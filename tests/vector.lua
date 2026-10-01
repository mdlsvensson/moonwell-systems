local Vector = require('systems.internal.vector')

local function near(actual, expected)
    if math.abs(actual - expected) > 1e-9 then
        error('expected about ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end

test('length', function()
    eq(Vector.length(3, 4, 0), 5.0); eq(Vector.length(0, 0, 0), 0.0); near(Vector.length(1, 2, 2), 3)
end)

test('turnToward keeps the speed and turns at most the given angle', function()
    local x, y, z = Vector.turnToward(10, 0, 0, 0, 1, 0, math.pi / 4)
    near(Vector.length(x, y, z), 10); near(math.atan(y, x), math.pi / 4); near(z, 0)
    -- Within reach: exactly the direction, at the old speed.
    x, y, z = Vector.turnToward(10, 0, 0, 0, 5, 0, math.pi)
    near(x, 0); near(y, 10); near(z, 0)
    -- Up toward a climbing direction.
    x, y, z = Vector.turnToward(10, 0, 0, 0, 0, 3, math.pi / 6)
    near(Vector.length(x, y, z), 10); near(math.atan(z, x), math.pi / 6); near(y, 0)
end)

test('turnToward: zero vectors, and a direction straight behind turns left', function()
    local x, y, z = Vector.turnToward(0, 0, 0, 1, 0, 0, 1)
    eq(x, 0); eq(y, 0); eq(z, 0)
    x, y, z = Vector.turnToward(3, 4, 5, 0, 0, 0, 1)
    eq(x, 3); eq(y, 4); eq(z, 5)
    x, y, z = Vector.turnToward(10, 0, 0, -1, 0, 0, math.pi / 2)
    near(x, 0); near(y, 10); near(z, 0)
    -- Moving straight up with the direction straight down: turns toward +x.
    x, y, z = Vector.turnToward(0, 0, 10, 0, 0, -1, math.pi / 2)
    near(x, 10); near(y, 0); near(z, 0)
end)

test('segmentSphere gives the earliest contact as a fraction', function()
    near(Vector.segmentSphere(0, 0, 0, 100, 0, 0, 50, 0, 0, 2), 0.48)
    eq(Vector.segmentSphere(0, 0, 0, 100, 0, 0, 1, 0, 0, 2), 0)      -- starts inside
    near(Vector.segmentSphere(0, 0, 0, 100, 0, 0, 50, 2, 0, 2), 0.5)  -- tangent
    eq(Vector.segmentSphere(0, 0, 0, 100, 0, 0, 50, 3, 0, 2), nil)    -- passes beside it
    eq(Vector.segmentSphere(0, 0, 0, 100, 0, 0, -10, 0, 0, 2), nil)   -- behind the start
    eq(Vector.segmentSphere(0, 0, 0, 100, 0, 0, 150, 0, 0, 2), nil)   -- beyond the end
    eq(Vector.segmentSphere(0, 0, 0, 100, 0, 0, 50, 0, 5, 2), nil)    -- above the path
    eq(Vector.segmentSphere(0, 0, 0, 0, 0, 0, 5, 0, 0, 2), nil)       -- no length, outside
    eq(Vector.segmentSphere(0, 0, 0, 0, 0, 0, 1, 0, 0, 2), 0)         -- no length, inside
end)

test('orientation: yaw from the horizontal direction, a negative pitch when climbing', function()
    local yaw, pitch = Vector.orientation(1, 0, 0)
    near(yaw, 0); near(pitch, 0)
    yaw, pitch = Vector.orientation(0, 1, 0)
    near(yaw, math.pi / 2); near(pitch, 0)
    yaw, pitch = Vector.orientation(-1, 0, 0)
    near(yaw, math.pi)
    yaw, pitch = Vector.orientation(1, 0, 1)
    near(yaw, 0); near(pitch, -math.pi / 4)
    yaw, pitch = Vector.orientation(0, 0, -1)
    near(yaw, 0); near(pitch, math.pi / 2)
    yaw, pitch = Vector.orientation(0, 0, 0)
    eq(yaw, 0); eq(pitch, 0)
end)
