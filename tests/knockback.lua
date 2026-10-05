PATHING_TYPE_WALKABILITY, UNIT_TYPE_FLYING = {}, {}
-- The world: unwalkable terrain, obstacles the terrain check misses, items on the ground and the world bounds.
local unwalkable = function() return false end
local obstacle = function() return false end
local items, enumerated = {}, nil
local bounds = {minX = -10000, minY = -10000, maxX = 10000, maxY = 10000}

native('UnitAlive', function(unit) return unit.alive end)
native('GetUnitX', function(unit) return unit.x end)
native('GetUnitY', function(unit) return unit.y end)
native('SetUnitX', function(unit, x) unit.x = x end)
native('SetUnitY', function(unit, y) unit.y = y end)
native('IsUnitType', function(unit, kind) return kind == UNIT_TYPE_FLYING and unit.flying == true end)
native('RemoveUnit', function(unit) unit.alive = false end)
native('GetWorldBounds', function() return bounds end)
native('GetRectMinX', function(rect) return rect.minX end)
native('GetRectMinY', function(rect) return rect.minY end)
native('GetRectMaxX', function(rect) return rect.maxX end)
native('GetRectMaxY', function(rect) return rect.maxY end)
native('Rect', function(minX, minY, maxX, maxY) return {minX = minX, minY = minY, maxX = maxX, maxY = maxY} end)
native('SetRect', function(rect, minX, minY, maxX, maxY)
    rect.minX, rect.minY, rect.maxX, rect.maxY = minX, minY, maxX, maxY
end)
native('RemoveRect', function() end)
native('RemoveLocation', function() end)
native('IsTerrainPathable', function(x, y) return unwalkable(x, y) end)
native('CreateItem', function(itemType, x, y)
    local item = {itemType = itemType, x = x, y = y, visible = true}
    items[#items + 1] = item
    return item
end)
native('SetItemPosition', function(item, x, y)
    item.visible = true
    item.x, item.y = obstacle(x, y) and x + 80 or x, y
end)
native('GetItemX', function(item) return item.x end)
native('GetItemY', function(item) return item.y end)
native('SetItemVisible', function(item, flag) item.visible = flag end)
native('IsItemVisible', function(item) return item.visible end)
native('EnumItemsInRect', function(rect, _, callback)
    for _, item in ipairs(items) do
        if item.x >= rect.minX and item.x <= rect.maxX and item.y >= rect.minY and item.y <= rect.maxY then
            enumerated = item
            callback()
        end
    end
end)
native('GetEnumItem', function() return enumerated end)
native('RemoveItem', function() end)
local Knockbacks = require('systems.knockback')
local Scheduler = require('systems.scheduler')
local Unit = require('wrappers.unit')
eq(totalCalls(), 0)

-- Every test starts with setup(): a clear world, a clock with the given step and a system with the given options.
local function setup(step, options)
    unwalkable, obstacle = function() return false end, function() return false end
    items = {}
    bounds = {minX = -10000, minY = -10000, maxX = 10000, maxY = 10000}
    local clock = Scheduler.new({step = step or 1})
    local merged = {clock = clock}
    for key, value in pairs(options or {}) do merged[key] = value end
    resetCalls()
    return Knockbacks.new(merged), clock
end
-- A Unit wrapper on a fresh raw handle at the origin.
local function footman(fields)
    local raw = {x = 0, y = 0, alive = true}
    for key, value in pairs(fields or {}) do raw[key] = value end
    return Unit.fromHandle(raw), raw
end
local function push(fields)
    local request = {angle = 0, distance = 10, duration = 1}
    for key, value in pairs(fields or {}) do request[key] = value end
    return request
end
local function near(actual, expected)
    if math.abs(actual - expected) > 1e-9 then
        error('expected about ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end
local function join(list) return table.concat(list, ',') end
local function recorder(reasons) return function(_, reason) reasons[#reasons + 1] = reason end end

test('a replacement owns the unit, and the old handle cannot cancel it', function()
    local system, clock = setup()
    local unit, raw = footman()
    local reasons = {}
    local first = system:apply(unit, push({onEnd = recorder(reasons)}))
    local second = system:apply(unit, push({angle = math.pi / 2, duration = 0.5, onEnd = recorder(reasons)}))
    eq(system:get(unit), second); eq(system:getCount(), 1); eq(first:isActive(), false)
    first:dispose()
    clock:advance()
    near(raw.x, 0); near(raw.y, 10)
    eq(join(reasons), 'replaced,completed'); eq(second:isActive(), false); eq(system:getCount(), 0)
    eq(system:get(unit), nil); eq(#PRINTED, 0)
end)

test('an onEnd that applies again cannot take the unit from the newest knockback', function()
    local system, clock = setup(0.5)
    local unit, raw = footman()
    local nested
    system:apply(unit, push({onEnd = function()
        nested = system:apply(unit, push({angle = math.pi / 2, distance = 30}))
    end}))
    local outer = system:apply(unit, push({distance = 20}))
    clock:advance()
    eq(outer:isActive(), false); eq(nested:isActive(), true); eq(system:get(unit), nested)
    near(raw.x, 0); near(raw.y, 15)
    system:dispose()
    eq(nested:isActive(), false)
end)

test('a dead, removed or disposed unit ends with invalid; a refused move ends with blocked', function()
    local system, clock = setup(0.1, {pathing = function(unit) return unit.handle.free == true end})
    local reasons = {}
    local dead, deadRaw = footman({free = true})
    local disposed = footman({free = true})
    local stuck, stuckRaw = footman()
    system:apply(dead, push({onEnd = recorder(reasons)}))
    system:apply(disposed, push({onEnd = recorder(reasons)}))
    system:apply(stuck, push({onEnd = recorder(reasons)}))
    deadRaw.alive = false
    disposed:remove()
    clock:advance()
    eq(join(reasons), 'invalid,invalid,blocked'); eq(system:getCount(), 0)
    eq(stuckRaw.x, 0); eq(callCount('SetUnitX'), 0); eq(#PRINTED, 0)
end)

test('linear falloff covers the distance and decelerates', function()
    local system, clock = setup(0.5)
    local unit, raw = footman()
    local knockback = system:apply(unit, push({distance = 300, falloff = 'linear'}))
    eq(knockback:getRemaining(), 1); eq(knockback:getUnit(), unit)
    clock:advance()
    near(raw.x, 225); eq(knockback:getRemaining(), 0.5) -- three quarters of the distance in the first half
    clock:advance()
    near(raw.x, 300); eq(knockback:getRemaining(), 0); eq(system:getCount(), 0)
end)

test('a unit moves from where it is, so walking adds to the push', function()
    local system, clock = setup(0.5)
    local unit, raw = footman()
    system:apply(unit, push({distance = 100}))
    clock:advance()
    near(raw.x, 50)
    raw.x, raw.y = 60, 7
    clock:advance()
    near(raw.x, 110); near(raw.y, 7)
end)

test('terrain pathing samples the move and refuses it before moving', function()
    local system, clock = setup(1, {pathing = 'terrain', sampleStep = 10})
    local sampled = {}
    unwalkable = function(x)
        sampled[#sampled + 1] = x
        return x == 20
    end
    local unit, raw = footman()
    local reasons = {}
    system:apply(unit, push({distance = 30, onEnd = recorder(reasons)}))
    clock:advance()
    eq(join(sampled), '10.0,20.0'); eq(join(reasons), 'blocked'); eq(raw.x, 0); eq(callCount('SetUnitX'), 0)
    eq(callCount('CreateItem'), 0) -- the terrain policy places no item
    local free, freeClock = setup(1, {pathing = 'none'})
    local other, otherRaw = footman()
    free:apply(other, push({distance = 30}))
    resetCalls()
    freeClock:advance()
    eq(otherRaw.x, 30.0); eq(callCount('IsTerrainPathable'), 0)
end)

test('obstacles pathing, the default, sees what terrain pathing misses', function()
    local system, clock = setup(0.25)
    obstacle = function(x) return x >= 40 and x <= 60 end
    local unit, raw = footman()
    local reasons = {}
    system:apply(unit, push({distance = 100, onEnd = recorder(reasons)}))
    clock:advance()
    near(raw.x, 25)
    clock:advance()
    near(raw.x, 25); eq(join(reasons), 'blocked'); eq(callCount('CreateItem'), 1); eq(items[1].visible, false)
    local terrain, terrainClock = setup(0.25, {pathing = 'terrain'})
    obstacle = function(x) return x >= 40 and x <= 60 end
    local other, otherRaw = footman()
    terrain:apply(other, push({distance = 100}))
    for _ = 1, 4 do terrainClock:advance() end
    near(otherRaw.x, 100)
end)

test('flying units skip the ground checks, but no policy leaves the world bounds', function()
    local system, clock = setup(1)
    obstacle = function() return true end
    local flyer, flyerRaw = footman({flying = true})
    system:apply(flyer, push({distance = 50}))
    clock:advance()
    eq(flyerRaw.x, 50.0); eq(callCount('CreateItem'), 0)
    local reasons = {}
    for _, pathing in ipairs({'obstacles', 'terrain', 'none', function() return true end}) do
        local bounded, boundedClock = setup(1, {pathing = pathing})
        bounds = {minX = -100, minY = -100, maxX = 100, maxY = 100}
        local unit, raw = footman({flying = true})
        bounded:apply(unit, push({distance = 40, onEnd = recorder(reasons)}))
        boundedClock:advance()
        eq(raw.x, 0) -- 40 is past the bounds shrunk by 64
    end
    eq(join(reasons), 'blocked,blocked,blocked,blocked')
end)

test('a move of too many samples is refused before any is taken', function()
    local system, clock = setup(1, {pathing = 'terrain', sampleStep = 1})
    bounds = {minX = -1e31, minY = -1e31, maxX = 1e31, maxY = 1e31}
    local unit = footman()
    local reasons = {}
    system:apply(unit, push({distance = 1e30, onEnd = recorder(reasons)}))
    clock:advance()
    eq(join(reasons), 'blocked'); eq(callCount('IsTerrainPathable'), 0)
end)

test('a pathing function gets the move; a failing one ends the knockback with error', function()
    local messages, seen = {}, {}
    local system, clock = setup(1, {
        onError = function(message) messages[#messages + 1] = message end,
        pathing = function(unit, fromX, fromY, toX, toY)
            if unit.handle.cursed then error('pathing broke', 0) end
            seen[#seen + 1] = table.concat({fromX, fromY, toX, toY}, ' ')
            return true
        end,
    })
    local unit, raw = footman({x = 5, y = 6})
    local cursed, cursedRaw = footman({cursed = true})
    local reasons = {}
    system:apply(unit, push({onEnd = recorder(reasons)}))
    system:apply(cursed, push({onEnd = recorder(reasons)}))
    clock:advance()
    eq(join(seen), '5 6 15.0 6.0'); eq(raw.x, 15.0)
    eq(join(reasons), 'completed,error'); eq(cursedRaw.x, 0); eq(join(messages), 'pathing broke')
    eq(#PRINTED, 0)
    -- A pathing function that ends the knockback itself: the unit does not move.
    local quitting
    local other, otherClock = setup(1, {pathing = function()
        quitting:dispose()
        return true
    end})
    local still, stillRaw = footman()
    quitting = other:apply(still, push())
    otherClock:advance()
    eq(stillRaw.x, 0); eq(quitting:isActive(), false)
end)

test('a failing onEnd is reported, and dispose still ends everything in apply order', function()
    local messages = {}
    local system, clock = setup(1, {onError = function(message) messages[#messages + 1] = message end})
    local ended = {}
    system:apply(footman(), push({onEnd = function()
        ended[#ended + 1] = 'first'
        error('end failed', 0)
    end}))
    system:apply(footman(), push({onEnd = function(_, reason) ended[#ended + 1] = reason end}))
    system:dispose(); system:dispose()
    eq(join(ended), 'first,disposed'); eq(join(messages), 'end failed'); eq(system:getCount(), 0)
    eq(clock:getPending(), 0)
    failsAt(function() system:apply(footman(), push()) end, 'Knockbacks.apply: the system is disposed')
    local printing = setup()
    printing:apply(footman(), push({onEnd = function() error('printed end', 0) end})):dispose()
    eq(PRINTED[1], '[systems] Knockback end failed: printed end')
end)

test('the system ticks only while units are pushed, and dispose releases the handles', function()
    local system, clock = setup(0.5)
    eq(clock:getPending(), 0)
    local reasons = {}
    local first = system:apply(footman(), push({duration = 0.5}))
    local second = system:apply(footman(), push({onEnd = recorder(reasons)}))
    eq(clock:getPending(), 1)
    clock:advance()
    eq(first:isActive(), false); eq(clock:getPending(), 1)
    second:dispose(); second:dispose()
    eq(join(reasons), 'interrupted'); eq(clock:getPending(), 0); eq(second:getRemaining(), 0)
    system:apply(footman(), push())
    eq(clock:getPending(), 1)
    clock:advance()
    resetCalls()
    system:dispose()
    eq(clock:getPending(), 0); eq(callCount('RemoveItem'), 1); eq(callCount('RemoveRect'), 1)
end)

test('arguments are checked at the caller', function()
    local clock = Scheduler.new({step = 1})
    failsAt(function() Knockbacks.new({}) end, "Knockbacks.new: 'clock' expected a Scheduler")
    failsAt(function() Knockbacks.new(clock) end, 'Knockbacks.new: expected an options table')
    failsAt(function() Knockbacks.new({clock = clock, onError = 5}) end, "Knockbacks.new: 'onError' expected a function")
    failsAt(function() Knockbacks.new({clock = clock, pathing = 'walls'}) end,
        "Knockbacks.new: 'pathing' expected 'obstacles', 'terrain', 'none' or a function")
    failsAt(function() Knockbacks.new({clock = clock, sampleStep = 0}) end,
        "Knockbacks.new: 'sampleStep' expected a finite positive number")
    local system = setup()
    local unit = footman()
    local gone = footman()
    gone:remove()
    failsAt(function() system:apply({}, push()) end, 'Knockbacks.apply: expected a live Unit')
    failsAt(function() system:apply(gone, push()) end, 'Knockbacks.apply: expected a live Unit')
    failsAt(function() system:apply(unit, 5) end, 'Knockbacks.apply: expected a knockback request table')
    local cases = {
        {'angle', {angle = '0'}}, {'distance', {distance = -1}}, {'distance', {distance = 0 / 0}},
        {'duration', {duration = 0}}, {'falloff', {falloff = 'quadratic'}}, {'onEnd', {onEnd = 5}},
    }
    for _, case in ipairs(cases) do
        failsAt(function() system:apply(unit, push(case[2])) end,
            "Knockbacks.apply: '" .. case[1] .. "'")
    end
    failsAt(function() system:apply(unit, {angle = 0, distance = 1, duration = 1, fallof = 'linear'}) end,
        "Knockbacks.apply: unknown key 'fallof'")
    eq(system:getCount(), 0)
    failsAt(function() system:get({}) end, 'Knockbacks.get: expected Unit')
    failsAt(function() Knockbacks.getCount({}) end, 'Knockbacks.getCount: expected Knockbacks')
    local knockback = system:apply(unit, push())
    failsAt(function() knockback.getUnit({}) end, 'Knockback.getUnit: expected Knockback')
    failsAt(function() knockback.dispose({}) end, 'Knockback.dispose: expected Knockback')
end)

test('the stepper starts with the first push and stops when the last one ends', function()
    local system, clock = setup()
    local unit = footman()
    eq(clock:getPending(), 0)
    local push = system:apply(unit, {angle = 0, distance = 10, duration = 3})
    eq(clock:getPending(), 1)
    push:dispose()
    eq(clock:getPending(), 0)
end)
