local Geometry = require('systems.geometry')

test('the functions answer like the internal ones', function()
    eq(Geometry.length(3, 4), 5.0); eq(Geometry.length(2, 3, 6), 7.0)
    local x, y, z = Geometry.turnToward(10, 0, 0, -1, 0, 0, math.pi / 2)
    assert(math.abs(x) < 1e-9 and math.abs(y - 10) < 1e-9 and z == 0, x .. ' ' .. y .. ' ' .. z)
    eq(Geometry.segmentSphere(0, 0, 0, 100, 0, 0, 50, 2, 0, 2), 0.5)
    eq(Geometry.segmentSphere(0, 0, 0, 100, 0, 0, 50, 3, 0, 2), nil)
    local yaw, pitch = Geometry.orientation(0, 1, 0)
    assert(math.abs(yaw - math.pi / 2) < 1e-9 and pitch == 0, yaw .. ' ' .. pitch)
    eq(totalCalls(), 0)
end)

test('arguments are checked at the caller', function()
    failsAt(function() Geometry.length('3', 4) end, 'Geometry.length: expected finite numbers')
    failsAt(function() Geometry.length(3, 0 / 0) end, 'Geometry.length: expected finite numbers')
    failsAt(function() Geometry.turnToward(1, 0, 0, 0, 1, 0) end, 'Geometry.turnToward: expected finite numbers')
    failsAt(function() Geometry.turnToward(1, 0, 0, 0, math.huge, 0, 1) end,
        'Geometry.turnToward: expected finite numbers')
    failsAt(function() Geometry.turnToward(1, 0, 0, 0, 1, 0, -1) end,
        'Geometry.turnToward: expected a non-negative angle')
    failsAt(function() Geometry.segmentSphere(0, 0, 0, 1, 0, 0, 0, 0, 0) end,
        'Geometry.segmentSphere: expected finite numbers')
    failsAt(function() Geometry.segmentSphere(0, 0, 0, 1, 0, 0, 0, 0, 0, -1) end,
        'Geometry.segmentSphere: expected a non-negative radius')
    failsAt(function() Geometry.orientation(1, nil, 0) end, 'Geometry.orientation: expected finite numbers')
end)
