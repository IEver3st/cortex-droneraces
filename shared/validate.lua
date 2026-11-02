RaceValidate = {}
local V = RaceValidate
local RESOURCE = GetCurrentResourceName()
local IS_SERVER = IsDuplicityVersion()

local function show(value)
    if type(value) == 'string' then return ('%q'):format(value:sub(1, 40)) end
    if type(value) == 'table' then return 'a table' end
    return tostring(value)
end

local function warn(path, expected, value, fallback)
    if not IS_SERVER then return end
    print(('^3[%s] config.lua: %s expected %s, got %s; using %s^0'):format(RESOURCE, path, expected, show(value), show(fallback)))
end

local function finite(value) return type(value) == 'number' and value == value and value > -math.huge and value < math.huge end
V.finite = finite

function V.integer(value, min, max)
    if not finite(value) or math.floor(value) ~= value then return nil end
    if (min and value < min) or (max and value > max) then return nil end
    return math.tointeger(value)
end

local function number(path, value, fallback, min, max)
    if finite(value) and value >= min and value <= max then return value end
    warn(path, ('a number from %s to %s'):format(min, max), value, fallback)
    return fallback
end

local function int(path, value, fallback, min, max)
    if V.integer(value, min, max) then return math.tointeger(value) end
    warn(path, ('a whole number from %s to %s'):format(min, max), value, fallback)
    return fallback
end

local function bool(path, value, fallback)
    if type(value) == 'boolean' then return value end
    warn(path, 'true or false', value, fallback)
    return fallback
end

local function text(path, value, fallback, pattern)
    if type(value) == 'string' and #value > 0 and #value <= 64 and (not pattern or value:match(pattern)) then return value end
    warn(path, 'a short name', value, fallback)
    return fallback
end

local function tab(path, value)
    if type(value) == 'table' then return value end
    if value ~= nil then warn(path, 'a table', value, 'the defaults') end
    return {}
end

local function colour(path, value, fallback)
    if type(value) == 'table' and V.integer(value[1], 0, 255) and V.integer(value[2], 0, 255) and V.integer(value[3], 0, 255) then
        return { math.tointeger(value[1]), math.tointeger(value[2]), math.tointeger(value[3]) }
    end
    warn(path, 'an { r, g, b } colour', value, 'the default')
    return fallback
end

local function fx(path, value, fallback)
    value = tab(path, value)
    return {
        asset = text(path .. '.asset', value.asset, fallback.asset, '^[%w_]+$'),
        name = text(path .. '.name', value.name, fallback.name, '^[%w_]+$'),
        scale = number(path .. '.scale', value.scale, fallback.scale, 0.05, 10.0),
        burst = fallback.burst and number(path .. '.burst', value.burst, fallback.burst, 0.1, 10.0) or nil,
        height = fallback.height and number(path .. '.height', value.height, fallback.height, 0.0, 200.0) or nil,
    }
end

function V.config()
    local C = Config
    C.Locale = text('Config.Locale', C.Locale, 'en', '^[%a%-]+$')
    C.debug = bool('Config.debug', C.debug, false)
    C.drone = text('Config.drone', C.drone, 'fpv', '^[%w_]+$')
    local items = type(C.requireItem) == 'string' and { C.requireItem } or C.requireItem
    if type(items) == 'table' then
        local list = {}
        for i, item in ipairs(items) do list[#list + 1] = text(('Config.requireItem[%d]'):format(i), item, nil, '^[%w_]+$') end
        C.requireItem = #list > 0 and list or false
    else
        if items ~= false and items ~= nil then warn('Config.requireItem', 'false, an item name or a list of them', items, false) end
        C.requireItem = false
    end

    local r = tab('Config.race', C.race)
    local laps = tab('Config.race.laps', r.laps)
    local lapMin = int('Config.race.laps.min', laps.min, 1, 1, 50)
    local lapMax = int('Config.race.laps.max', laps.max, 10, lapMin, 50)
    C.race = {
        maxRacers = int('Config.race.maxRacers', r.maxRacers, 8, 1, 16),
        laps = { min = lapMin, max = lapMax, default = int('Config.race.laps.default', laps.default, math.min(3, lapMax), lapMin, lapMax) },
        countdown = int('Config.race.countdown', r.countdown, 5, 3, 10),
        lobbyMinutes = number('Config.race.lobbyMinutes', r.lobbyMinutes, 10, 1, 120),
        joinRadius = number('Config.race.joinRadius', r.joinRadius, 45.0, 5.0, 500.0),
        deploySeconds = number('Config.race.deploySeconds', r.deploySeconds, 20, 5, 120),
        respawnPenalty = number('Config.race.respawnPenalty', r.respawnPenalty, 0.0, 0.0, 15.0),
        dnfSeconds = number('Config.race.dnfSeconds', r.dnfSeconds, 60, 5, 900),
        maxMinutes = number('Config.race.maxMinutes', r.maxMinutes, 15, 1, 120),
        resultsSeconds = number('Config.race.resultsSeconds', r.resultsSeconds, 12, 3, 120),
        ghosting = bool('Config.race.ghosting', r.ghosting, true),
        topSpeed = number('Config.race.topSpeed', r.topSpeed, 50.0, 10.0, 200.0),
    }

    local e = tab('Config.economy', C.economy)
    local minFee = int('Config.economy.minFee', e.minFee, 0, 0, 100000000)
    local payouts = {}
    for count, shares in pairs(tab('Config.economy.payouts', e.payouts)) do
        local valid = V.integer(count, 1, 16) and type(shares) == 'table' and #shares >= 1 and #shares <= count
        if valid then
            local total, list = 0.0, {}
            for i, share in ipairs(shares) do
                if not finite(share) or share < 0 or share > 100 then valid = false break end
                list[i], total = share + 0.0, total + share
            end
            valid = valid and total > 0
            if valid then payouts[math.tointeger(count)] = list end
        end
        if not valid then warn(('Config.economy.payouts[%s]'):format(show(count)), 'a list of shares no longer than the count', shares, 'skipped') end
    end
    if not payouts[1] then payouts[1] = { 1.0 } end
    C.economy = {
        enabled = bool('Config.economy.enabled', e.enabled, true),
        account = (e.account == 'cash' or e.account == 'bank') and e.account or (warn('Config.economy.account', "'cash' or 'bank'", e.account, 'cash') or 'cash'),
        minFee = minFee,
        maxFee = int('Config.economy.maxFee', e.maxFee, 10000, minFee, 100000000),
        houseCut = number('Config.economy.houseCut', e.houseCut, 0.0, 0.0, 0.9),
        payouts = payouts,
    }

    local ed = tab('Config.editor', C.editor)
    local reach = tab('Config.editor.reach', ed.reach)
    local speed = tab('Config.editor.speed', ed.speed)
    local reachMin = number('Config.editor.reach.min', reach.min, 3.0, 1.0, 50.0)
    local reachMax = number('Config.editor.reach.max', reach.max, 80.0, reachMin, 300.0)
    C.editor = {
        access = (ed.access == 'ace' or ed.access == 'everyone') and ed.access or (warn('Config.editor.access', "'ace' or 'everyone'", ed.access, 'ace') or 'ace'),
        maxCheckpoints = int('Config.editor.maxCheckpoints', ed.maxCheckpoints, 60, 2, 200),
        maxProps = int('Config.editor.maxProps', ed.maxProps, 120, 1, 400),
        maxTracksPerPlayer = int('Config.editor.maxTracksPerPlayer', ed.maxTracksPerPlayer, 10, 1, 500),
        maxSpan = number('Config.editor.maxSpan', ed.maxSpan, 2500.0, 100.0, 10000.0),
        reach = { min = reachMin, max = reachMax, default = number('Config.editor.reach.default', reach.default, 14.0, reachMin, reachMax) },
        speed = {
            normal = number('Config.editor.speed.normal', speed.normal, 12.0, 0.5, 200.0),
            fast = number('Config.editor.speed.fast', speed.fast, 40.0, 0.5, 400.0),
            slow = number('Config.editor.speed.slow', speed.slow, 3.0, 0.1, 100.0),
        },
    }

    local b = tab('Config.blips', C.blips)
    C.blips = {
        enabled = bool('Config.blips.enabled', b.enabled, true),
        sprite = int('Config.blips.sprite', b.sprite, 627, 0, 1000),
        colour = int('Config.blips.colour', b.colour, 3, 0, 85),
        scale = number('Config.blips.scale', b.scale, 0.8, 0.1, 3.0),
    }

    C.keys = { menu = text('Config.keys.menu', tab('Config.keys', C.keys).menu, 'K', '^[%w_]+$') }

    local defaults = { place = 24, grab = 25, delete = 178, cycle = 37, yawLeft = 44, yawRight = 38, pitchUp = 45, pitchDown = 23,
        earlier = 10, later = 11, menu = 191, back = 194, up = 22, down = 36, fast = 21, slow = 19, snap = 47, reachIn = 241, reachOut = 242 }
    local controls = tab('Config.editorControls', C.editorControls)
    C.editorControls = {}
    for key, fallback in pairs(defaults) do
        C.editorControls[key] = int('Config.editorControls.' .. key, controls[key], fallback, 0, 360)
    end

    local f = tab('Config.effects', C.effects)
    local lights = tab('Config.effects.lights', f.lights)
    local flood = tab('Config.effects.lights.flood', lights.flood)
    local colours = {}
    for i, value in ipairs(tab('Config.effects.colours', f.colours)) do
        if i > 16 then break end
        colours[#colours + 1] = colour(('Config.effects.colours[%d]'):format(i), value, { 240, 240, 233 })
    end
    if #colours == 0 then colours = { { 143, 203, 191 } } end
    C.effects = {
        drawDistance = number('Config.effects.drawDistance', f.drawDistance, 450.0, 50.0, 2000.0),
        lights = {
            count = int('Config.effects.lights.count', lights.count, 16, 0, 40),
            range = number('Config.effects.lights.range', lights.range, 11.0, 0.5, 50.0),
            intensity = number('Config.effects.lights.intensity', lights.intensity, 6.0, 0.1, 50.0),
            distance = number('Config.effects.lights.distance', lights.distance, 160.0, 10.0, 1000.0),
            pool = number('Config.effects.lights.pool', lights.pool, 3.0, 0.5, 20.0),
            flood = {
                distance = number('Config.effects.lights.flood.distance', flood.distance, 45.0, 5.0, 200.0),
                brightness = number('Config.effects.lights.flood.brightness', flood.brightness, 10.0, 0.1, 100.0),
                hardness = number('Config.effects.lights.flood.hardness', flood.hardness, 1.0, 0.0, 100.0),
                radius = number('Config.effects.lights.flood.radius', flood.radius, 38.0, 1.0, 90.0),
                falloff = number('Config.effects.lights.flood.falloff', flood.falloff, 18.0, 0.1, 100.0),
            },
        },
        trail = fx('Config.effects.trail', f.trail, { asset = 'scr_ar_planes', name = 'scr_ar_trail_smoke', scale = 0.32 }),
        colours = colours,
        flame = fx('Config.effects.flame', f.flame, { asset = 'core', name = 'ent_sht_flame', scale = 2.2, burst = 1.4 }),
        curtain = fx('Config.effects.curtain', f.curtain, { asset = 'core', name = 'ent_amb_fbi_fire_wall_lg', scale = 0.55 }),
        fireworks = fx('Config.effects.fireworks', f.fireworks, { asset = 'scr_indep_fireworks', name = 'scr_indep_firework_starburst', scale = 1.0, height = 18.0 }),
        ghostModel = text('Config.effects.ghostModel', f.ghostModel, 'rcmavic', '^[%w_]+$'),
    }

    local a = tab('Config.audit', C.audit)
    C.audit = {
        races = bool('Config.audit.races', a.races, true),
        money = bool('Config.audit.money', a.money, true),
        tracks = bool('Config.audit.tracks', a.tracks, true),
        staff = bool('Config.audit.staff', a.staff, true),
    }
end

V.config()
