Config = {}

Config.Locale = 'en'

Config.debug = false

Config.drone = 'fpv'

Config.requireItem = false

Config.race = {
    maxRacers = 8,
    laps = { min = 1, max = 10, default = 3 },
    countdown = 5,
    lobbyMinutes = 10,
    joinRadius = 45.0,
    deploySeconds = 20,
    respawnPenalty = 0.0,
    dnfSeconds = 60,
    maxMinutes = 15,
    resultsSeconds = 12,
    ghosting = true,
    topSpeed = 50.0,
}

Config.economy = {
    enabled = true,
    account = 'cash',
    minFee = 0,
    maxFee = 10000,
    houseCut = 0.0,
    payouts = {
        [1] = { 1.0 },
        [2] = { 0.7, 0.3 },
        [3] = { 0.6, 0.3, 0.1 },
    },
}

Config.editor = {
    access = 'ace',
    maxCheckpoints = 60,
    maxProps = 120,
    maxTracksPerPlayer = 10,
    maxSpan = 2500.0,
    reach = { min = 3.0, max = 80.0, default = 14.0 },
    speed = { normal = 12.0, fast = 40.0, slow = 3.0 },
}

Config.blips = { enabled = true, sprite = 627, colour = 3, scale = 0.8 }

Config.keys = { menu = 'K' }

Config.editorControls = {
    place = 24, grab = 25, delete = 178, cycle = 37, yawLeft = 44, yawRight = 38,
    pitchUp = 45, pitchDown = 23, earlier = 10, later = 11, menu = 191, back = 194, up = 22, down = 36,
    fast = 21, slow = 19, snap = 47, reachIn = 241, reachOut = 242,
}

Config.effects = {
    drawDistance = 450.0,
    lights = { count = 16, range = 11.0, intensity = 6.0, distance = 160.0, pool = 3.0,
        flood = { distance = 45.0, brightness = 10.0, hardness = 1.0, radius = 38.0, falloff = 18.0 } },
    trail = { asset = 'scr_ar_planes', name = 'scr_ar_trail_smoke', scale = 0.32 },
    colours = {
        { 120, 205, 235 }, { 236, 112, 168 }, { 246, 196, 92 }, { 120, 170, 255 },
        { 186, 140, 255 }, { 250, 140, 90 }, { 160, 230, 120 }, { 240, 240, 233 },
    },
    flame = { asset = 'core', name = 'ent_sht_flame', scale = 2.2, burst = 1.4 },
    curtain = { asset = 'core', name = 'ent_amb_fbi_fire_wall_lg', scale = 0.55 },
    fireworks = { asset = 'scr_indep_fireworks', name = 'scr_indep_firework_starburst', scale = 1.0, height = 18.0 },
    ghostModel = 'rcmavic',
}

Config.audit = { races = true, money = true, tracks = true, staff = true }
