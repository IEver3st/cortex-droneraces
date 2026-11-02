RaceWorld = {}
local W = RaceWorld
local RC, U, T, K, G = RaceClient, RaceUtil, RaceTrack, RaceCatalogue, RaceGeometry
local RESOURCE = GetCurrentResourceName()
local PROMPT = 'droneraces'

local spawned = {}
local forced = {}
local hidden = {}
local blips = {}
local fetching = {}
local lit = {}
local lightGen = 0
local promptShown = false
W.near = nil

function W.fetch(id, rev)
    if id == 'draft' then return RC.cache.draft end
    local cached = RC.cache[id]
    if cached and (not rev or cached.rev == rev) then return cached end
    if fetching[id] then
        local deadline = U.now() + 6000
        while fetching[id] and U.now() < deadline do Wait(50) end
        cached = RC.cache[id]
        if cached and (not rev or cached.rev == rev) then return cached end
    end
    fetching[id] = true
    local result = U.call('track', id)
    fetching[id] = nil
    if not result or not result.ok or type(result.data) ~= 'table' then return cached end
    local track, err = T.normalize(result.data, { maxCheckpoints = 200, maxProps = 400, maxSpan = 10000.0 })
    if not track then
        if Config.debug then print(('[%s] track %s rejected: %s'):format(RESOURCE, id, err)) end
        return cached
    end
    track.id, track.rev, track.author, track.builtin = result.data.id, result.data.rev, result.data.author, result.data.builtin
    T.derive(track)
    RC.cache[id] = track
    return track
end

function W.install(track)
    T.derive(track)
    RC.cache[track.id] = track
    return track
end

local function pieceList(track)
    local list = {}
    for i, p in ipairs(track.checkpoints) do list[#list + 1] = { piece = p, kind = K.pieces[p.k], index = i } end
    for _, p in ipairs(track.props) do list[#list + 1] = { piece = p, kind = K.pieces[p.k] } end
    return list
end

function W.place(entity, piece)
    SetEntityCoordsNoOffset(entity, U.F(piece.x), U.F(piece.y), U.F(piece.z), false, false, false)
    SetEntityRotation(entity, U.F(piece.p), 0.0, U.F(piece.h), 2, true)
end

local MIN_GAP, MAX_GAP = 0.6, 80.0
local supports = {}
local unsupported = {}
local groundAt = {}

local function spawnSupport(hash, x, y, z)
    if not U.loadModel(hash) then return nil end
    local entity = CreateObjectNoOffset(hash, U.F(x), U.F(y), U.F(z), false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if entity == 0 then return nil end
    FreezeEntityPosition(entity, true)
    SetEntityLodDist(entity, 500)
    SetEntityInvincible(entity, true)
    return entity
end

local function support(entity, kind)
    if not DoesEntityExist(entity) then return true end
    local top = GetOffsetFromEntityInWorldCoords(entity, 0.0, 0.0, -U.F(kind.ground))
    local found, ground = GetGroundZFor_3dCoord(top.x, top.y, top.z, false)
    if not found then return false end
    groundAt[entity] = ground
    local gap = top.z - ground
    local parts = {}
    if gap >= MIN_GAP and gap <= MAX_GAP then
        local z, left = top.z, gap - K.foot.height
        while left > 0 do
            local pick = K.masts[#K.masts]
            for _, mast in ipairs(K.masts) do
                if mast.length <= left then pick = mast break end
            end
            parts[#parts + 1] = spawnSupport(pick.hash, top.x, top.y, z)
            z, left = z - pick.length, left - pick.length
        end
        parts[#parts + 1] = spawnSupport(K.foot.hash, top.x, top.y, ground)
    end
    supports[entity] = parts
    return true
end

local function retrySupports()
    local budget = 6
    for entity, kind in pairs(unsupported) do
        if budget == 0 then return end
        budget = budget - 1
        if support(entity, kind) then unsupported[entity] = nil end
    end
end

function W.spawnPiece(piece, kind, alpha)
    local hash = U.loadModel(kind.hash)
    if not hash then return 0 end
    local entity = CreateObjectNoOffset(hash, U.F(piece.x), U.F(piece.y), U.F(piece.z), false, false, false)
    if entity == 0 then return 0 end
    W.place(entity, piece)
    FreezeEntityPosition(entity, true)
    SetEntityLodDist(entity, 500)
    SetEntityInvincible(entity, true)
    if alpha then SetEntityAlpha(entity, alpha, false) end
    if kind.mast and not alpha and not support(entity, kind) then unsupported[entity] = kind end
    return entity
end

function W.removePiece(entity)
    if not entity then return end
    unsupported[entity] = nil
    groundAt[entity] = nil
    for _, part in ipairs(supports[entity] or {}) do U.deleteEntity(part) end
    supports[entity] = nil
    U.deleteEntity(entity)
end

local function despawn(id)
    local record = spawned[id]
    if not record then return end
    spawned[id] = nil
    for _, item in ipairs(record.items) do
        if item.entity then W.removePiece(item.entity) end
    end
    TriggerEvent(RESOURCE .. ':despawned', id)
end

local function spawn(track)
    local record = { track = track, rev = track.rev, items = pieceList(track), ready = false }
    spawned[track.id] = record
    CreateThread(function()
        for i, item in ipairs(record.items) do
            if spawned[track.id] ~= record then return end
            if item.kind then item.entity = W.spawnPiece(item.piece, item.kind) end
            if i % 4 == 0 then Wait(0) end
        end
        for _, item in ipairs(record.items) do SetModelAsNoLongerNeeded(item.kind.hash) end
        record.ready = true
        TriggerEvent(RESOURCE .. ':spawned', track.id)
    end)
end

function W.record(id) return spawned[id] end

function W.hide(id, on)
    if not id then return end
    hidden[id] = on and true or nil
    if on and spawned[id] then despawn(id) end
end

function W.force(key, track)
    forced[key] = track
    if track then
        local current = spawned[track.id]
        if current and current.track ~= track then despawn(track.id) end
    end
end

local function visibleTracks()
    local list = {}
    for _, track in pairs(forced) do list[track.id] = track end
    for id, summary in pairs(RC.tracks) do
        if not list[id] and not hidden[id] and (summary.always or (RC.active[id] or 0) > 0) then list[id] = true end
    end
    return list
end

local function lightLoop()
    lightGen = lightGen + 1
    local gen = lightGen
    CreateThread(function()
        local nextPick = 0
        local L = Config.effects.lights
        while gen == lightGen do
            local now = U.now()
            if now >= nextPick then
                nextPick = now + 500
                lit = {}
                if RC.prefs.lights and L.count > 0 then
                    local cam = U.camera()
                    local candidates = {}
                    for _, record in pairs(spawned) do
                        for _, item in ipairs(record.items) do
                            local kind = item.kind
                            if kind and kind.light then
                                local p = item.piece
                                local x, y, z = p.x, p.y, p.z
                                if kind.glow then x, y, z = G.toWorld(p, kind.glow.x, kind.glow.y, kind.glow.z) end
                                local d = #(cam - vector3(x, y, z))
                                if d < L.distance then
                                    if not kind.aim then
                                        if item.ground == nil then
                                            if kind.mast then item.ground = item.entity and groundAt[item.entity]
                                            else item.ground = p.z - (kind.ground or 0.0) end
                                        end
                                        if item.ground then z = math.min(z, item.ground + L.pool) end
                                    end
                                    local light = { d = d, x = x, y = y, z = z, c = kind.light }
                                    if kind.aim then
                                        local ax, ay, az = G.toWorld(p, kind.aim.x, kind.aim.y, kind.aim.z)
                                        light.dx, light.dy, light.dz = ax - p.x, ay - p.y, az - p.z
                                    end
                                    candidates[#candidates + 1] = light
                                end
                            end
                        end
                    end
                    table.sort(candidates, function(a, b) return a.d < b.d end)
                    for i = 1, math.min(L.count, #candidates) do lit[i] = candidates[i] end
                end
                if next(spawned) == nil then break end
            end
            if #lit > 0 then SetLightsCutoffDistanceTweak(U.F(L.distance)) end
            for i = 1, #lit do
                local l = lit[i]
                if l.dx then
                    local S = L.flood
                    DrawSpotLight(U.F(l.x), U.F(l.y), U.F(l.z), U.F(l.dx), U.F(l.dy), U.F(l.dz), U.I(l.c[1]), U.I(l.c[2]), U.I(l.c[3]),
                        U.F(S.distance), U.F(S.brightness), U.F(S.hardness), U.F(S.radius), U.F(S.falloff))
                else
                    DrawLightWithRange(U.F(l.x), U.F(l.y), U.F(l.z), U.I(l.c[1]), U.I(l.c[2]), U.I(l.c[3]), U.F(L.range), U.F(L.intensity))
                end
            end
            Wait(#lit > 0 and 0 or 500)
        end
        lit = {}
    end)
end

local function rebuildBlips()
    for _, blip in pairs(blips) do RemoveBlip(blip) end
    blips = {}
    if not Config.blips.enabled then return end
    for id, summary in pairs(RC.tracks) do
        local blip = AddBlipForCoord(U.F(summary.x), U.F(summary.y), U.F(summary.z))
        SetBlipSprite(blip, Config.blips.sprite)
        SetBlipColour(blip, Config.blips.colour)
        SetBlipScale(blip, U.F(Config.blips.scale))
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(L('blip.track', { name = summary.name }))
        EndTextCommandSetBlipName(blip)
        blips[id] = blip
    end
end

local function readTracks(value)
    RC.tracks = {}
    for _, summary in ipairs(type(value) == 'table' and value or {}) do
        if type(summary) == 'table' and T.validId(summary.id) then
            RC.tracks[summary.id] = summary
            local cached = RC.cache[summary.id]
            if cached and cached.rev ~= summary.rev then RC.cache[summary.id] = nil end
        end
    end
    for id, record in pairs(spawned) do
        local summary = RC.tracks[id]
        local isForced = false
        for _, track in pairs(forced) do if track.id == id then isForced = true end end
        if not isForced and (not summary or summary.rev ~= record.rev) then despawn(id) end
    end
    rebuildBlips()
end

AddStateBagChangeHandler(RESOURCE .. ':tracks', 'global', function(_, _, value) readTracks(value) end)
AddStateBagChangeHandler(RESOURCE .. ':active', 'global', function(_, _, value) RC.active = type(value) == 'table' and value or {} end)

local function prompt(show, name)
    if show == promptShown then return end
    promptShown = show
    if not lib then return end
    if show then
        lib.showInteraction({ id = PROMPT, label = L('prompt.races', { name = name }), key = Config.keys.menu, priority = 15 })
    else
        lib.hideInteraction(PROMPT)
    end
end

CreateThread(function()
    readTracks(GlobalState[RESOURCE .. ':tracks'])
    RC.active = GlobalState[RESOURCE .. ':active'] or {}
    while true do
        local cam = U.camera()
        local ped = PlayerPedId()
        local pedAt = GetEntityCoords(ped)
        local wanted = visibleTracks()
        for id, entry in pairs(wanted) do
            local track = entry ~= true and entry or RC.cache[id]
            local summary = RC.tracks[id]
            local centre = track and track.centre or (summary and vector3(summary.x, summary.y, summary.z))
            local radius = track and track.radius or 300.0
            if centre then
                local c = vector3(centre.x, centre.y, centre.z)
                local close = math.min(#(cam - c), #(pedAt - c)) < Config.effects.drawDistance + radius
                if close and not spawned[id] then
                    if not track then track = W.fetch(id) end
                    if track then spawn(track) end
                elseif not close and spawned[id] then
                    despawn(id)
                end
            end
        end
        for id in pairs(spawned) do if not wanted[id] or hidden[id] then despawn(id) end end
        local nearest, nearestDist = nil, Config.race.joinRadius
        if not RC.race and not RC.editing and not RC.replaying and not U.piloting() then
            for id, summary in pairs(RC.tracks) do
                local d = #(pedAt - vector3(summary.x, summary.y, summary.z))
                if d < nearestDist then nearest, nearestDist = id, d end
            end
        end
        W.near = nearest
        prompt(nearest ~= nil, nearest and RC.tracks[nearest].name)
        if next(unsupported) then retrySupports() end
        Wait(nearest and 400 or 1000)
    end
end)

function W.ensureLights()
    lightLoop()
end

AddEventHandler(RESOURCE .. ':spawned', function() W.ensureLights() end)

AddEventHandler('onClientResourceStop', function(name)
    if name ~= RESOURCE then return end
    lightGen = lightGen + 1
    for id in pairs(spawned) do pcall(despawn, id) end
    for _, blip in pairs(blips) do pcall(RemoveBlip, blip) end
    if promptShown and lib then pcall(lib.hideInteraction, PROMPT) end
end)
