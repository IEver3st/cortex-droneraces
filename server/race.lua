RaceServer = { races = {}, bySrc = {} }
local RS = RaceServer
local B, E, T, G, Db, TR = Bridge, RaceEconomy, RaceTrack, RaceGeometry, RaceDb, RaceTracks
local RESOURCE = GetCurrentResourceName()
local DRONE = 'cortex-drone'
local SAMPLE_MS = 250
local SAMPLE_KEEP = 24
local PATH_LIMIT = 6000
local nextId = 0

local function now() return GetGameTimer() end

local function send(src, name, ...) TriggerClientEvent(RESOURCE .. ':' .. name, src, ...) end

local function racersOf(race)
    local list = {}
    for _, src in ipairs(race.order) do if race.racers[src] then list[#list + 1] = src end end
    return list
end

local function broadcast(race, name, ...)
    for _, src in ipairs(racersOf(race)) do send(src, name, ...) end
end

local function droneEntity(src)
    local ok, info = pcall(function() return exports[DRONE]:GetDrone(src) end)
    if not ok or type(info) ~= 'table' or not info.netId then return 0 end
    local entity = NetworkGetEntityFromNetworkId(info.netId)
    if entity == 0 or not DoesEntityExist(entity) then return 0 end
    return entity
end

local function hasDrone(src)
    local ok, info = pcall(function() return exports[DRONE]:GetDrone(src) end)
    return ok and type(info) == 'table'
end

local function setProfile(src, profile)
    local ok, result = pcall(function() return exports[DRONE]:SetRaceProfile(src, profile) end)
    return ok and result == true
end

local function recall(src)
    pcall(function() exports[DRONE]:RecallDrone(src, 'race') end)
    setProfile(src, nil)
end

function RS.liveUids()
    local live = {}
    for _, race in pairs(RS.races) do live[race.uid] = true end
    return live
end

local function publishActive()
    local active = {}
    for _, race in pairs(RS.races) do
        if not race.draft and race.state ~= 'closed' then active[race.track.id] = (active[race.track.id] or 0) + 1 end
    end
    GlobalState[RESOURCE .. ':active'] = active
end

local function lobbyOn(trackId)
    for _, race in pairs(RS.races) do
        if race.track.id == trackId and not race.trial and race.state == 'lobby' then return race end
    end
end
RS.lobbyOn = lobbyOn

local function lobbyView(race)
    local racers = {}
    for _, src in ipairs(racersOf(race)) do
        local r = race.racers[src]
        racers[#racers + 1] = { id = src, name = r.name, colour = r.colour, host = src == race.host }
    end
    local pot = 0
    for _, r in pairs(race.racers) do if r.fee then pot = pot + r.fee.amount end end
    return {
        id = race.id, track = race.track.id, name = race.track.name, laps = race.laps, loop = race.track.loop, fee = race.fee, pot = pot,
        host = race.host, state = race.state, racers = racers, max = math.min(Config.race.maxRacers, #race.track.grid),
        closes = race.closesAt and math.max(0, math.floor((race.closesAt - now()) / 1000)) or 0,
    }
end
RS.lobbyView = lobbyView

local function pushLobby(race)
    local view = lobbyView(race)
    broadcast(race, 'lobby', view)
end

local function leaveRace(src, race, reason)
    local racer = race.racers[src]
    if not racer then return end
    race.racers[src] = nil
    if RS.bySrc[src] == race.id then RS.bySrc[src] = nil end
    for i = #race.order, 1, -1 do
        if race.order[i] == src then table.remove(race.order, i) end
    end
    if racer.deployed then recall(src) end
    E.refund(racer.fee, race.uid)
    if GetPlayerName(tostring(src)) then send(src, 'left', race.id, reason) end
end

local function close(race, reason)
    if race.state == 'closed' then return end
    local previous = race.state
    race.state = 'closed'
    local before = previous == 'lobby' or previous == 'deploying' or previous == 'countdown'
    local fees = {}
    for _, list in ipairs({ race.racers, race.gone or {} }) do
        for _, racer in pairs(list) do if racer.fee then fees[#fees + 1] = racer.fee end end
    end
    for _, src in ipairs(racersOf(race)) do
        local racer = race.racers[src]
        if before or reason == 'cancelled' then
            local ok, err = pcall(leaveRace, src, race, reason)
            if not ok then print(('^1[%s] leaving race %s failed: %s^0'):format(RESOURCE, race.uid, tostring(err))) end
        else
            if racer.deployed then pcall(recall, src) end
            if RS.bySrc[src] == race.id then RS.bySrc[src] = nil end
            if GetPlayerName(tostring(src)) then send(src, 'left', race.id, reason) end
        end
    end
    local queued = 0
    for _, fee in ipairs(fees) do
        pcall(E.refund, fee, race.uid)
        if not fee.settled or fee.deferred then queued = queued + 1 end
    end
    RS.races[race.id] = nil
    publishActive()
    if Config.audit.races then RaceAudit.log('races', 'Race closed', { Race = race.uid, Track = race.track.name, Reason = reason or previous }) end
    return queued
end
RS.close = close

local function makeRace(track, host, laps, fee, trial, draft)
    nextId = nextId + 1
    local race = {
        id = nextId, uid = ('r%d-%d-%x'):format(os.time(), nextId, math.random(0, 0x7FFFFFFF)), track = track, host = host, laps = laps, fee = fee,
        trial = trial == true, draft = draft == true, state = 'lobby', racers = {}, order = {}, created = now(),
        closesAt = now() + math.floor(Config.race.lobbyMinutes * 60000),
    }
    race.gates = T.gateCount(track, laps)
    RS.races[race.id] = race
    publishActive()
    return race
end

local function addRacer(race, src, feeEntry)
    local taken = {}
    for _, other in pairs(race.racers) do taken[other.slot] = true end
    local slot = 1
    while taken[slot] do slot = slot + 1 end
    local racer = {
        src = src, name = B.name(src), owner = B.identifier(src), citizenid = B.citizenid(src), colour = (slot - 1) % #Config.effects.colours + 1,
        slot = slot, fee = feeEntry, gate = 0, times = {}, laps = {}, lastLap = 0, lastMs = 0, samples = {}, rejected = 0,
    }
    race.racers[src] = racer
    race.order[#race.order + 1] = src
    RS.bySrc[src] = race.id
    return racer
end

function RS.eligible(src, track, checkDistance)
    if RS.bySrc[src] then return false, 'already_racing' end
    local ped = B.actor(src)
    if not ped then return false, 'unavailable' end
    if GetVehiclePedIsIn(ped, false) ~= 0 then return false, 'on_foot' end
    if checkDistance ~= false then
        local at = GetEntityCoords(ped)
        if G.distance(at.x, at.y, at.z, track.start.x, track.start.y, track.start.z) > Config.race.joinRadius + 5.0 then return false, 'too_far' end
    end
    if hasDrone(src) then return false, 'drone_out' end
    if Config.requireItem then
        local has = false
        for _, item in ipairs(Config.requireItem) do
            local found = B.hasItem(src, item)
            if found == nil then return false, 'inventory' end
            if found then has = true break end
        end
        if not has then return false, 'no_drone' end
    end
    return true
end

function RS.host(src, trackId, laps, fee)
    local track = TR.get(trackId)
    if not track then return nil, 'no_track' end
    if #track.grid < 1 then return nil, 'no_grid' end
    if lobbyOn(track.id) then return nil, 'lobby_exists' end
    laps = track.loop and (math.tointeger(tonumber(laps)) or track.laps) or 1
    if laps < Config.race.laps.min or laps > Config.race.laps.max then return nil, 'bad_laps' end
    fee = E.clampFee(fee)
    if not fee then return nil, 'bad_fee' end
    local ok, err = RS.eligible(src, track)
    if not ok then return nil, err end
    local race = makeRace(track, src, laps, fee, false, false)
    race.joining = (race.joining or 0) + 1
    local success, charged, entry = pcall(E.charge, src, race, fee)
    race.joining = race.joining - 1
    if not success or not charged then close(race, 'host_failed'); return nil, success and entry or 'economy_unavailable' end
    if race.state ~= 'lobby' or RS.bySrc[src] or not GetPlayerName(tostring(src)) or B.unloading(src)
        or (entry and (B.citizenid(src) ~= entry.citizenid or B.epoch(src) ~= entry.epoch)) then
        E.refund(entry, race.uid)
        close(race, 'host_failed')
        return nil, 'unavailable'
    end
    addRacer(race, src, entry)
    if Config.audit.races then RaceAudit.log('races', 'Race lobby opened', { Host = RaceAudit.actor(src), Track = track.name, Laps = laps, Fee = fee }) end
    pushLobby(race)
    TriggerClientEvent(RESOURCE .. ':lobbyOpened', -1, { track = track.id, name = track.name, fee = fee, laps = laps })
    return lobbyView(race)
end

function RS.join(src, raceId)
    local race = RS.races[math.tointeger(tonumber(raceId)) or -1]
    if not race or race.trial or race.state ~= 'lobby' or not race.racers[race.host] then return nil, 'no_lobby' end
    if race.racers[src] then return lobbyView(race) end
    local max = math.min(Config.race.maxRacers, #race.track.grid)
    if #racersOf(race) >= max then return nil, 'full' end
    local ok, err = RS.eligible(src, race.track)
    if not ok then return nil, err end
    race.joining = (race.joining or 0) + 1
    local success, charged, entry = pcall(E.charge, src, race, race.fee)
    race.joining = race.joining - 1
    if not success then return nil, 'economy_unavailable' end
    if not charged then return nil, entry end
    if race.state ~= 'lobby' or race.racers[src] or RS.bySrc[src] or #racersOf(race) >= max or not GetPlayerName(tostring(src))
        or B.unloading(src) or (entry and (B.citizenid(src) ~= entry.citizenid or B.epoch(src) ~= entry.epoch)) then
        E.refund(entry, race.uid)
        return nil, race.state ~= 'lobby' and 'no_lobby' or 'full'
    end
    addRacer(race, src, entry)
    pushLobby(race)
    return lobbyView(race)
end

local function leaveBeforeStart(src, race, reason)
    if race.host == src then
        for _, other in ipairs(racersOf(race)) do
            if other ~= src then race.host = other break end
        end
    end
    leaveRace(src, race, reason)
    if #racersOf(race) == 0 then close(race, 'empty') return end
    if race.state == 'lobby' then pushLobby(race) end
end

function RS.leave(src)
    local race = RS.races[RS.bySrc[src] or -1]
    if not race then return false end
    if race.state == 'lobby' or race.state == 'deploying' or race.state == 'countdown' then
        leaveBeforeStart(src, race, 'left')
        return true
    end
    RS.forfeit(src, race, 'forfeit')
    return true
end

local function poseFor(race, racer)
    local pad = race.track.grid[racer.slot] or race.track.grid[1]
    local top = RaceCatalogue.pieces.pad.top
    return { x = pad.x, y = pad.y, z = pad.z + top + 0.2, w = pad.h }
end

local function startCountdown(race)
    for _, src in ipairs(racersOf(race)) do
        local racer = race.racers[src]
        if racer and not racer.ready then
            if Config.audit.races then RaceAudit.log('races', 'Racer dropped: drone not on its pad', { Player = RaceAudit.actor(src), Race = race.uid }) end
            leaveRace(src, race, 'not_ready')
        end
    end
    if RS.races[race.id] ~= race or race.state ~= 'deploying' then return end
    if #racersOf(race) == 0 then close(race, 'nobody_ready'); return end
    race.state = 'countdown'
    race.goAt = now() + Config.race.countdown * 1000
    for _, src in ipairs(racersOf(race)) do
        local entity = droneEntity(src)
        if entity ~= 0 then Entity(entity).state:set(RESOURCE .. ':racer', { race = race.id, colour = race.racers[src].colour }, true) end
    end
    local roster = {}
    for _, src in ipairs(racersOf(race)) do
        local r = race.racers[src]
        roster[#roster + 1] = { id = src, name = r.name, colour = r.colour }
    end
    broadcast(race, 'countdown', { id = race.id, seconds = Config.race.countdown, roster = roster })
    SetTimeout(Config.race.countdown * 1000, function()
        if RS.races[race.id] ~= race or race.state ~= 'countdown' then return end
        race.state = 'racing'
        race.startedAt = now()
        for _, src in ipairs(racersOf(race)) do race.racers[src].seenAt = race.startedAt end
        broadcast(race, 'go', race.id)
        RS.watch(race)
    end)
end

function RS.start(src, raceId)
    local race = RS.races[math.tointeger(tonumber(raceId)) or -1]
    if not race or race.state ~= 'lobby' then return false, 'no_lobby' end
    if race.host ~= src then return false, 'not_host' end
    if (race.joining or 0) > 0 then return false, 'busy' end
    RS.deploy(race)
    return true
end

function RS.deploy(race)
    race.state = 'deploying'
    race.closesAt = nil
    race.deployAt = now()
    publishActive()
    for _, src in ipairs(racersOf(race)) do
        local racer = race.racers[src]
        local pose = poseFor(race, racer)
        if not hasDrone(src) and setProfile(src, { kind = Config.drone, spawn = pose, race = race.uid }) then
            racer.deployed = true
            send(src, 'deploy', {
                id = race.id, track = race.track.id, rev = race.track.rev, draft = race.draft, laps = race.laps, gates = race.gates,
                slot = racer.slot, colour = racer.colour, trial = race.trial, pose = pose,
            })
        end
    end
    if Config.audit.races then RaceAudit.log('races', 'Race started', { Race = race.uid, Track = race.track.name, Racers = #racersOf(race), Laps = race.laps, Fee = race.fee }) end
    local deadline = now() + math.floor(Config.race.deploySeconds * 1000)
    CreateThread(function()
        while RS.races[race.id] == race and race.state == 'deploying' do
            local all = true
            for _, src in ipairs(racersOf(race)) do if not race.racers[src].ready then all = false break end end
            if all or now() > deadline then
                local ok, err = pcall(startCountdown, race)
                if not ok then
                    print(('^1[%s] race %s countdown failed: %s^0'):format(RESOURCE, race.uid, tostring(err)))
                    close(race, 'stuck')
                end
                break
            end
            Wait(250)
        end
    end)
end

function RS.ready(src, raceId)
    local race = RS.races[math.tointeger(tonumber(raceId)) or -1]
    local racer = race and race.racers[src]
    if not racer or race.state ~= 'deploying' then return end
    if droneEntity(src) == 0 then return end
    racer.ready = true
end

function RS.trial(src, trackId, draft)
    local track
    if draft then
        local normalized, err = T.normalize(draft)
        if not normalized then return nil, err end
        normalized.id = 'draft'
        normalized.rev = 0
        T.derive(normalized)
        track = normalized
    else
        track = TR.get(trackId)
        if not track then return nil, 'no_track' end
    end
    local ok, err = RS.eligible(src, track, not draft)
    if not ok then return nil, err end
    local race = makeRace(track, src, track.loop and track.laps or 1, 0, true, draft ~= nil)
    addRacer(race, src, nil)
    RS.deploy(race)
    return { id = race.id }
end

local function standings(race)
    local rows = {}
    for _, src in ipairs(race.order) do
        local r = race.racers[src] or race.gone and race.gone[src]
        if r then
            local best
            for _, lap in ipairs(r.laps) do if not best or lap < best then best = lap end end
            rows[#rows + 1] = {
                src = src, id = src, name = r.name, colour = r.colour, gate = r.gate, ms = r.lastMs, finished = r.finished == true,
                dnf = not r.finished, total = r.finished and r.total or nil, laps = r.laps, best = best, citizenid = r.citizenid, owner = r.owner,
                online = GetPlayerName(tostring(src)) ~= nil and race.racers[src] ~= nil,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.finished ~= b.finished then return a.finished end
        if a.finished then return a.total < b.total end
        if a.gate ~= b.gate then return a.gate > b.gate end
        return a.ms < b.ms
    end)
    for i, row in ipairs(rows) do row.place = i end
    return rows
end
RS.standings = standings

local function live(race)
    local rows = standings(race)
    local view = {}
    for _, row in ipairs(rows) do
        view[#view + 1] = { id = row.id, name = row.name, colour = row.colour, gate = row.gate, ms = row.ms, finished = row.finished, total = row.total, place = row.place }
    end
    broadcast(race, 'standings', race.id, view)
end

function RS.forfeit(src, race, reason)
    local racer = race.racers[src]
    if not racer or racer.finished or racer.out then return end
    racer.out = true
    if racer.deployed then recall(src) end
    racer.deployed = false
    if Config.audit.races then RaceAudit.log('races', 'Racer out', { Player = RaceAudit.actor(src), Race = race.uid, Reason = reason }) end
    live(race)
end

local function sample(race)
    local at = now()
    for _, src in ipairs(racersOf(race)) do
        local racer = race.racers[src]
        if not racer.finished and not racer.out then
            local entity = droneEntity(src)
            if entity ~= 0 then
                local p = GetEntityCoords(entity)
                local s = racer.samples
                s[#s + 1] = { at, p.x, p.y, p.z }
                racer.seenAt = at
                if #s > SAMPLE_KEEP then table.remove(s, 1) end
            end
        end
    end
end

local function near(racer, piece, reach, since)
    local s = racer.samples
    local found = false
    for i = 1, #s do
        local a = s[i]
        if a[1] >= since then
            found = true
            local b = s[i + 1] or a
            if G.segmentDistance(piece.x, piece.y, piece.z, a[2], a[3], a[4], b[2], b[3], b[4]) <= reach then return true, true end
        end
    end
    return false, found
end

local function previousPoint(race, racer)
    if racer.gate >= 1 then
        local piece = T.at(race.track, racer.gate)
        return piece.x, piece.y, piece.z
    end
    local pose = poseFor(race, racer)
    return pose.x, pose.y, pose.z
end

function RS.gate(src, raceId, index, ms, retried)
    local race = RS.races[math.tointeger(tonumber(raceId)) or -1]
    local racer = race and race.racers[src]
    if not racer or race.state ~= 'racing' or racer.finished or racer.out then return end
    index, ms = math.tointeger(tonumber(index)), tonumber(ms)
    if not index or not RaceValidate.finite(ms) then return end
    if racer.retrying and not retried then
        if index > racer.retrying and index <= race.gates and racer.queued then racer.queued[index] = ms end
        return
    end
    racer.retrying = nil
    if index ~= racer.gate + 1 or index > race.gates then return end
    local elapsed = now() - race.startedAt
    local reject = nil
    if ms < racer.lastMs or ms > elapsed + 1500 or ms < elapsed - 3000 then reject = 'clock' end
    local piece = T.at(race.track, index)
    if not reject then
        local px, py, pz = previousPoint(race, racer)
        local minimum = G.distance(px, py, pz, piece.x, piece.y, piece.z) / Config.race.topSpeed * 1000.0
        if ms - racer.lastMs < minimum then reject = 'speed' end
    end
    if not reject then
        local kind = RaceCatalogue.pieces[piece.k]
        if not near(racer, piece, (kind.reach or 3.0) + 10.0, now() - 4000) then
            if not retried then
                racer.retrying, racer.queued = index, racer.queued or {}
                SetTimeout(400, function() RS.gate(src, raceId, index, ms, true) end)
                return
            end
            reject = 'position'
        end
    end
    if reject then
        racer.queued = nil
        racer.rejected = racer.rejected + 1
        send(src, 'gateRejected', race.id, racer.gate, reject)
        if Config.debug then print(('[%s] gate %d from %s rejected: %s'):format(RESOURCE, index, src, reject)) end
        return
    end
    racer.gate, racer.lastMs = index, ms
    racer.times[index] = ms
    if T.isLapLine(race.track, index) then
        racer.laps[#racer.laps + 1] = ms - racer.lastLap
        racer.lastLap = ms
    end
    if index == race.gates then
        if not race.track.loop then racer.laps[#racer.laps + 1] = ms end
        racer.finished, racer.total = true, ms
        racer.finishedAt = now()
        if racer.deployed then recall(src) end
        racer.deployed = false
        race.firstFinish = race.firstFinish or now()
        local place = 0
        for _, other in pairs(race.racers) do if other.finished then place = place + 1 end end
        if not race.draft then
            TriggerClientEvent(RESOURCE .. ':finished', -1, { track = race.track.id, place = place, colour = racer.colour })
        end
    end
    live(race)
    local queued = racer.queued
    local following = queued and queued[index + 1]
    if not following then racer.queued = nil return end
    queued[index + 1] = nil
    RS.gate(src, raceId, index + 1, following)
end

local function validPath(path)
    if type(path) ~= 'table' then return nil end
    local function ints(list, limit)
        if type(list) ~= 'table' or #list > PATH_LIMIT then return nil end
        local out = {}
        for i = 1, #list do
            local v = math.tointeger(list[i])
            if not v or v < -limit or v > limit then return nil end
            out[i] = v
        end
        return out
    end
    local x, y, z, v = ints(path.x, 2000000), ints(path.y, 2000000), ints(path.z, 2000000), ints(path.v, 2000)
    local dt = math.tointeger(path.dt)
    if not x or not y or not z or not v or not dt or dt < 50 or dt > 2000 then return nil end
    if #x ~= #y or #x ~= #z or #x ~= #v or #x < 2 then return nil end
    return { dt = dt, x = x, y = y, z = z, v = v }
end

function RS.path(src, raceId, path)
    local race = RS.races[math.tointeger(tonumber(raceId)) or -1]
    if not race then return end
    local racer = race.racers[src]
    if not racer or (racer.path and (racer.finished or racer.out or race.state ~= 'racing')) then return end
    racer.path = validPath(path) or racer.path
end

local function finish(race, reason)
    if race.state ~= 'racing' then return end
    race.state = 'results'
    race.resultsAt = now()
    for _, src in ipairs(racersOf(race)) do
        local racer = race.racers[src]
        if racer.deployed then recall(src); racer.deployed = false end
    end
    broadcast(race, 'ended', race.id)
    local deadline = now() + 6000
    while now() < deadline do
        local waiting = false
        for _, src in ipairs(racersOf(race)) do if not race.racers[src].path then waiting = true end end
        if not waiting then break end
        Wait(100)
    end
    if race.state ~= 'results' then return end
    local rows = standings(race)
    local prizes = {}
    if not race.trial and race.fee > 0 then
        prizes = E.settle(race, rows, function(src) return race.racers[src] or (race.gone and race.gone[src]) end)
    end
    if not race.draft and Db.ready then
        local winner = rows[1] and rows[1].finished and rows[1].src or nil
        for _, row in ipairs(rows) do
            local racer = race.racers[row.src] or (race.gone and race.gone[row.src])
            local clean = racer and racer.rejected <= 3
            if row.owner and (row.best or row.total) and clean then
                pcall(Db.recordTime, race.track.id, row.owner, row.name, row.best and math.floor(row.best) or nil,
                    row.finished and math.floor(row.total) or nil, race.laps, row.src == winner and not race.trial)
            end
        end
    end
    local results = { id = race.id, uid = race.uid, track = race.track.id, rev = race.track.rev, draft = race.draft, trial = race.trial, laps = race.laps,
        gates = race.gates, fee = race.fee, reason = reason, standings = {}, paths = {} }
    for _, row in ipairs(rows) do
        local racer = race.racers[row.src] or (race.gone and race.gone[row.src])
        results.standings[#results.standings + 1] = {
            id = row.id, name = row.name, colour = row.colour, place = row.place, finished = row.finished, total = row.total, best = row.best,
            laps = row.laps, gate = row.gate, prize = prizes[row.src] or 0,
        }
        if racer and racer.path then results.paths[tostring(row.id)] = racer.path end
    end
    for _, src in ipairs(racersOf(race)) do
        TriggerLatentClientEvent(RESOURCE .. ':results', src, 200000, results, race.draft and T.wire(race.track) or nil)
    end
    if Config.audit.races then
        local top = rows[1]
        RaceAudit.log('races', 'Race finished', { Race = race.uid, Track = race.track.name, Winner = top and top.finished and top.name or 'nobody', Reason = reason })
    end
    SetTimeout(math.floor(Config.race.resultsSeconds * 1000), function() close(race, 'done') end)
end
RS.finish = finish

function RS.watch(race)
    CreateThread(function()
        while RS.races[race.id] == race and race.state == 'racing' do
            sample(race)
            local at = now()
            local active, done = 0, 0
            for _, src in ipairs(racersOf(race)) do
                local racer = race.racers[src]
                if racer.finished or racer.out then
                    done = done + 1
                else
                    active = active + 1
                    if not GetPlayerName(tostring(src)) then RS.forfeit(src, race, 'dropped')
                    elseif racer.seenAt and at - racer.seenAt > 10000 then RS.forfeit(src, race, 'lost') end
                end
            end
            if active == 0 then CreateThread(function() finish(race, 'complete') end) break end
            if race.firstFinish and at - race.firstFinish > Config.race.dnfSeconds * 1000 then CreateThread(function() finish(race, 'time') end) break end
            if at - race.startedAt > Config.race.maxMinutes * 60000 then CreateThread(function() finish(race, 'limit') end) break end
            Wait(SAMPLE_MS)
        end
    end)
end

function RS.dropped(src)
    local race = RS.races[RS.bySrc[src] or -1]
    if not race then return end
    local racer = race.racers[src]
    if race.state == 'lobby' or race.state == 'deploying' or race.state == 'countdown' then
        leaveBeforeStart(src, race, 'dropped')
        return
    end
    if racer then
        race.gone = race.gone or {}
        if race.state == 'racing' then
            racer.out = true
            setProfile(src, nil)
        end
        race.gone[src] = racer
        race.racers[src] = nil
        if RS.bySrc[src] == race.id then RS.bySrc[src] = nil end
    end
end

function RS.unloaded(src)
    local race = RS.races[RS.bySrc[src] or -1]
    if not race then return end
    local before = race.state == 'lobby' or race.state == 'deploying' or race.state == 'countdown'
    if race.state == 'racing' then RS.forfeit(src, race, 'logout') end
    RS.dropped(src)
    if not before and GetPlayerName(tostring(src)) then send(src, 'left', race.id, 'logout') end
end

CreateThread(function()
    while true do
        Wait(5000)
        local at = now()
        for _, race in ipairs(RS.list()) do
            local ok, err = pcall(function()
                if race.state == 'lobby' and race.closesAt and at > race.closesAt then
                    close(race, 'expired')
                elseif race.state == 'lobby' then
                    pushLobby(race)
                elseif race.state == 'countdown' and race.goAt and at - race.goAt > 15000 then
                    close(race, 'stuck')
                elseif race.state == 'deploying' and race.deployAt and at - race.deployAt > Config.race.deploySeconds * 1000 + 15000 then
                    close(race, 'stuck')
                elseif race.state == 'racing' and race.startedAt and at - race.startedAt > Config.race.maxMinutes * 60000 + 30000 then
                    close(race, 'stuck')
                elseif race.state == 'results' and race.resultsAt and at - race.resultsAt > Config.race.resultsSeconds * 1000 + 30000 then
                    close(race, 'stuck')
                end
            end)
            if not ok then print(('^1[%s] race %s upkeep failed: %s^0'):format(RESOURCE, race.uid, tostring(err))) end
        end
    end
end)

function RS.list()
    local list = {}
    for _, race in pairs(RS.races) do list[#list + 1] = race end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

function RS.shutdown()
    for _, race in pairs(RS.races) do
        for _, src in ipairs(racersOf(race)) do
            if race.racers[src].deployed then recall(src) end
        end
    end
end
