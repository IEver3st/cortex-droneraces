RaceRun = {}
local R = RaceRun
local RC, U, T, G, K, W, FX, N = RaceClient, RaceUtil, RaceTrack, RaceGeometry, RaceCatalogue, RaceWorld, RaceFx, RaceNui
local RESOURCE = GetCurrentResourceName()
local DRONE = 'cortex-drone'
local SAMPLE_MS = 200
local PB_PREFIX = 'droneraces:pb:'

local loopGen = 0

local function drone(race)
    local info = U.drone()
    if info and info.entity and DoesEntityExist(info.entity) then race.entity = info.entity end
    return race.entity
end

local function droneCall(name, ...)
    local args = { ... }
    local ok, result = pcall(function() return exports[DRONE][name](exports[DRONE], table.unpack(args)) end)
    if not ok and Config.debug then print(('[%s] cortex-drone %s failed: %s'):format(RESOURCE, name, tostring(result))) end
    return ok and result
end

local function readPb(trackId)
    local raw = GetResourceKvpString(PB_PREFIX .. trackId)
    if not raw then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' or type(data.ms) ~= 'number' or type(data.splits) ~= 'table' then return nil end
    return data
end

local function writePb(trackId, data)
    SetResourceKvp(PB_PREFIX .. trackId, json.encode(data))
end

local function perLap(track) return track.loop and #track.checkpoints or #track.checkpoints end

local function lapOf(race, index)
    local _, lap, slot = T.at(race.track, index)
    return lap, slot or index
end

local function hudState(race, now)
    local elapsed = race.t0 and (now - race.t0) or 0
    if race.finishedMs then elapsed = race.finishedMs end
    local nextIndex = math.min(race.gate + 1, race.gates)
    local lap, slot = lapOf(race, nextIndex)
    if race.track.loop and race.gate >= race.gates then lap = race.laps end
    local place, count = 1, 1
    local rows = {}
    if race.standings then
        count = #race.standings
        local mine = { gate = race.gate, ms = race.lastMs or 0 }
        local sorted = {}
        for _, row in ipairs(race.standings) do
            local entry = { id = row.id, name = row.name, colour = U.hex(row.colour), gate = row.gate, ms = row.ms, finished = row.finished, total = row.total }
            if row.id == race.me then entry.gate, entry.ms, entry.me = math.max(row.gate, mine.gate), row.gate >= mine.gate and row.ms or mine.ms, true end
            sorted[#sorted + 1] = entry
        end
        table.sort(sorted, function(a, b)
            if a.finished ~= b.finished then return a.finished end
            if a.finished then return (a.total or 0) < (b.total or 0) end
            if a.gate ~= b.gate then return a.gate > b.gate end
            return a.ms < b.ms
        end)
        for i, entry in ipairs(sorted) do
            if entry.me then place = i end
            rows[#rows + 1] = { name = entry.name, colour = entry.colour, me = entry.me == true, done = entry.finished == true }
        end
    end
    local nextPiece = T.at(race.track, nextIndex)
    local distance = 0
    if nextPiece and race.pos then distance = G.distance(race.pos.x, race.pos.y, race.pos.z, nextPiece.x, nextPiece.y, nextPiece.z) end
    local respawn = race.respawnAt and math.max(0, race.respawnAt - now) or nil
    return {
        state = race.state, place = place, count = count, lap = math.min(lap, race.laps), laps = race.laps, loop = race.track.loop,
        gate = slot, perLap = perLap(race.track), time = math.max(0, elapsed), best = race.bestLap, last = race.lastLapMs,
        split = race.split and now - race.split.at < 2600 and race.split.delta or nil, next = math.floor(distance + 0.5),
        respawn = respawn, racers = rows, trial = race.trial, colour = U.hex(race.colour),
        countdown = race.countdownEnds and math.max(0, math.ceil((race.countdownEnds - now) / 1000)) or nil,
    }, table.concat({ race.state, place, count, lap, slot, math.floor(elapsed / 100), race.bestLap or '-', race.lastLapMs or '-',
        race.split and race.split.at or '-', math.floor(distance), respawn and math.ceil(respawn / 100) or '-', #rows,
        race.countdownEnds and math.ceil((race.countdownEnds - now) / 1000) or '-', race.standingsRev or 0 }, '|')
end

local function pushHud(race, now)
    local state, signature = hudState(race, now)
    N.state('race:hud', state, signature)
end

local function record(race, now, entity)
    if not race.path or now < race.nextSample then return end
    race.nextSample = now + SAMPLE_MS
    local p = race.pos
    local path = race.path
    if #path.x >= 6000 then return end
    path.x[#path.x + 1] = math.floor(p.x * 10 + 0.5)
    path.y[#path.y + 1] = math.floor(p.y * 10 + 0.5)
    path.z[#path.z + 1] = math.floor(p.z * 10 + 0.5)
    path.v[#path.v + 1] = math.floor(GetEntitySpeed(entity) * 10 + 0.5)
end

local function uploadPath(race)
    if race.uploaded or not race.path or #race.path.x < 2 then return end
    race.uploaded = true
    TriggerLatentServerEvent(RESOURCE .. ':path', 60000, race.id, race.path)
end

local function lapPath(race, fromMs, toMs)
    local p = race.path
    local first = math.max(1, math.floor(fromMs / SAMPLE_MS) + 1)
    local last = math.min(#p.x, math.floor(toMs / SAMPLE_MS) + 1)
    local out = { dt = SAMPLE_MS, x = {}, y = {}, z = {}, v = {} }
    for i = first, last do
        out.x[#out.x + 1], out.y[#out.y + 1], out.z[#out.z + 1], out.v[#out.v + 1] = p.x[i], p.y[i], p.z[i], p.v[i]
    end
    return out, (first - 1) * SAMPLE_MS - fromMs
end

local function onLap(race, lapMs, startMs, endMs)
    race.lastLapMs = lapMs
    if not race.bestLap or lapMs < race.bestLap then race.bestLap = lapMs end
    if race.track.id == 'draft' then return end
    local pb = race.pb
    if not pb or lapMs < pb.ms then
        local path, offset = lapPath(race, startMs, endMs)
        local splits = {}
        for i, value in ipairs(race.lapSplits) do splits[i] = value end
        race.pb = { ms = lapMs, splits = splits, path = path, offset = offset }
        writePb(race.track.id, race.pb)
        U.notify('notify.personal_best', 'success', { time = U.formatTime(lapMs) })
    end
end

local function passGate(race, index, ms)
    race.gate = index
    race.lastMs = ms
    TriggerServerEvent(RESOURCE .. ':gate', race.id, index, math.floor(ms))
    local piece = T.at(race.track, index)
    FX.flames(race.track.id, piece, 14.0)
    local lap, slot = lapOf(race, index)
    local lapStart = race.lapStart or 0
    local within = ms - lapStart
    if race.track.loop then
        if T.isLapLine(race.track, index) then
            onLap(race, ms - lapStart, lapStart, ms)
            race.lapStart = ms
            race.lapSplits = {}
            if race.pbGhost then RaceReplay.restartGhost(race.pbGhost) end
        else
            race.lapSplits[slot] = within
            local reference = race.pb and race.pb.splits and race.pb.splits[slot]
            if reference then race.split = { delta = within - reference, at = U.now() } end
        end
    else
        race.lapSplits[slot] = ms
        local reference = race.pb and race.pb.splits and race.pb.splits[slot]
        if reference then race.split = { delta = ms - reference, at = U.now() } end
    end
    if index >= race.gates then
        if not race.track.loop then onLap(race, ms, 0, ms) end
        race.state = 'finished'
        race.finishedMs = ms
        U.sound('FIRST_PLACE')
        uploadPath(race)
        RaceReplay.stopGhost()
    elseif T.isLapLine(race.track, index) then
        U.sound('CHECKPOINT_PERFECT')
    else
        U.sound('CHECKPOINT_NORMAL')
    end
end

local function drawMarkers(race)
    local r, g, b = U.accent()
    for offset = 1, 2 do
        local piece = T.at(race.track, race.gate + offset)
        if not piece or race.gate + offset > race.gates then break end
        local kind = K.pieces[piece.k]
        local top = (kind.h and kind.h * 0.5) or kind.r or 2.0
        local alpha = offset == 1 and 220 or 90
        local size = offset == 1 and 1.1 or 0.7
        DrawMarker(2, U.F(piece.x), U.F(piece.y), U.F(piece.z + top + 1.6), 0.0, 0.0, 0.0, 180.0, 0.0, 0.0, size, size, size,
            r, g, b, alpha, true, true, 2, false, nil, nil, false)
        if offset == 1 then
            DrawLightWithRange(U.F(piece.x), U.F(piece.y), U.F(piece.z), r, g, b, 7.0, 4.0)
        end
    end
end

local function respawnPose(race)
    if race.gate >= 1 then
        local piece = T.at(race.track, race.gate)
        local x, y, z, h = G.respawn(piece, 3.5)
        local ground = U.ground(x, y, z)
        if ground and z < ground + 1.2 then z = ground + 1.2 end
        return x, y, z, h
    end
    local pose = race.pose
    return pose.x, pose.y, pose.z + 0.6, pose.w
end

local function respawn(race)
    local x, y, z, h = respawnPose(race)
    if not droneCall('RaceRespawn', U.F(x), U.F(y), U.F(z), U.F(h)) then
        race.respawnAt = U.piloting() and U.now() + 500 or nil
        return
    end
    race.prev, race.prevAt = vector3(x, y, z), U.now()
    race.respawnAt = nil
end

local function stopLoop() loopGen = loopGen + 1 end

local function finishLocal(reason)
    local race = RC.race
    if not race then return end
    stopLoop()
    RC.race = nil
    RaceReplay.stopGhost()
    FX.lamps(nil)
    droneCall('RaceHold', false)
    W.force('race', nil)
    N.send('race:hide')
    N.forget('race:hud')
    U.hud(true)
    if reason and reason ~= 'results' then U.notify('race.left_' .. reason, 'info') end
end
R.finishLocal = finishLocal

local function raceLoop(race)
    stopLoop()
    local gen = loopGen
    CreateThread(function()
        local nextHud = 0
        local lostSince = nil
        while gen == loopGen and RC.race == race do
            local now = U.now()
            local entity = drone(race)
            if entity and DoesEntityExist(entity) then
                local p = GetEntityCoords(entity)
                race.pos = p
                if race.state == 'racing' then
                    if not race.respawnAt then
                        local prev = race.prev or p
                        local nextIndex = race.gate + 1
                        local piece = T.at(race.track, nextIndex)
                        if piece and nextIndex <= race.gates then
                            local t = G.crossing(piece, K.pieces[piece.k], prev.x, prev.y, prev.z, p.x, p.y, p.z, 0.2)
                            if t then
                                local before = race.prevAt or now
                                passGate(race, nextIndex, (before + (now - before) * t) - race.t0)
                            end
                        end
                    end
                    race.prev, race.prevAt = p, now
                    record(race, now, entity)
                    drawMarkers(race)
                    if Config.race.ghosting then
                        for other in pairs(FX.racers()) do
                            if other ~= entity and DoesEntityExist(other) then SetEntityNoCollisionEntity(entity, other, true) end
                        end
                    end
                end
                if (race.state == 'racing' or race.state == 'finished') and race.respawnAt and now >= race.respawnAt then respawn(race) end
            end
            if race.state == 'racing' and not race.respawnAt and not U.piloting() then
                lostSince = lostSince or now
                if now - lostSince > 1500 then
                    race.state = 'out'
                    TriggerServerEvent(RESOURCE .. ':forfeit')
                    uploadPath(race)
                    U.notify('race.forfeit', 'info')
                end
            else
                lostSince = nil
            end
            if now >= nextHud then
                nextHud = now + 100
                pushHud(race, now)
            end
            Wait(0)
        end
    end)
end

AddEventHandler('cortex-drone:raceCrashed', function()
    local race = RC.race
    if not race then return end
    if race.state == 'racing' then
        race.respawnAt = U.now() + math.floor(Config.race.respawnPenalty * 1000)
        U.sound('CHECKPOINT_MISSED')
    elseif race.state == 'finished' then
        race.respawnAt = U.now()
    end
end)

RegisterNetEvent(RESOURCE .. ':lobby', function(view)
    if type(view) ~= 'table' then return end
    RC.lobby = view
    if RC.race then return end
    local racers = {}
    for i, row in ipairs(type(view.racers) == 'table' and view.racers or {}) do
        racers[i] = { id = row.id, name = row.name, colour = U.hex(row.colour), host = row.host == true }
    end
    N.send('race:lobby', {
        id = view.id, name = view.name, laps = view.laps, loop = view.loop, fee = view.fee, pot = view.pot, max = view.max, closes = view.closes, racers = racers,
    })
end)

RegisterNetEvent(RESOURCE .. ':left', function(raceId, reason)
    if RC.lobby and RC.lobby.id == raceId then
        RC.lobby = nil
        N.send('race:lobbyHide')
    end
    if RC.race and RC.race.id == raceId then finishLocal(type(reason) == 'string' and reason or 'left') end
    if reason == 'expired' or reason == 'cancelled' then U.notify('race.left_' .. reason, 'info') end
end)

RegisterNetEvent(RESOURCE .. ':lobbyOpened', function(data)
    if type(data) ~= 'table' or RC.race or RC.lobby then return end
    local summary = RC.tracks[data.track]
    if not summary then return end
    if #(GetEntityCoords(PlayerPedId()) - vector3(summary.x, summary.y, summary.z)) > 350.0 then return end
    U.notify('race.lobby_open', 'info', { name = summary.name, key = Config.keys.menu })
end)

RegisterNetEvent(RESOURCE .. ':deploy', function(data)
    if type(data) ~= 'table' or RC.race then return end
    local track = data.draft and RC.cache.draft or W.fetch(data.track, data.rev)
    if not track then
        U.notify('error.no_track')
        TriggerServerEvent(RESOURCE .. ':forfeit')
        return
    end
    RC.lobby = nil
    N.send('race:lobbyHide')
    local pose = type(data.pose) == 'table' and data.pose or { x = track.start.x, y = track.start.y, z = track.start.z, w = 0.0 }
    local race = {
        id = data.id, track = track, laps = tonumber(data.laps) or 1, gates = tonumber(data.gates) or T.gateCount(track, tonumber(data.laps) or 1),
        slot = data.slot, colour = data.colour, trial = data.trial == true, pose = pose, state = 'deploying', gate = 0, lastMs = 0,
        me = GetPlayerServerId(PlayerId()), lapSplits = {}, lapStart = 0,
    }
    race.pb = readPb(track.id)
    RC.race = race
    W.force('race', track)
    U.hud(false)
    N.send('race:start', { trial = race.trial, colour = U.hex(race.colour), laps = race.laps, name = track.name })
    raceLoop(race)
    CreateThread(function()
        droneCall('DeployRace', Config.drone)
        local deadline = U.now() + math.floor(Config.race.deploySeconds * 1000)
        while RC.race == race and race.state == 'deploying' do
            local entity = drone(race)
            if entity and U.piloting() then
                droneCall('RaceHold', true)
                TriggerServerEvent(RESOURCE .. ':ready', race.id)
                race.state = 'staged'
                break
            end
            if U.now() > deadline then
                U.notify('race.deploy_failed')
                break
            end
            Wait(200)
        end
    end)
end)

RegisterNetEvent(RESOURCE .. ':countdown', function(data)
    local race = RC.race
    if not race or type(data) ~= 'table' or data.id ~= race.id then return end
    race.state = 'countdown'
    local seconds = tonumber(data.seconds) or 5
    race.countdownEnds = U.now() + seconds * 1000
    race.standings = {}
    for _, row in ipairs(type(data.roster) == 'table' and data.roster or {}) do
        race.standings[#race.standings + 1] = { id = row.id, name = row.name, colour = row.colour, gate = 0, ms = 0 }
    end
    droneCall('RaceHold', true, true)
    CreateThread(function()
        for i = 1, seconds do
            if RC.race ~= race or race.state ~= 'countdown' then return end
            FX.lamps(race.track.id, i, false)
            U.sound('3_2_1')
            Wait(1000)
        end
    end)
end)

RegisterNetEvent(RESOURCE .. ':go', function(raceId)
    local race = RC.race
    if not race or race.id ~= raceId then return end
    race.state = 'racing'
    race.t0 = U.now()
    race.countdownEnds = nil
    race.nextSample = race.t0
    race.path = { dt = SAMPLE_MS, x = {}, y = {}, z = {}, v = {} }
    race.prev, race.prevAt = nil, nil
    if not droneCall('RaceGo') then droneCall('RaceHold', false) end
    FX.lamps(race.track.id, 0, true)
    SetTimeout(2500, function() if RC.race == race then FX.lamps(nil) end end)
    FX.flames(race.track.id)
    U.sound('GO')
    if race.trial and race.pb and race.pb.path and race.track.loop then
        race.pbGhost = RaceReplay.startGhost(race.pb.path, race.colour)
    end
end)

RegisterNetEvent(RESOURCE .. ':standings', function(raceId, view)
    local race = RC.race
    if not race or race.id ~= raceId or type(view) ~= 'table' then return end
    race.standings = view
    race.standingsRev = (race.standingsRev or 0) + 1
end)

RegisterNetEvent(RESOURCE .. ':gateRejected', function(raceId, gate, reason)
    local race = RC.race
    if not race or race.id ~= raceId or (race.state ~= 'racing' and race.state ~= 'finished') then return end
    if race.state == 'finished' then
        race.state, race.finishedMs, race.uploaded = 'racing', nil, false
    end
    race.gate = math.tointeger(tonumber(gate)) or race.gate
    U.notify('race.gate_rejected', 'error')
    if Config.debug then print(('[%s] gate rejected: %s'):format(RESOURCE, tostring(reason))) end
end)

RegisterNetEvent(RESOURCE .. ':ended', function(raceId)
    local race = RC.race
    if not race or race.id ~= raceId then return end
    if race.state == 'racing' then race.state = 'out' end
    uploadPath(race)
end)

function R.forfeit()
    local race = RC.race
    if not race then return end
    TriggerServerEvent(RESOURCE .. ':forfeit')
    if race.state ~= 'finished' then race.state = 'out' end
    uploadPath(race)
    droneCall('Disconnect')
end

AddEventHandler('onClientResourceStop', function(name)
    if name ~= RESOURCE then return end
    stopLoop()
    if RC.race then
        pcall(droneCall, 'RaceHold', false)
        pcall(U.hud, true)
    end
end)
