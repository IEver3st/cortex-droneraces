RaceNui = {}
local N = RaceNui
local ready, focus = false, nil
local queue = {}
local signatures = {}

local function text()
    local merged = Locale.prefixed('ui.')
    return merged
end

local function post(action, data)
    SendNUIMessage({ action = action, data = data })
end

function N.send(action, data)
    if not ready then
        queue[action] = data or false
        return
    end
    post(action, data)
end

function N.state(action, data, signature)
    if signature and signatures[action] == signature then return end
    signatures[action] = signature
    N.send(action, data)
end

function N.forget(action) signatures[action] = nil end

RegisterNUICallback('ready', function(_, cb)
    ready = true
    cb({ ok = true })
    post('text', { text = text(), safezone = GetSafeZoneSize(), key = Config.keys.menu })
    for action, data in pairs(queue) do post(action, data or nil) end
    queue = {}
end)

function N.focus(reason)
    if focus == reason then return end
    focus = reason
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(false)
end

function N.release(reason)
    if not focus or (reason and focus ~= reason) then return end
    focus = nil
    SetNuiFocus(false, false)
end

function N.focused() return focus end

local handlers = {}
function N.on(name, fn) handlers[name] = fn end

for _, name in ipairs({ 'close', 'replay', 'select' }) do
    RegisterNUICallback(name, function(data, cb)
        local fn = handlers[name]
        local ok = false
        if fn then ok = pcall(fn, type(data) == 'table' and data or {}) end
        cb({ ok = ok })
    end)
end

AddEventHandler('onClientResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    if focus then pcall(SetNuiFocus, false, false) end
end)
