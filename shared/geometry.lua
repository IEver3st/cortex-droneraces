RaceGeometry = {}
local G = RaceGeometry
local rad, sin, cos, sqrt = math.rad, math.sin, math.cos, math.sqrt

function G.axes(pitch, heading)
    local p, h = rad(pitch or 0.0), rad(heading or 0.0)
    local sp, cp, sh, ch = sin(p), cos(p), sin(h), cos(h)
    return
        { ch, sh, 0.0 },
        { -sh * cp, ch * cp, sp },
        { sh * sp, -ch * sp, cp }
end

local function dot(a, x, y, z) return a[1] * x + a[2] * y + a[3] * z end

function G.toLocal(piece, x, y, z)
    local right, forward, up = G.axes(piece.p, piece.h)
    local dx, dy, dz = x - piece.x, y - piece.y, z - piece.z
    return dot(right, dx, dy, dz), dot(forward, dx, dy, dz), dot(up, dx, dy, dz)
end

function G.toWorld(piece, lx, ly, lz)
    local right, forward, up = G.axes(piece.p, piece.h)
    return piece.x + right[1] * lx + forward[1] * ly + up[1] * lz,
        piece.y + right[2] * lx + forward[2] * ly + up[2] * lz,
        piece.z + right[3] * lx + forward[3] * ly + up[3] * lz
end

function G.inside(shape, lx, lz, margin)
    margin = margin or 0.0
    if shape.shape == 'circle' then return lx * lx + lz * lz <= (shape.r + margin) ^ 2 end
    if shape.shape == 'hex' then
        local a = shape.r + margin
        return math.abs(lz) <= a and sqrt(3.0) * math.abs(lx) + math.abs(lz) <= 2.0 * a
    end
    return math.abs(lx) <= shape.w * 0.5 + margin and math.abs(lz) <= shape.h * 0.5 + margin
end

function G.crossing(piece, shape, ax, ay, az, bx, by, bz, margin)
    local alx, aly, alz = G.toLocal(piece, ax, ay, az)
    if aly >= 0.0 then return nil end
    local blx, bly, blz = G.toLocal(piece, bx, by, bz)
    if bly < 0.0 then return nil end
    local t = aly / (aly - bly)
    local lx, lz = alx + (blx - alx) * t, alz + (blz - alz) * t
    if not G.inside(shape, lx, lz, margin) then return nil end
    return t
end

function G.distance(ax, ay, az, bx, by, bz)
    local dx, dy, dz = bx - ax, by - ay, bz - az
    return sqrt(dx * dx + dy * dy + dz * dz)
end

function G.segmentDistance(px, py, pz, ax, ay, az, bx, by, bz)
    local vx, vy, vz = bx - ax, by - ay, bz - az
    local len = vx * vx + vy * vy + vz * vz
    local t = 0.0
    if len > 1e-6 then t = math.max(0.0, math.min(1.0, ((px - ax) * vx + (py - ay) * vy + (pz - az) * vz) / len)) end
    return G.distance(px, py, pz, ax + vx * t, ay + vy * t, az + vz * t)
end

function G.respawn(piece, ahead)
    local x, y, z = G.toWorld(piece, 0.0, ahead or 3.0, 0.0)
    return x, y, z, piece.h
end

function G.headingTo(ax, ay, bx, by)
    return (math.deg(math.atan(-(bx - ax), by - ay)) + 360.0) % 360.0
end
