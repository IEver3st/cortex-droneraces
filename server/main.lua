local B, E, T, Db, TR, RS = Bridge, RaceEconomy, RaceTrack, RaceDb, RaceTracks, RaceServer
local RESOURCE = GetCurrentResourceName()
local RATES = { host = 1500, join = 1500, leave = 800, start = 1500, trial = 2000, track = 200, board = 1000, save = 2000, delete = 2000,
    ready = 200, gate = 10, path = 2000, lobby = 500, access = 1000 }
local rates = {}

local function limited(src, name)
    local key, at = src .. ':' .. name, GetGameTimer()
    local last = rates[key]
    if last and at - last >= 0 and at - last < (RATES[name] or 300) then return true end
    rates[key] = at
    return false
end

local function ok(data) return { ok = true, data = data } end
local function fail(code) return { ok = false, error = code } end

local function callback(name, fn)
    lib.callback.register(RESOURCE .. ':' .. name, function(src, ...)
        if limited(src, name) then return fail('rate_limited') end
        local success, result, err = pcall(fn, src, ...)
        if not success then
            print(('^1[%s] %s failed: %s^0'):format(RESOURCE, name, tostring(result)))
            return fail('unavailable')
        end
        if result == nil then return fail(err or 'unavailable') end
        return ok(result)
    end)
end

local function event(name, fn)
    RegisterNetEvent(RESOURCE .. ':' .. name, function(...)
        local src = source
        if limited(src, name) then return end
        local success, err = pcall(fn, src, ...)
        if not success then print(('^1[%s] %s failed: %s^0'):format(RESOURCE, name, tostring(err))) end
    end)
end

local function canCreate(src)
    if Config.editor.access == 'everyone' then return true end
    return IsPlayerAceAllowed(tostring(src), 'cortex.droneraces.create') or IsPlayerAceAllowed(tostring(src), 'cortex.droneraces.admin')
end

local function isStaff(src)
    return src == 0 or IsPlayerAceAllowed(tostring(src), 'cortex.droneraces.admin')
end

local function canEdit(src, track)
    if not track then return false end
    if isStaff(src) then return true end
    if not canCreate(src) then return false end
    return track.owner ~= nil and track.owner == B.identifier(src)
end

callback('access', function(src)
    return { create = canCreate(src), staff = isStaff(src), economy = E.enabled(), account = Config.economy.account,
        minFee = Config.economy.minFee, maxFee = Config.economy.maxFee, owner = B.identifier(src) }
end)

callback('track', function(src, id)
    local track = TR.get(id)
    if not track then return nil, 'no_track' end
    return T.wire(track)
end)

callback('lobby', function(src, trackId)
    local track = TR.get(trackId)
    if not track then return nil, 'no_track' end
    local race = RS.lobbyOn(track.id)
    local mine = RS.races[RS.bySrc[src] or -1]
    return {
        lobby = race and RS.lobbyView(race) or false,
        mine = mine and mine.id or false,
        canEdit = canEdit(src, track),
        isStaff = isStaff(src),
    }
end)

callback('host', function(src, trackId, laps, fee) return RS.host(src, trackId, laps, fee) end)
callback('join', function(src, raceId) return RS.join(src, raceId) end)
callback('leave', function(src) return RS.leave(src) or nil, 'not_racing' end)
callback('start', function(src, raceId)
    local started, err = RS.start(src, raceId)
    if not started then return nil, err end
    return true
end)

callback('trial', function(src, trackId, draft)
    if draft ~= nil then
        if not canCreate(src) then return nil, 'denied' end
        if type(draft) ~= 'table' then return nil, 'bad_track' end
    end
    return RS.trial(src, trackId, draft)
end)

callback('board', function(src, trackId)
    local track = TR.get(trackId)
    if not track or not Db.ready then return nil, 'no_track' end
    local owner = B.identifier(src)
    return { rows = Db.leaderboard(track.id, 10), mine = owner and Db.personal(track.id, owner) or false }
end)

callback('save', function(src, id, draft)
    if not canCreate(src) then return nil, 'denied' end
    if not Db.ready then return nil, 'database' end
    if type(draft) ~= 'table' then return nil, 'bad_track' end
    local owner = B.identifier(src)
    if not owner then return nil, 'unavailable' end
    local existing = id and TR.get(id)
    if existing then
        if not canEdit(src, existing) then return nil, 'denied' end
    else
        if not isStaff(src) and Db.countOwned(owner) >= Config.editor.maxTracksPerPlayer then return nil, 'too_many_tracks' end
        id = TR.newId()
        if not id then return nil, 'unavailable' end
    end
    if not isStaff(src) then draft.always = existing and existing.always == true or false end
    local track, err = TR.save(id, draft, existing and existing.owner or owner, existing and existing.author or B.name(src))
    if not track then return nil, err end
    if Config.audit.tracks then RaceAudit.log('tracks', 'Track saved', { Player = RaceAudit.actor(src), Track = track.name, Id = id, Gates = #track.checkpoints }) end
    return { id = id, rev = track.rev }
end)

callback('delete', function(src, id)
    local track = TR.get(id)
    if not track then return nil, 'no_track' end
    if not canEdit(src, track) then return nil, 'denied' end
    if RS.lobbyOn(id) then return nil, 'busy' end
    for _, race in pairs(RS.races) do if race.track.id == id then return nil, 'busy' end end
    TR.delete(id)
    if Config.audit.tracks then RaceAudit.log('tracks', 'Track deleted', { Player = RaceAudit.actor(src), Track = track.name, Id = id }) end
    return true
end)

event('ready', function(src, raceId) RS.ready(src, raceId) end)
event('gate', function(src, raceId, index, ms) RS.gate(src, raceId, index, ms) end)
event('forfeit', function(src)
    local race = RS.races[RS.bySrc[src] or -1]
    if race then RS.leave(src) end
end)
RegisterNetEvent(RESOURCE .. ':path', function(raceId, path)
    local src = source
    if limited(src, 'path') then return end
    local success, err = pcall(RS.path, src, raceId, path)
    if not success then print(('^1[%s] path failed: %s^0'):format(RESOURCE, tostring(err))) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    pcall(RS.dropped, src)
    B.setUnloading(src, false)
    local prefix = src .. ':'
    for key in pairs(rates) do if key:sub(1, #prefix) == prefix then rates[key] = nil end end
end)

local function loaded(src)
    B.setUnloading(src, false)
    SetTimeout(5000, function() pcall(E.retryFor, src) end)
end
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    src = tonumber(src)
    if not src then return end
    B.setUnloading(src, true)
    local ok, err = pcall(RS.unloaded, src)
    if not ok then print(('^1[%s] unload failed: %s^0'):format(RESOURCE, tostring(err))) end
end)
AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    local src = tonumber(type(player) == 'table' and player.PlayerData and player.PlayerData.source)
    if src then loaded(src) end
end)

AddEventHandler(RESOURCE .. ':dbReady', function()
    local loadedOk, loadErr = pcall(TR.loadSaved)
    if not loadedOk then print(('^1[%s] loading saved tracks failed: %s^0'):format(RESOURCE, tostring(loadErr))) end
    local ok, result = pcall(E.recover, true)
    E.recovered = ok and result == true
    if E.recovered then
        for _, id in ipairs(GetPlayers()) do pcall(E.retryFor, tonumber(id)) end
    else print(('^1[%s] money recovery failed, paid races stay closed until it succeeds: %s^0'):format(RESOURCE, tostring(result))) end
end)

CreateThread(function()
    while true do
        Wait(300000)
        if E.recovered then
            pcall(E.recover, false)
        elseif Db.ready then
            local ok, result = pcall(E.recover, true)
            E.recovered = ok and result == true
            if E.recovered then
                for _, id in ipairs(GetPlayers()) do pcall(E.retryFor, tonumber(id)) end
            end
        end
    end
end)

CreateThread(function()
    TR.loadBuiltins()
    GlobalState[RESOURCE .. ':active'] = {}
end)

local function reply(src, text)
    if src == 0 then print(('[%s] %s'):format(RESOURCE, text)) else TriggerClientEvent('chat:addMessage', src, { args = { 'Drone races', text } }) end
end

RegisterCommand('droneraces_list', function(src)
    if not isStaff(src) then return end
    local races = RS.list()
    if #races == 0 then reply(src, 'No races running.') end
    for _, race in ipairs(races) do
        local count = 0
        for _ in pairs(race.racers) do count = count + 1 end
        reply(src, ('#%d %s on %s: %s, %d racers, fee %d%s'):format(race.id, race.uid, race.track.name, race.state, count, race.fee, race.trial and ', trial' or ''))
    end
    local unresolved = Db.ready and Db.ledgerUnknown() or {}
    if #unresolved > 0 then
        reply(src, ('Unresolved money entries: newest %d of %d. Older ones are in cortex_droneraces_ledger with state unknown.'):format(#unresolved, Db.ledgerUnknownCount()))
    end
    for _, row in ipairs(unresolved) do
        reply(src, ('Unresolved money entry %s (%s): %s %d %s for %s (race %s, attempt %s)'):format(row.id, row.state, row.kind, row.amount, row.account, row.citizenid, row.race, row.attempt or 'none'))
    end
end, true)

RegisterCommand('droneraces_cancel', function(src, args)
    if not isStaff(src) then return end
    local race = RS.races[math.tointeger(tonumber(args[1])) or -1]
    if not race then reply(src, 'No race with that number.') return end
    if race.state == 'results' then reply(src, ('Race #%d has finished; its results and prizes stand.'):format(race.id)) return end
    local free = race.trial or race.fee <= 0
    local queued = RS.close(race, 'cancelled') or 0
    if Config.audit.staff then RaceAudit.log('staff', 'Race cancelled by staff', { Staff = RaceAudit.actor(src), Race = race.uid }) end
    local note = free and '' or queued > 0 and ('; %d refunds settle automatically within a few minutes, the rest are refunded'):format(queued)
        or '; entry fees refunded (offline players receive them when they next log in; any payment that could not be confirmed shows in droneraces_list)'
    reply(src, ('Race #%d cancelled%s.'):format(race.id, note))
end, true)

RegisterCommand('droneraces_deletetrack', function(src, args)
    if not isStaff(src) then return end
    local id = args[1]
    if not TR.get(id) then reply(src, 'No track with that id.') return end
    for _, race in pairs(RS.races) do if race.track.id == id then reply(src, 'A race is using that track.') return end end
    TR.delete(id)
    if Config.audit.staff then RaceAudit.log('staff', 'Track deleted by staff', { Staff = RaceAudit.actor(src), Id = id }) end
    reply(src, ('Track %s deleted.'):format(id))
end, true)

AddEventHandler('onResourceStop', function(name)
    if name ~= RESOURCE then return end
    pcall(RS.shutdown)
end)
