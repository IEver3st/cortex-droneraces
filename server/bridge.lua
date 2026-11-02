Bridge = {}
local B = Bridge
local RESOURCE = GetCurrentResourceName()
local qb

local function started(name)
    local state = GetResourceState(name)
    return state == 'started' or state == 'starting'
end

local function qbCore()
    if not qb and started('qb-core') then
        local success, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
        qb = success and core or nil
    end
    return qb
end

function B.reset() qb = nil end

function B.framework()
    if started('qbx_core') then return 'qbx' end
    if started('qb-core') and qbCore() then return 'qb' end
end

function B.inventory()
    if started('ox_inventory') then return 'ox' end
    if B.framework() == 'qb' then return 'qb' end
end

function B.player(src)
    local kind = B.framework()
    if kind == 'qbx' then
        local success, value = pcall(function() return exports.qbx_core:GetPlayer(src) end)
        return success and value or nil
    elseif kind == 'qb' then
        local success, value = pcall(function() return qb.Functions.GetPlayer(src) end)
        return success and value or nil
    end
end

function B.data(src)
    local object = B.player(src)
    return object and object.PlayerData or nil
end

function B.citizenid(src)
    local data = B.data(src)
    if data and type(data.citizenid) == 'string' and data.citizenid ~= '' then return data.citizenid end
end

function B.identifier(src)
    local cid = B.citizenid(src)
    if cid then return 'cid:' .. cid end
    return GetPlayerIdentifierByType(tostring(src), 'license')
end

function B.name(src)
    local data = B.data(src)
    local info = data and data.charinfo
    if type(info) == 'table' and type(info.firstname) == 'string' then
        return (('%s %s'):format(info.firstname, info.lastname or ''):gsub('%s+$', ''))
    end
    return GetPlayerName(tostring(src)) or ('Player %s'):format(src)
end

function B.actor(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) or GetEntityHealth(ped) <= 0 then return nil end
    local data = B.data(src)
    local meta = data and data.metadata or {}
    if meta.isdead or meta.inlaststand or meta.ishandcuffed then return nil end
    return ped
end

function B.count(src, item)
    local inventory = B.inventory()
    if inventory == 'ox' then
        local success, amount = pcall(function() return exports.ox_inventory:GetItemCount(src, item) end)
        return success and type(amount) == 'number' and amount or nil
    elseif inventory == 'qb' then
        local object = B.player(src)
        if not object then return nil end
        local success, found = pcall(function() return object.Functions.GetItemByName(item) end)
        if not success then return nil end
        return type(found) == 'table' and (tonumber(found.amount) or 0) or 0
    end
end

function B.hasItem(src, item)
    if not item then return true end
    if not B.inventory() then return true end
    local amount = B.count(src, item)
    if amount == nil then return nil end
    return amount > 0
end

function B.economy()
    return Config.economy.enabled and B.framework() ~= nil
end

function B.balance(src, account)
    local data = B.data(src)
    local money = data and data.money
    return type(money) == 'table' and tonumber(money[account]) or nil
end

local function outcome(success, result, receipt)
    if not success then return 'unknown' end
    if type(receipt) == 'table' and receipt.status ~= nil then
        if receipt.status == 'applied' and receipt.durable == true and result == true then return 'applied' end
        if receipt.status == 'rejected' then return 'rejected' end
        return 'unknown'
    end
    if result == true then return 'applied' end
    if result ~= nil and result ~= false then return 'unknown' end
    return 'rejected'
end

local unloading, epochs = {}, {}

function B.setUnloading(src, on)
    unloading[src] = on or nil
    epochs[src] = (epochs[src] or 0) + 1
end

function B.epoch(src)
    return epochs[src] or 0
end

function B.unloading(src)
    return unloading[src] == true
end

function B.save(src)
    local kind = B.framework()
    if kind == 'qbx' then
        pcall(function() exports.qbx_core:Save(src) end)
    elseif kind == 'qb' then
        local object = B.player(src)
        if object then pcall(function() object.Functions.Save() end) end
    end
end

function B.removeMoney(src, citizenid, account, amount, reason, operation)
    local kind = B.framework()
    if kind == 'qbx' then
        return outcome(pcall(function() return exports.qbx_core:RemoveMoney(citizenid, account, amount, reason, operation) end))
    elseif kind == 'qb' then
        local object = B.player(src)
        if not object or B.citizenid(src) ~= citizenid then return 'rejected' end
        return outcome(pcall(function() return object.Functions.RemoveMoney(account, amount, reason) end))
    end
    return 'rejected'
end

function B.addMoney(src, citizenid, account, amount, reason, operation)
    if not src or unloading[src] or B.citizenid(src) ~= citizenid then return 'rejected' end
    local kind = B.framework()
    if kind == 'qbx' then
        return outcome(pcall(function() return exports.qbx_core:AddMoney(citizenid, account, amount, reason, operation) end))
    elseif kind == 'qb' then
        local object = B.player(src)
        if not object then return 'rejected' end
        return outcome(pcall(function() return object.Functions.AddMoney(account, amount, reason) end))
    end
    return 'rejected'
end

function B.online(citizenid)
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src and not unloading[src] and B.citizenid(src) == citizenid then return src end
    end
end

function B.notify(src, key, kind, vars)
    TriggerClientEvent(RESOURCE .. ':notify', src, key, kind or 'error', vars)
end
