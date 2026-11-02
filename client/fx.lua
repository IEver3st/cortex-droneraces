RaceFx = {}
local FX = RaceFx
local RC, U, G, W = RaceClient, RaceUtil, RaceGeometry, RaceWorld
local RESOURCE = GetCurrentResourceName()
local BAG = RESOURCE .. ':racer'

local racers = {}
local trails = {}
local curtains = {}
local lamps = nil
local trailGen, curtainGen, lampGen = 0, 0, 0

function FX.racers() return racers end

local function stopTrail(entity)
    local handle = trails[entity]
    if handle then
        StopParticleFxLooped(handle, false)
        trails[entity] = nil
    end
end

local function trailLoop()
    trailGen = trailGen + 1
    local gen = trailGen
    CreateThread(function()
        local cfg = Config.effects.trail
        while gen == trailGen and next(racers) do
            local cam = U.camera()
            local mine = U.drone()
            mine = mine and mine.entity
            for entity, colour in pairs(racers) do
                if not DoesEntityExist(entity) then
                    stopTrail(entity)
                    racers[entity] = nil
                else
                    local want = RC.prefs.trails and entity ~= mine and #(cam - GetEntityCoords(entity)) < 300.0 and GetEntitySpeed(entity) > 1.5
                    if want and not trails[entity] and U.ptfx(cfg.asset) then
                        UseParticleFxAssetNextCall(cfg.asset)
                        local handle = StartParticleFxLoopedOnEntity(cfg.name, entity, 0.0, -0.18, 0.0, 0.0, 0.0, 0.0, U.F(cfg.scale), false, false, false)
                        if handle and handle ~= 0 then
                            local c = U.colour(colour)
                            SetParticleFxLoopedColour(handle, c[1] / 255.0, c[2] / 255.0, c[3] / 255.0, false)
                            trails[entity] = handle
                        end
                    elseif not want and trails[entity] then
                        stopTrail(entity)
                    end
                end
            end
            Wait(250)
        end
        if gen == trailGen then for entity in pairs(trails) do stopTrail(entity) end end
    end)
end

AddStateBagChangeHandler(BAG, nil, function(bagName, _, value)
    local entity = GetEntityFromStateBagName(bagName)
    for _ = 1, 60 do
        if entity ~= 0 then break end
        Wait(0)
        entity = GetEntityFromStateBagName(bagName)
    end
    if entity == 0 then return end
    if type(value) ~= 'table' then
        stopTrail(entity)
        racers[entity] = nil
        return
    end
    local fresh = next(racers) == nil
    racers[entity] = tonumber(value.colour) or 1
    if fresh then trailLoop() end
end)

function FX.clearRacers()
    for entity in pairs(racers) do stopTrail(entity) end
    racers = {}
    trailGen = trailGen + 1
end

local function burners(trackId, near, radius)
    local record = W.record(trackId)
    if not record then return {} end
    local list = {}
    for _, item in ipairs(record.items) do
        if item.kind and item.kind.role == 'flame' then
            local p = item.piece
            if not near or G.distance(p.x, p.y, p.z, near.x, near.y, near.z) <= (radius or 14.0) then list[#list + 1] = item end
        end
    end
    return list
end

local function burst(item, seconds)
    local cfg = Config.effects.flame
    if not RC.prefs.flames or not U.ptfx(cfg.asset) then return end
    local p, kind = item.piece, item.kind
    local x, y, z = G.toWorld(p, kind.nozzle.x, kind.nozzle.y, kind.nozzle.z)
    UseParticleFxAssetNextCall(cfg.asset)
    local handle = StartParticleFxLoopedAtCoord(cfg.name, U.F(x), U.F(y), U.F(z), 0.0, 0.0, 0.0, U.F(cfg.scale), false, false, false, false)
    if not handle or handle == 0 then return end
    SetTimeout(math.floor((seconds or cfg.burst) * 1000), function() StopParticleFxLooped(handle, false) end)
end

function FX.flames(trackId, near, radius)
    for _, item in ipairs(burners(trackId, near, radius)) do burst(item) end
end

local function curtainOff()
    for _, handle in ipairs(curtains) do StopParticleFxLooped(handle, false) end
    curtains = {}
end

local function curtainLoop()
    curtainGen = curtainGen + 1
    local gen = curtainGen
    CreateThread(function()
        local cfg = Config.effects.curtain
        local showing, pulse = nil, 0
        while gen == curtainGen do
            local live = nil
            if RC.prefs.flames then
                for id in pairs(RC.active) do if (RC.active[id] or 0) > 0 and W.record(id) then live = id break end end
                if RC.race and RC.race.track and W.record(RC.race.track.id) then live = RC.race.track.id end
            end
            if live ~= showing then
                curtainOff()
                showing = live
                local record = live and W.record(live)
                if record and U.ptfx(cfg.asset) then
                    for _, item in ipairs(record.items) do
                        if item.kind and item.kind.role == 'curtain' then
                            for _, nozzle in ipairs(item.kind.nozzles) do
                                local x, y, z = G.toWorld(item.piece, nozzle.x, nozzle.y, nozzle.z)
                                UseParticleFxAssetNextCall(cfg.asset)
                                local handle = StartParticleFxLoopedAtCoord(cfg.name, U.F(x), U.F(y), U.F(z), 0.0, 0.0, U.F(item.piece.h), U.F(cfg.scale), false, false, false, false)
                                if handle and handle ~= 0 then curtains[#curtains + 1] = handle end
                            end
                        end
                    end
                end
            end
            if showing and not RC.race then
                pulse = pulse + 1
                if pulse % 6 == 0 then FX.flames(showing) end
            end
            Wait(1000)
        end
        curtainOff()
    end)
end
curtainLoop()

function FX.fireworks(trackId, place)
    local cfg = Config.effects.fireworks
    if not RC.prefs.flames then return end
    local record = W.record(trackId)
    if not record then return end
    local arch = record.track.checkpoints[record.track.loop and 1 or #record.track.checkpoints]
    if not arch or #(U.camera() - vector3(arch.x, arch.y, arch.z)) > 600.0 then return end
    if not U.ptfx(cfg.asset) then return end
    local shots = place == 1 and 4 or 1
    CreateThread(function()
        for i = 1, shots do
            local ox, oy = (math.random() - 0.5) * 12.0, (math.random() - 0.5) * 6.0
            UseParticleFxAssetNextCall(cfg.asset)
            StartParticleFxNonLoopedAtCoord(cfg.name, U.F(arch.x + ox), U.F(arch.y + oy), U.F(arch.z + cfg.height + i * 2.0), 0.0, 0.0, 0.0, U.F(cfg.scale), false, false, false)
            Wait(450)
        end
    end)
    FX.flames(trackId, arch, 16.0)
end

RegisterNetEvent(RESOURCE .. ':finished', function(data)
    if type(data) ~= 'table' or type(data.track) ~= 'string' then return end
    FX.fireworks(data.track, tonumber(data.place) or 9)
end)

function FX.lamps(trackId, red, green)
    lamps = trackId and { track = trackId, red = red or 0, green = green == true } or nil
    lampGen = lampGen + 1
    if not lamps then return end
    local gen = lampGen
    CreateThread(function()
        local points = {}
        local record = W.record(trackId)
        if record then
            for _, item in ipairs(record.items) do
                if item.kind and item.kind.role == 'lights' then
                    for i, lamp in ipairs(item.kind.lamps) do
                        local x, y, z = G.toWorld(item.piece, lamp.x, lamp.y, lamp.z)
                        points[#points + 1] = { x = x, y = y, z = z, slot = (i + 1) // 2 }
                    end
                end
            end
        end
        while gen == lampGen and lamps and #points > 0 do
            for _, p in ipairs(points) do
                local on, r, g, b = false, 0, 0, 0
                if lamps.green then on, r, g, b = true, 90, 235, 130
                elseif p.slot <= lamps.red then on, r, g, b = true, 235, 60, 50 end
                if on then
                    DrawMarker(28, U.F(p.x), U.F(p.y), U.F(p.z), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.16, 0.16, 0.16, r, g, b, 235, false, false, 2, false, nil, nil, false)
                    DrawLightWithRange(U.F(p.x), U.F(p.y), U.F(p.z), r, g, b, 2.5, 6.0)
                end
            end
            Wait(0)
        end
    end)
end

AddEventHandler('onClientResourceStop', function(name)
    if name ~= RESOURCE then return end
    trailGen, curtainGen, lampGen = trailGen + 1, curtainGen + 1, lampGen + 1
    for entity in pairs(trails) do pcall(stopTrail, entity) end
    pcall(curtainOff)
    pcall(U.releasePtfx)
end)
