---Vector functions on plain numbers, without argument checks and without tables, for the per-tick loops (spec
---2026-10-01 release 4 §3). systems.geometry is the checked public version.
local Vector = {}

local sqrt, acos, cos, sin, atan = math.sqrt, math.acos, math.cos, math.sin, math.atan

---@param x number
---@param y number
---@param z number
---@return number
function Vector.length(x, y, z) return sqrt(x * x + y * y + z * z) end

---Rotates the velocity toward the direction (tx, ty, tz) by at most `maxAngle` radians, keeping its speed. A zero
---velocity stays zero; a zero direction leaves the velocity unchanged.
---@param vx number
---@param vy number
---@param vz number
---@param tx number
---@param ty number
---@param tz number
---@param maxAngle number
---@return number x
---@return number y
---@return number z
function Vector.turnToward(vx, vy, vz, tx, ty, tz, maxAngle)
    local speed = sqrt(vx * vx + vy * vy + vz * vz)
    local distance = sqrt(tx * tx + ty * ty + tz * tz)
    if distance == 0 or speed == 0 then return vx, vy, vz end
    local dx, dy, dz = tx / distance, ty / distance, tz / distance
    local ux, uy, uz = vx / speed, vy / speed, vz / speed
    local dot = ux * dx + uy * dy + uz * dz
    if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
    if acos(dot) <= maxAngle then return dx * speed, dy * speed, dz * speed end
    -- Rotate u toward d inside their common plane: w is the unit vector in that plane at a right angle to u.
    local wx, wy, wz = dx - ux * dot, dy - uy * dot, dz - uz * dot
    local w = sqrt(wx * wx + wy * wy + wz * wz)
    if w < 1e-4 then
        -- The direction is straight behind: turn left in the horizontal plane, so every machine picks the same plane.
        wx, wy, wz = -uy, ux, 0
        w = sqrt(wx * wx + wy * wy)
        if w < 1e-4 then wx, wy, w = 1, 0, 1 end -- moving straight up or down
    end
    wx, wy, wz = wx / w, wy / w, wz / w
    local c, s = cos(maxAngle), sin(maxAngle)
    return (ux * c + wx * s) * speed, (uy * c + wy * s) * speed, (uz * c + wz * s) * speed
end

---The earliest contact of the segment from f to t with a sphere, as a fraction of the segment: 0 when it starts
---inside, nil when it misses (or has no length and starts outside).
---@param fx number
---@param fy number
---@param fz number
---@param tx number
---@param ty number
---@param tz number
---@param cx number
---@param cy number
---@param cz number
---@param radius number
---@return number? fraction
function Vector.segmentSphere(fx, fy, fz, tx, ty, tz, cx, cy, cz, radius)
    local x, y, z = fx - cx, fy - cy, fz - cz
    local c = x * x + y * y + z * z - radius * radius
    if c <= 0 then return 0 end
    local dx, dy, dz = tx - fx, ty - fy, tz - fz
    local a = dx * dx + dy * dy + dz * dz
    if a == 0 then return nil end
    local b = x * dx + y * dy + z * dz
    local discriminant = b * b - a * c
    if discriminant < 0 then return nil end
    local fraction = (-b - sqrt(discriminant)) / a
    if fraction >= 0 and fraction <= 1 then return fraction end
    return nil
end

---The yaw and pitch that point an effect along a velocity. A positive pitch points the nose down (measured on
---3.0.0.24268), so a climbing velocity gives a negative pitch. A zero velocity gives 0, 0.
---@param vx number
---@param vy number
---@param vz number
---@return number yaw
---@return number pitch
function Vector.orientation(vx, vy, vz)
    local horizontal = sqrt(vx * vx + vy * vy)
    if horizontal == 0 and vz == 0 then return 0, 0 end
    return atan(vy, vx), -atan(vz, horizontal)
end

return Vector
