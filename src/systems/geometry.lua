local Check = require('systems.internal.check')
local Vector = require('systems.internal.vector')

---Pure vector helpers for missiles and other moving things. They take and return plain numbers, so nothing is
---allocated per call. Angles are radians.
local Geometry = {}

---Raises at the public function's caller unless the first `count` values are finite numbers.
---@param operation string
---@param count integer
---@param ... unknown
local function numbers(operation, count, ...)
    for index = 1, count do
        if not Check.finite((select(index, ...))) then
            error('[systems] ' .. operation .. ': expected finite numbers', 3)
        end
    end
end

---The length of a vector.
---@param x number
---@param y number
---@param z number? Default 0.
---@return number
function Geometry.length(x, y, z)
    if z == nil then z = 0 end
    numbers('Geometry.length', 3, x, y, z)
    return Vector.length(x, y, z)
end

---Rotates a velocity toward the direction (tx, ty, tz) by at most `maxAngle` radians, keeping its speed: the homing
---primitive, called from a missile's `steer` with a turn rate times `dt`. A zero velocity stays zero; a zero direction
---leaves the velocity unchanged; a direction straight behind turns left in the horizontal plane.
---@param vx number
---@param vy number
---@param vz number
---@param tx number
---@param ty number
---@param tz number
---@param maxAngle number Not negative.
---@return number x
---@return number y
---@return number z
function Geometry.turnToward(vx, vy, vz, tx, ty, tz, maxAngle)
    numbers('Geometry.turnToward', 7, vx, vy, vz, tx, ty, tz, maxAngle)
    if maxAngle < 0 then error('[systems] Geometry.turnToward: expected a non-negative angle', 2) end
    return Vector.turnToward(vx, vy, vz, tx, ty, tz, maxAngle)
end

---The earliest contact of the segment from (fx, fy, fz) to (tx, ty, tz) with a sphere, as a fraction of the segment:
---0 when the segment starts inside it, nil when it misses.
---@param fx number
---@param fy number
---@param fz number
---@param tx number
---@param ty number
---@param tz number
---@param cx number
---@param cy number
---@param cz number
---@param radius number Not negative.
---@return number? fraction
function Geometry.segmentSphere(fx, fy, fz, tx, ty, tz, cx, cy, cz, radius)
    numbers('Geometry.segmentSphere', 10, fx, fy, fz, tx, ty, tz, cx, cy, cz, radius)
    if radius < 0 then error('[systems] Geometry.segmentSphere: expected a non-negative radius', 2) end
    return Vector.segmentSphere(fx, fy, fz, tx, ty, tz, cx, cy, cz, radius)
end

---The yaw and pitch, in radians, that point an effect along a velocity: apply them with
---`effect:setOrientation(math.deg(yaw), math.deg(pitch), 0)`, which takes degrees. A climbing velocity gives a negative
---pitch: in Warcraft a positive pitch points the nose down. A zero velocity gives 0, 0.
---@param vx number
---@param vy number
---@param vz number
---@return number yaw
---@return number pitch
function Geometry.orientation(vx, vy, vz)
    numbers('Geometry.orientation', 3, vx, vy, vz)
    return Vector.orientation(vx, vy, vz)
end

return Geometry
