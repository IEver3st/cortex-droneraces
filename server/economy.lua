RaceEconomy = { recovered = false }
local E = RaceEconomy
local B, Db = Bridge, RaceDb
local counter = 0

local function opId(race, kind)
    counter = counter + 1
    return ('cxdr:%s:%s:%d:%x'):format(kind, race, counter, math.random(0, 0xFFFFFF)):sub(1, 64)
end

local function reason(row)
    return ('Drone race %s (%s)'):format(row.kind, row.race)
end

function E.enabled() return B.economy() end

function E.clampFee(value)
    if not E.enabled() then return 0 end
    local fee = tonumber(value or 0)
    if not fee or fee ~= fee or fee % 1 ~= 0 then return nil end
    fee = math.tointeger(fee)
    if not fee or fee < Config.economy.minFee or fee > Config.economy.maxFee then return nil end
    return fee
end

function E.charge(src, race, fee)
    if fee <= 0 then return true, nil end
    if not E.enabled() or not Db.ready or not E.recovered then return false, 'economy_unavailable' end
    local citizenid = B.citizenid(src)
    if not citizenid or B.unloading(src) then return false, 'economy_unavailable' end
    local account = Config.economy.account
    local balance = B.balance(src, account)
    if balance and balance < fee then return false, 'cannot_afford' end
    local epoch = B.epoch(src)
    local id = opId(race.uid, 'fee')
    if not Db.ledgerInsert(id, race.uid, citizenid, 'fee', fee, account, 'pending') then return false, 'economy_unavailable' end
    if B.citizenid(src) ~= citizenid or B.unloading(src) or B.epoch(src) ~= epoch then
        Db.ledgerState(id, 'void', 'pending')
        return false, 'unavailable'
    end
    local result = B.removeMoney(src, citizenid, account, fee, reason({ kind = 'fee', race = race.uid }), id)
    if result == 'applied' and B.epoch(src) ~= epoch then result = 'moved' end
    if result == 'rejected' then
        Db.ledgerState(id, 'void', 'pending')
        return false, 'cannot_afford'
    elseif result ~= 'applied' then
        Db.ledgerState(id, 'unknown', 'pending')
        RaceAudit.log('money', 'Race entry fee outcome unknown; check it by hand', { Player = RaceAudit.actor(src), Id = id, Amount = fee, Account = account })
        return false, 'economy_unavailable'
    end
    B.save(src)
    if not Db.ledgerState(id, 'held', 'pending') and not Db.ledgerState(id, 'held', 'pending') then
        RaceAudit.log('money', 'Race entry fee taken but still marked pending; it settles with the race', { Player = RaceAudit.actor(src), Id = id, Amount = fee })
    end
    RaceAudit.log('money', 'Race entry fee held', { Player = RaceAudit.actor(src), Race = race.uid, Amount = fee, Account = account })
    return true, { id = id, citizenid = citizenid, amount = fee, account = account, epoch = epoch }
end

local function pay(row)
    local src = B.online(row.citizenid)
    if not src then return false end
    local attempt = opId(row.race, 'pay')
    if not Db.ledgerClaim(row.id, attempt) then return false end
    local epoch = B.epoch(src)
    local result = B.addMoney(src, row.citizenid, row.account, row.amount, reason(row), attempt)
    if result == 'applied' and B.citizenid(src) == row.citizenid and not B.unloading(src) and B.epoch(src) == epoch then
        B.save(src)
        if not Db.ledgerState(row.id, 'done', 'pending') then
            RaceAudit.log('money', 'Race credit paid but still marked pending; check it by hand', { Id = row.id, Attempt = attempt, Citizen = row.citizenid, Amount = row.amount })
        end
        B.notify(src, row.kind == 'prize' and 'notify.prize' or 'notify.refunded', 'success', { amount = row.amount })
        RaceAudit.log('money', 'Race credit paid', { Citizen = row.citizenid, Kind = row.kind, Amount = row.amount, Account = row.account, Race = row.race })
        return true
    elseif result == 'rejected' then
        Db.ledgerState(row.id, 'owed', 'pending')
        RaceAudit.log('money', 'Race credit refused, retried on next load', { Citizen = row.citizenid, Kind = row.kind, Amount = row.amount, Race = row.race })
        return false
    end
    Db.ledgerState(row.id, 'unknown', 'pending')
    RaceAudit.log('money', 'Race credit outcome unknown; check it by hand', { Id = row.id, Attempt = attempt, Citizen = row.citizenid, Kind = row.kind, Amount = row.amount, Account = row.account })
    return false
end

local function payAll(rows)
    for _, row in ipairs(rows) do
        local ok, err = pcall(pay, row)
        if not ok then print(('^1[%s] paying %s failed: %s^0'):format(GetCurrentResourceName(), row.id, tostring(err))) end
    end
end

local function obligation(race, citizenid, kind, amount, account)
    return { id = opId(race, kind), race = race, citizenid = citizenid, kind = kind, amount = amount, account = account }
end

local function commit(race, changes, rows)
    for _ = 1, 2 do
        if Db.settle(race, changes, rows) then return true end
        if #rows == 0 then return nil end
        local exists = Db.ledgerExists(rows[1].id)
        if exists ~= false then return exists end
    end
    return false
end

function E.refund(entry, race)
    if not entry or entry.amount <= 0 or entry.settled then return true end
    entry.settled = true
    local row = obligation(race, entry.citizenid, 'refund', entry.amount, entry.account)
    local done = commit(race, { { id = entry.id, citizenid = entry.citizenid, state = 'refunded' } }, { row })
    if done == false then
        entry.settled = false
        RaceAudit.log('money', 'Race refund could not be recorded; it is retried automatically', { Citizen = entry.citizenid, Amount = entry.amount, Race = race })
        return false
    elseif done == nil then
        entry.deferred = true
        RaceAudit.log('money', 'Race refund not confirmed; it settles automatically after the race closes', { Id = entry.id, Citizen = entry.citizenid, Amount = entry.amount, Race = race })
        return false
    end
    payAll({ row })
    return true
end

function E.split(pot, finishers)
    local result = {}
    if pot <= 0 or finishers <= 0 then return result end
    local key = 0
    for count in pairs(Config.economy.payouts) do
        if count <= finishers and count > key then key = count end
    end
    local shares = Config.economy.payouts[key] or { 1.0 }
    local total = 0.0
    for _, share in ipairs(shares) do total = total + share end
    local paid = 0
    for i, share in ipairs(shares) do
        local amount = math.floor(pot * share / total)
        result[i] = amount
        paid = paid + amount
    end
    result[1] = result[1] + (pot - paid)
    return result
end

local function paidOut(rows)
    local total = 0
    for _, row in ipairs(rows) do total = total + row.amount end
    return total
end

function E.settle(race, standings, racerOf)
    local fees, pot = {}, 0
    for _, row in ipairs(standings) do
        local racer = racerOf(row.src)
        local fee = racer and racer.fee
        if fee and not fee.settled and fee.amount > 0 then
            fee.settled = true
            fees[#fees + 1] = fee
            pot = pot + fee.amount
        end
    end
    if pot <= 0 then return {}, 0 end
    local changes, rows, prizes = {}, {}, {}
    local finishers = {}
    for _, row in ipairs(standings) do
        if row.finished then finishers[#finishers + 1] = row end
    end
    if #finishers == 0 then
        for _, fee in ipairs(fees) do
            changes[#changes + 1] = { id = fee.id, citizenid = fee.citizenid, state = 'refunded' }
            rows[#rows + 1] = obligation(race.uid, fee.citizenid, 'refund', fee.amount, fee.account)
        end
    else
        for _, fee in ipairs(fees) do changes[#changes + 1] = { id = fee.id, citizenid = fee.citizenid, state = 'pot' } end
        local house = math.floor(pot * Config.economy.houseCut)
        for place, amount in ipairs(E.split(pot - house, #finishers)) do
            local row = finishers[place]
            local racer = row and racerOf(row.src)
            local citizenid = racer and (racer.fee and racer.fee.citizenid or racer.citizenid)
            if citizenid and amount > 0 then
                rows[#rows + 1] = obligation(race.uid, citizenid, 'prize', amount, Config.economy.account)
                prizes[row.src] = amount
            end
        end
    end
    local done = commit(race.uid, changes, rows)
    if done == false then
        for _, fee in ipairs(fees) do fee.settled = false end
        RaceAudit.log('money', 'Race pot could not be recorded; fees are refunded instead', { Race = race.uid, Pot = pot })
        return {}, 0
    elseif done == nil then
        RaceAudit.log('money', 'Race pot not confirmed; it settles automatically after the race closes', { Race = race.uid, Pot = pot })
        for _, fee in ipairs(fees) do
            local online = B.online(fee.citizenid)
            if online then B.notify(online, 'notify.settling', 'info') end
        end
        return {}, 0
    end
    payAll(rows)
    RaceAudit.log('money', 'Race pot settled', { Race = race.uid, Pot = pot, House = pot - paidOut(rows), Finishers = #finishers, Credits = #rows })
    return prizes, pot
end

function E.recover(boot)
    if not Db.ready then return false end
    local open = Db.ledgerOpen()
    if not open then return false end
    local live = RaceServer and RaceServer.liveUids() or {}
    local complete = true
    for _, row in ipairs(open) do
        if not live[row.race] then
            if row.state == 'held' and row.kind == 'fee' then
                local refund = obligation(row.race, row.citizenid, 'refund', row.amount, row.account)
                if commit(row.race, { { id = row.id, citizenid = row.citizenid, state = 'refunded' } }, { refund }) then payAll({ refund }) end
            elseif row.state == 'pending' and (boot or (row.updated and row.updated < Db.now() - 600)) then
                if not Db.ledgerState(row.id, 'unknown', 'pending') then complete = false end
                RaceAudit.log('money', 'Race money entry interrupted; check it by hand', {
                    Id = row.id, Attempt = row.attempt, Citizen = row.citizenid, Kind = row.kind, Amount = row.amount, Account = row.account,
                })
            elseif row.state == 'owed' then
                payAll({ row })
            end
        end
    end
    return complete
end

function E.retryFor(src)
    if not Db.ready or not E.recovered or not B.framework() then return end
    local citizenid = B.citizenid(src)
    if not citizenid then return end
    payAll(Db.ledgerFor(citizenid))
end
