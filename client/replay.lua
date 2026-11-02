RaceReplay = {}
local RP = RaceReplay
local RC, U, T, K, W, N = RaceClient, RaceUtil, RaceTrack, RaceCatalogue, RaceWorld, RaceNui
local RESOURCE = GetCurrentResourceName()
local KEYS = { prev = 174, next = 175, view = 22, speed = 21, exit = 194, exitAlt = 200 }

local ghost = nil
local watch = nil
local lastResults = nil

local function sample(path, i)
    local n = #path.x
    i = math.max(1, math.min(n, i))
    return path.x[i] * 0.1, path.y[i] * 0.1, path.z[i] * 0.1
end

local function catmull(a, b, c, d, t)
    local t2, t3 = t * t, t * t * t
    return 0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
end

function RP.at(path, ms)
    local f = ms / path.dt
    local i = math.floor(f) + 1
    local t = f - math.floor(f)
    local n = #path.x
    if i >= n then
        local x, y, z = sample(path, n)
        return x, y, z, true
    end
    local ax, ay, az = sample(path, i - 1)
    local bx, by, bz = sample(path, i)
    local cx, cy, cz = sample(path, i + 1)
    local dx, dy, dz = sample(path, i + 2)
    return catmull(ax, bx, cx, dx, t), catmull(ay, by, cy, dy, t), catmull(az, bz, cz, dz, t), false
end

function RP.duration(path) return (#path.x - 1) * path.dt end

local function speedAt(path, ms)
    local i = math.max(1, math.min(#path.v, math.floor(ms / path.dt) + 1))
    return path.v[i] * 0.1
end

local function makeGhost(colour, alpha)
    local hash = U.loadModel(Config.effects.ghostModel)
    if not hash then return 0 end
    local at = GetEntityCoords(PlayerPedId())
    local vehicle = CreateVehicle(hash, at.x, at.y, at.z - 50.0, 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if vehicle == 0 then return 0 end
    SetEntityCollision(vehicle, false, false)
    SetEntityInvincible(vehicle, true)
    FreezeEntityPosition(vehicle, true)
    SetVehicleEngineOn(vehicle, true, true, false)
    SetVehicleDoorsLocked(vehicle, 2)
    if alpha then SetEntityAlpha(vehicle, alpha, false) end
    local c = U.colour(colour)
    SetVehicleCustomPrimaryColour(vehicle, c[1], c[2], c[3])
    return vehicle
end

local function pose(vehicle, path, ms)
    local x, y, z, ended = RP.at(path, ms)
    local ax, ay = RP.at(path, math.max(0, ms - 120))
    local heading = GetEntityHeading(vehicle)
    if (x - ax) ^ 2 + (y - ay) ^ 2 > 0.01 then heading = (math.deg(math.atan(-(x - ax), y - ay)) + 360.0) % 360.0 end
    SetEntityCoordsNoOffset(vehicle, U.F(x), U.F(y), U.F(z), false, false, false)
    SetEntityRotation(vehicle, 0.0, 0.0, U.F(heading), 2, true)
    SetHeliBladesSpeed(vehicle, 1.0)
    return x, y, z, heading, ended
end

local function trail(vehicle, colour)
    local cfg = Config.effects.trail
    if not RC.prefs.trails or not U.ptfx(cfg.asset) then return nil end
    UseParticleFxAssetNextCall(cfg.asset)
    local handle = StartParticleFxLoopedOnEntity(cfg.name, vehicle, 0.0, -0.18, 0.0, 0.0, 0.0, 0.0, U.F(cfg.scale), false, false, false)
    if handle and handle ~= 0 then
        local c = U.colour(colour)
        SetParticleFxLoopedColour(handle, c[1] / 255.0, c[2] / 255.0, c[3] / 255.0, false)
    end
    return handle
end

function RP.startGhost(path, colour)
    RP.stopGhost()
    if type(path) ~= 'table' or type(path.x) ~= 'table' or #path.x < 2 then return nil end
    local vehicle = makeGhost(colour, 140)
    if vehicle == 0 then return nil end
    ghost = { vehicle = vehicle, path = path, start = U.now(), gen = (ghost and ghost.gen or 0) + 1 }
    local current = ghost
    CreateThread(function()
        while ghost == current and DoesEntityExist(vehicle) do
            local ms = U.now() - current.start
            local _, _, _, _, ended = pose(vehicle, path, math.min(ms, RP.duration(path)))
            local mine = RC.race and RC.race.entity
            if mine and DoesEntityExist(mine) then SetEntityNoCollisionEntity(mine, vehicle, true) end
            if ended then SetEntityVisible(vehicle, false, false) else SetEntityVisible(vehicle, true, false) end
            Wait(0)
        end
    end)
    return ghost
end

function RP.restartGhost(handle)
    if ghost and ghost == handle then ghost.start = U.now() end
end

function RP.stopGhost()
    if not ghost then return end
    U.deleteEntity(ghost.vehicle)
    ghost = nil
end

local function wirePath(path)
    if type(path) ~= 'table' or type(path.x) ~= 'table' then return nil end
    local points = {}
    for i = 1, #path.x do
        points[i] = { path.x[i] * 0.1, path.y[i] * 0.1, path.z[i] * 0.1, path.v[i] * 0.1 }
    end
    return { dt = path.dt, points = points }
end

local function wireTrack(track)
    local checkpoints, props = {}, {}
    for i, p in ipairs(track.checkpoints) do
        local kind = K.pieces[p.k]
        checkpoints[i] = { k = p.k, x = p.x, y = p.y, z = p.z, h = p.h, p = p.p, w = kind.w or (kind.r and kind.r * 2) or 3.0 }
    end
    for _, p in ipairs(track.props) do
        if p.k == 'pad' or p.k == 'pylon' or p.k == 'burner' or p.k == 'trough' or p.k == 'gantry' then props[#props + 1] = { k = p.k, x = p.x, y = p.y, h = p.h } end
    end
    return { name = track.name, loop = track.loop, checkpoints = checkpoints, props = props }
end

local function resultTrack(data, draftTrack)
    if not data.draft then return W.fetch(data.track, data.rev) end
    if RC.cache.draft then return RC.cache.draft end
    if type(draftTrack) ~= 'table' then return nil end
    local normalized = T.normalize(draftTrack, { maxCheckpoints = 200, maxProps = 400, maxSpan = 10000.0 })
    if not normalized then return nil end
    normalized.id = 'draft'
    return W.install(normalized)
end

local function results(data, draftTrack)
    local track = resultTrack(data, draftTrack)
    if not track then return end
    lastResults = { data = data, track = track }
    local me = GetPlayerServerId(PlayerId())
    local standings = {}
    for _, row in ipairs(type(data.standings) == 'table' and data.standings or {}) do
        standings[#standings + 1] = {
            id = row.id, name = row.name, colour = U.hex(row.colour), place = row.place, finished = row.finished == true, total = row.total,
            best = row.best, laps = type(row.laps) == 'table' and row.laps or {}, prize = row.prize or 0, me = row.id == me,
            path = wirePath(type(data.paths) == 'table' and data.paths[tostring(row.id)]),
        }
    end
    N.send('race:results', {
        track = wireTrack(track), standings = standings, laps = data.laps, trial = data.trial == true, fee = data.fee or 0,
        account = Config.economy.account,
    })
    N.focus('results')
end

RegisterNetEvent(RESOURCE .. ':results', function(data, draftTrack)
    if type(data) ~= 'table' then return end
    if RC.race and RC.race.id == data.id then RaceRun.finishLocal('results') end
    CreateThread(function() results(data, draftTrack) end)
end)

N.on('close', function()
    N.release('results')
    N.send('race:resultsHide')
end)

local function stopWatch()
    local w = watch
    if not w then return end
    watch = nil
    for _, g in ipairs(w.ghosts) do
        if g.trail then StopParticleFxLooped(g.trail, false) end
        U.deleteEntity(g.vehicle)
    end
    RenderScriptCams(false, true, 400, true, true)
    if w.cam then DestroyCam(w.cam, false) end
    ClearFocus()
    FreezeEntityPosition(PlayerPedId(), false)
    W.force('replay', nil)
    RC.replaying = false
    N.send('replay:hide')
    if lib and lib.hideHelp then lib.hideHelp() end
    U.hud(true)
end
RP.stopWatch = stopWatch

local function watchLoop(w)
    CreateThread(function()
        local camPos, lastNow = nil, U.now()
        while watch == w do
            local now = U.now()
            local dt = (now - lastNow) * w.speed
            lastNow = now
            w.time = w.time + dt
            DisableAllControlActions(0)
            local focusX, focusY, focusZ, focusH
            local allEnded = true
            for i, g in ipairs(w.ghosts) do
                local x, y, z, h, ended = pose(g.vehicle, g.path, math.min(w.time, RP.duration(g.path)))
                if not ended then allEnded = false end
                if i == w.index then focusX, focusY, focusZ, focusH = x, y, z, h end
            end
            if allEnded and w.time > 1000 then w.time = 0 end
            if focusX then
                local target
                if w.view == 'chase' then
                    local r = math.rad(focusH)
                    target = vector3(focusX + math.sin(r) * 6.0, focusY - math.cos(r) * 6.0, focusZ + 2.2)
                else
                    local c = w.track.centre
                    target = vector3(c.x + (focusX - c.x) * 0.25 - 30.0, c.y + (focusY - c.y) * 0.25 - 30.0, c.z + 70.0)
                end
                camPos = camPos and camPos + (target - camPos) * math.min(1.0, dt / 1000.0 * 4.0) or target
                SetCamCoord(w.cam, camPos.x, camPos.y, camPos.z)
                PointCamAtCoord(w.cam, U.F(focusX), U.F(focusY), U.F(focusZ))
                SetFocusPosAndVel(camPos.x, camPos.y, camPos.z, 0.0, 0.0, 0.0)
            end
            if IsDisabledControlJustPressed(0, KEYS.next) then w.index = w.index % #w.ghosts + 1 end
            if IsDisabledControlJustPressed(0, KEYS.prev) then w.index = (w.index - 2) % #w.ghosts + 1 end
            if IsDisabledControlJustPressed(0, KEYS.view) then w.view = w.view == 'chase' and 'sky' or 'chase' end
            if IsDisabledControlJustPressed(0, KEYS.speed) then w.speed = w.speed == 1.0 and 2.0 or (w.speed == 2.0 and 0.5 or 1.0) end
            if IsDisabledControlJustPressed(0, KEYS.exit) or IsDisabledControlJustPressed(0, KEYS.exitAlt) then
                stopWatch()
                break
            end
            local g = w.ghosts[w.index]
            local signature = ('%d|%d|%s|%s'):format(w.index, math.floor(w.time / 100), w.view, w.speed)
            N.state('replay:state', {
                name = g.name, colour = g.hex, time = math.floor(w.time), total = math.floor(RP.duration(g.path)), index = w.index, count = #w.ghosts,
                speed = w.speed, view = w.view, kmh = math.floor(speedAt(g.path, w.time) * 3.6 + 0.5),
            }, signature)
            Wait(0)
        end
    end)
end

local function startWatch(focusId)
    if watch or not lastResults or RC.race or RC.editing then return end
    local data, track = lastResults.data, lastResults.track
    local ghosts = {}
    for _, row in ipairs(type(data.standings) == 'table' and data.standings or {}) do
        local path = type(data.paths) == 'table' and data.paths[tostring(row.id)]
        if type(path) == 'table' and type(path.x) == 'table' and #path.x > 1 then
            local vehicle = makeGhost(row.colour)
            if vehicle ~= 0 then
                ghosts[#ghosts + 1] = { id = row.id, name = row.name, colour = row.colour, hex = U.hex(row.colour), path = path, vehicle = vehicle }
            end
        end
    end
    if #ghosts == 0 then U.notify('replay.empty', 'info') return end
    N.release('results')
    N.send('race:resultsHide')
    W.force('replay', track)
    RC.replaying = true
    U.hud(false)
    FreezeEntityPosition(PlayerPedId(), true)
    local w = { ghosts = ghosts, track = track, time = 0, speed = 1.0, view = 'chase', index = 1 }
    for i, g in ipairs(ghosts) do
        g.trail = trail(g.vehicle, g.colour)
        if g.id == focusId then w.index = i end
    end
    w.cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamFov(w.cam, 55.0)
    RenderScriptCams(true, true, 500, true, true)
    watch = w
    if lib and lib.showHelp then
        lib.showHelp({
            { label = L('help.replay_racer'), value = 'LEFT RIGHT' }, { label = L('help.replay_view'), value = 'SPACE' },
            { label = L('help.replay_speed'), value = 'SHIFT' }, { label = L('help.replay_exit'), value = 'BACKSPACE' },
        })
    end
    watchLoop(w)
end

N.on('replay', function(data)
    CreateThread(function() startWatch(tonumber(data.id)) end)
end)

AddEventHandler('onClientResourceStop', function(name)
    if name ~= RESOURCE then return end
    pcall(RP.stopGhost)
    pcall(stopWatch)
end)
