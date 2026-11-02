RaceCatalogue = {}
local K = RaceCatalogue
local R = RaceRig

K.order = { 'gate', 'ring', 'hex', 'cube', 'hurdle', 'arch', 'tunnel', 'pad', 'gantry', 'pylon', 'burner', 'trough', 'flag', 'cone', 'sign',
    'barrier', 'tower' }

K.pieces = {
    gate = { model = 'cx_dr_gate', role = 'checkpoint', shape = 'rect', w = R.gate.w, h = R.gate.h, ground = R.gate.ground, light = { 255, 60, 170 }, tilt = true, mast = true },
    ring = { model = 'cx_dr_ring', role = 'checkpoint', shape = 'circle', r = R.ring.r, ground = R.ring.ground, light = { 60, 220, 255 }, tilt = true, mast = true },
    hex = { model = 'cx_dr_hex', role = 'checkpoint', shape = 'hex', r = R.hex.r, ground = R.hex.ground, light = { 150, 70, 255 }, tilt = true, mast = true },
    cube = { model = 'cx_dr_cube', role = 'checkpoint', shape = 'rect', w = R.cube.w, h = R.cube.h, ground = R.cube.ground, light = { 140, 255, 40 }, tilt = true, mast = true },
    hurdle = { model = 'cx_dr_hurdle', role = 'checkpoint', shape = 'rect', w = R.hurdle.w, h = R.hurdle.h, ground = R.hurdle.ground, light = { 255, 40, 30 }, snap = true },
    arch = { model = 'cx_dr_arch', role = 'checkpoint', shape = 'rect', w = R.arch.w, h = R.arch.h, ground = R.arch.ground, light = { 240, 240, 233 }, snap = true },
    tunnel = { model = 'cx_dr_tunnel', role = 'checkpoint', shape = 'rect', w = R.tunnel.w, h = R.tunnel.h, ground = R.tunnel.ground, light = { 255, 170, 40 }, mast = true },
    pad = { model = 'cx_dr_pad', role = 'grid', ground = 0.0, top = R.pad.top, snap = true },
    gantry = { model = 'cx_dr_gantry', role = 'lights', ground = 0.0, lamps = R.gantry.lamps, snap = true },
    pylon = { model = 'cx_dr_pylon', role = 'decor', ground = 0.0, light = { 255, 60, 170 }, glow = R.pylon.glow, snap = true },
    burner = { model = 'cx_dr_burner', role = 'flame', ground = 0.0, nozzle = R.burner.nozzle, snap = true },
    trough = { model = 'cx_dr_trough', role = 'curtain', ground = 0.0, nozzles = R.trough.nozzles, snap = true },
    flag = { model = 'cx_dr_flag', role = 'decor', ground = 0.0, snap = true },
    cone = { model = 'cx_dr_cone', role = 'decor', ground = 0.0, snap = true },
    sign = { model = 'cx_dr_sign', role = 'decor', ground = 0.0, light = { 255, 150, 30 }, glow = R.sign.glow, snap = true },
    barrier = { model = 'cx_dr_barrier', role = 'decor', ground = 0.0, snap = true },
    tower = { model = 'cx_dr_tower', role = 'decor', ground = 0.0, light = { 255, 236, 210 }, glow = R.tower.flood, aim = R.tower.aim, snap = true },
}

for key, piece in pairs(K.pieces) do
    piece.key = key
    piece.hash = joaat(piece.model)
    piece.checkpoint = piece.role == 'checkpoint'
    if piece.shape == 'rect' then piece.reach = math.sqrt(piece.w * piece.w + piece.h * piece.h) * 0.5
    elseif piece.shape == 'circle' then piece.reach = piece.r
    elseif piece.shape == 'hex' then piece.reach = piece.r * 2.0 / math.sqrt(3.0) end
end

K.masts = {}
for _, length in ipairs(R.mast.lengths) do K.masts[#K.masts + 1] = { length = length, hash = joaat(('cx_dr_mast%d'):format(length)) } end
K.foot = { hash = joaat('cx_dr_foot'), height = R.mast.foot }

function K.get(key) return type(key) == 'string' and K.pieces[key] or nil end

function K.checkpointKinds()
    local list = {}
    for _, key in ipairs(K.order) do if K.pieces[key].checkpoint then list[#list + 1] = key end end
    return list
end
