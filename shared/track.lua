RaceTrack = {}
local T = RaceTrack
local K, V, G = RaceCatalogue, RaceValidate, RaceGeometry

local CONTROL = '[%z\1-\31\127]'
local LIMIT = 100000.0

function T.cleanName(value, max)
    if type(value) ~= 'string' then return nil end
    local clean = value:gsub(CONTROL, ''):gsub('[<>]', ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s%s+', ' ')
    if #clean == 0 or #clean > (max or 40) then return nil end
    return clean
end

function T.validId(value)
    return type(value) == 'string' and #value >= 1 and #value <= 32 and value:match('^[a-z0-9_%-]+$') ~= nil
end

local function piece(raw, role)
    if type(raw) ~= 'table' then return nil end
    local kind = K.get(raw.k)
    if not kind then return nil end
    if role == 'checkpoint' and not kind.checkpoint then return nil end
    if role == 'prop' and kind.checkpoint then return nil end
    local x, y, z, h, p = raw.x, raw.y, raw.z, raw.h or 0.0, raw.p or 0.0
    for _, n in ipairs({ x, y, z, h, p }) do
        if not V.finite(n) or math.abs(n) > LIMIT then return nil end
    end
    if p < -90.0 or p > 90.0 then return nil end
    if not kind.tilt then p = 0.0 end
    local function round(n, step) return math.floor(n / step + 0.5) * step end
    return { k = kind.key, x = round(x, 0.01), y = round(y, 0.01), z = round(z, 0.01), h = round(h % 360.0, 0.1), p = round(p, 0.1) }
end

function T.normalize(raw, limits)
    if type(raw) ~= 'table' then return nil, 'bad_track' end
    limits = limits or {}
    local name = T.cleanName(raw.name)
    if not name then return nil, 'bad_name' end
    local loop = raw.loop ~= false
    local laps = loop and (V.integer(raw.laps, Config.race.laps.min, Config.race.laps.max) or Config.race.laps.default) or 1
    if type(raw.checkpoints) ~= 'table' or type(raw.props) ~= 'table' then return nil, 'bad_track' end
    local maxCheckpoints = limits.maxCheckpoints or Config.editor.maxCheckpoints
    local maxProps = limits.maxProps or Config.editor.maxProps
    if #raw.checkpoints > maxCheckpoints then return nil, 'too_many_checkpoints' end
    if #raw.props > maxProps then return nil, 'too_many_props' end
    local track = { name = name, loop = loop, laps = laps, always = raw.always == true, checkpoints = {}, props = {} }
    for i = 1, #raw.checkpoints do
        local value = piece(raw.checkpoints[i], 'checkpoint')
        if not value then return nil, 'bad_piece' end
        track.checkpoints[i] = value
    end
    local pads = 0
    for i = 1, #raw.props do
        local value = piece(raw.props[i], 'prop')
        if not value then return nil, 'bad_piece' end
        if value.k == 'pad' then pads = pads + 1 end
        track.props[i] = value
    end
    if #track.checkpoints < 2 then return nil, 'need_checkpoints' end
    if pads < 1 then return nil, 'need_pad' end
    local first = track.checkpoints[1]
    local span = limits.maxSpan or Config.editor.maxSpan
    for _, list in ipairs({ track.checkpoints, track.props }) do
        for _, p in ipairs(list) do
            if G.distance(first.x, first.y, first.z, p.x, p.y, p.z) > span then return nil, 'too_spread' end
        end
    end
    return track
end

function T.derive(track)
    local grid = {}
    local sx, sy, sz = 0.0, 0.0, 0.0
    for _, p in ipairs(track.props) do
        if p.k == 'pad' then
            grid[#grid + 1] = p
            sx, sy, sz = sx + p.x, sy + p.y, sz + p.z
        end
    end
    track.grid = grid
    if #grid > 0 then
        track.start = { x = sx / #grid, y = sy / #grid, z = sz / #grid }
    else
        local c = track.checkpoints[1]
        track.start = { x = c.x, y = c.y, z = c.z }
    end
    local minX, minY, minZ, maxX, maxY, maxZ = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
    for _, list in ipairs({ track.checkpoints, track.props }) do
        for _, p in ipairs(list) do
            minX, minY, minZ = math.min(minX, p.x), math.min(minY, p.y), math.min(minZ, p.z)
            maxX, maxY, maxZ = math.max(maxX, p.x), math.max(maxY, p.y), math.max(maxZ, p.z)
        end
    end
    track.centre = { x = (minX + maxX) * 0.5, y = (minY + maxY) * 0.5, z = (minZ + maxZ) * 0.5 }
    track.radius = G.distance(minX, minY, minZ, maxX, maxY, maxZ) * 0.5 + 10.0
    return track
end

function T.gateCount(track, laps)
    local n = #track.checkpoints
    if not track.loop then return n end
    return laps * n + 1
end

function T.at(track, index)
    local n = #track.checkpoints
    if index < 1 then return nil end
    if not track.loop then return track.checkpoints[index], 1 end
    local slot = (index - 1) % n + 1
    return track.checkpoints[slot], math.floor((index - 1) / n) + 1, slot
end

function T.isLapLine(track, index)
    return track.loop and index > 1 and (index - 1) % #track.checkpoints == 0
end

function T.summary(track)
    return {
        id = track.id, name = track.name, author = track.author, loop = track.loop, laps = track.laps, always = track.always,
        rev = track.rev, builtin = track.builtin == true, gates = #track.checkpoints, grid = #track.grid,
        x = track.start.x, y = track.start.y, z = track.start.z,
    }
end

function T.wire(track)
    return {
        id = track.id, name = track.name, author = track.author, loop = track.loop, laps = track.laps, always = track.always,
        rev = track.rev, builtin = track.builtin == true, checkpoints = track.checkpoints, props = track.props,
    }
end
