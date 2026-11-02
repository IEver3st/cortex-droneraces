RaceClient = { tracks = {}, cache = {}, active = {}, prefs = { trails = true, flames = true, lights = true } }
RaceUtil = {}
local U = RaceUtil
local RESOURCE = GetCurrentResourceName()

function U.F(value) return (tonumber(value) or 0) + 0.0 end
function U.I(value) return math.floor((tonumber(value) or 0) + 0.5) end
function U.now() return GetGameTimer() end

function U.notify(key, kind, vars)
    if lib and lib.notify then lib.notify({ description = L(key, vars), type = kind or 'error' }) end
end

RegisterNetEvent(RESOURCE .. ':notify', function(key, kind, vars)
    if type(key) ~= 'string' or #key > 64 then return end
    U.notify(key, type(kind) == 'string' and kind or 'error', type(vars) == 'table' and vars or nil)
end)

function U.call(name, ...)
    local args = { ... }
    local ok, result = pcall(function() return lib.callback.await(RESOURCE .. ':' .. name, false, table.unpack(args)) end)
    if not ok or type(result) ~= 'table' then return nil end
    return result
end

function U.failure(result)
    if not result then U.notify('notify.no_answer'); return end
    if result.error == 'rate_limited' then return end
    U.notify('error.' .. tostring(result.error or 'unavailable'))
end

function U.loadModel(model, timeout)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local deadline = GetNetworkTimeAccurate() + (timeout or 5000)
    while not HasModelLoaded(hash) do
        if GetNetworkTimeAccurate() > deadline then return nil end
        Wait(0)
    end
    return hash
end

local assets = {}
function U.ptfx(asset)
    if assets[asset] and HasNamedPtfxAssetLoaded(asset) then return true end
    RequestNamedPtfxAsset(asset)
    local deadline = GetNetworkTimeAccurate() + 3000
    while not HasNamedPtfxAssetLoaded(asset) do
        if GetNetworkTimeAccurate() > deadline then return false end
        Wait(0)
    end
    assets[asset] = true
    return true
end

function U.releasePtfx()
    for asset in pairs(assets) do RemoveNamedPtfxAsset(asset) end
    assets = {}
end

function U.deleteEntity(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    if IsEntityAttached(entity) then DetachEntity(entity, false, true) end
    SetEntityAsMissionEntity(entity, true, true)
    DeleteEntity(entity)
end

function U.camera()
    return GetFinalRenderedCamCoord()
end

function U.sound(name, set)
    PlaySoundFrontend(-1, name, set or 'HUD_MINI_GAME_SOUNDSET', true)
end

function U.accent()
    local ok, data = pcall(function() return exports['cortex-lib']:getPresentation() end)
    local value = ok and type(data) == 'table' and type(data.profile) == 'table' and data.profile.accent
    if type(value) ~= 'string' or not value:match('^#%x%x%x%x%x%x$') then value = '#8fcbbf' end
    return tonumber(value:sub(2, 3), 16), tonumber(value:sub(4, 5), 16), tonumber(value:sub(6, 7), 16)
end

function U.colour(index)
    local list = Config.effects.colours
    return list[((tonumber(index) or 1) - 1) % #list + 1]
end

function U.hex(index)
    local c = U.colour(index)
    return ('#%02x%02x%02x'):format(c[1], c[2], c[3])
end

function U.hud(visible)
    if GetResourceState('cortex-hud') ~= 'started' then return end
    pcall(function()
        if visible then exports['cortex-hud']:showHud(RESOURCE) else exports['cortex-hud']:hideHud(RESOURCE) end
    end)
end

function U.ground(x, y, z)
    local found, height = GetGroundZFor_3dCoord(U.F(x), U.F(y), U.F(z) + 2.0, false)
    if found then return height end
end

function U.drone()
    if GetResourceState('cortex-drone') ~= 'started' then return nil end
    local ok, info = pcall(function() return exports['cortex-drone']:GetDrone() end)
    if not ok or type(info) ~= 'table' then return nil end
    return info
end

function U.piloting()
    if GetResourceState('cortex-drone') ~= 'started' then return false end
    local ok, value = pcall(function() return exports['cortex-drone']:IsPiloting() end)
    return ok and value == true
end

function U.ribbon(ax, ay, az, bx, by, bz, width, r, g, b, a)
    local cam = GetFinalRenderedCamCoord()
    local dx, dy, dz = bx - ax, by - ay, bz - az
    local vx, vy, vz = cam.x - (ax + bx) * 0.5, cam.y - (ay + by) * 0.5, cam.z - (az + bz) * 0.5
    local sx, sy, sz = dy * vz - dz * vy, dz * vx - dx * vz, dx * vy - dy * vx
    local len = math.sqrt(sx * sx + sy * sy + sz * sz)
    if len < 0.0001 then return end
    local k = width * 0.5 / len
    sx, sy, sz = sx * k, sy * k, sz * k
    local x1, y1, z1 = U.F(ax - sx), U.F(ay - sy), U.F(az - sz)
    local x2, y2, z2 = U.F(ax + sx), U.F(ay + sy), U.F(az + sz)
    local x3, y3, z3 = U.F(bx + sx), U.F(by + sy), U.F(bz + sz)
    local x4, y4, z4 = U.F(bx - sx), U.F(by - sy), U.F(bz - sz)
    DrawPoly(x1, y1, z1, x2, y2, z2, x3, y3, z3, r, g, b, a)
    DrawPoly(x1, y1, z1, x3, y3, z3, x4, y4, z4, r, g, b, a)
    DrawPoly(x3, y3, z3, x2, y2, z2, x1, y1, z1, r, g, b, a)
    DrawPoly(x4, y4, z4, x3, y3, z3, x1, y1, z1, r, g, b, a)
end

function U.formatTime(ms)
    if not ms then return '--:--.---' end
    ms = math.max(0, math.floor(ms))
    return ('%d:%02d.%03d'):format(ms // 60000, (ms // 1000) % 60, ms % 1000)
end
