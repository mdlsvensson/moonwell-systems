-- The world: units (raw handles are tables), a ground function and the effects created.
local world, effects, queries, ranges = {}, {}, {}, {}
local ground = function() return 0 end

native('CreateGroup', function() return {units = {}} end)
native('DestroyGroup', function() end)
native('GroupClear', function(group) group.units = {} end)
-- As measured in game: the enumeration tests unit origins, and clears the group first.
native('GroupEnumUnitsInRange', function(group, x, y, radius)
    queries[#queries + 1] = {x = x, y = y, radius = radius}
    group.units = {}
    for _, unit in ipairs(world) do
        if (unit.x - x) ^ 2 + (unit.y - y) ^ 2 <= radius ^ 2 then group.units[#group.units + 1] = unit end
    end
end)
-- As measured in game: true up to the range plus the unit's collision size.
native('IsUnitInRangeXY', function(unit, x, y, range)
    ranges[#ranges + 1] = {x = x, y = y, range = range}
    return math.sqrt((unit.x - x) ^ 2 + (unit.y - y) ^ 2) <= range + unit.size
end)
native('BlzGroupGetSize', function(group) return #group.units end)
native('BlzGroupUnitAt', function(group, index) return group.units[index + 1] end)
native('UnitAlive', function(unit) return unit.alive end)
native('GetUnitX', function(unit) return unit.x end)
native('GetUnitY', function(unit) return unit.y end)
native('BlzGetUnitCollisionSize', function(unit) return unit.size end)
native('GetUnitFlyHeight', function(unit) return unit.fly end)
native('Location', function(x, y) return {x = x, y = y} end)
native('MoveLocation', function(location, x, y) location.x, location.y = x, y end)
native('GetLocationZ', function(location) return ground(location.x, location.y) end)
native('RemoveLocation', function() end)
native('AddSpecialEffect', function(model, x, y)
    if model == 'missing.mdl' then return nil end
    local effect = {model = model, x = x, y = y, turns = 0, destroyed = 0}
    effects[#effects + 1] = effect
    return effect
end)
native('BlzSetSpecialEffectPosition', function(effect, x, y, z) effect.x, effect.y, effect.z = x, y, z end)
native('BlzSetSpecialEffectOrientation', function(effect, yaw, pitch, roll)
    effect.yaw, effect.pitch, effect.roll = yaw, pitch, roll
    effect.turns = effect.turns + 1
end)
native('BlzSetSpecialEffectScale', function(effect, scale) effect.scale = scale end)
native('DestroyEffect', function(effect) effect.destroyed = effect.destroyed + 1 end)
local Missiles = require('systems.missile')
local Scheduler = require('systems.scheduler')
local Geometry = require('systems.geometry')
local Effect = require('wrappers.effect')
eq(totalCalls(), 0)

-- Every test starts with setup(): an empty flat world, a clock with the given step, and a system whose targets have
-- their centre at their feet and a radius cap of 16, so coordinates read as in the tests' comments.
local function setup(step, options)
    world, effects, queries, ranges = {}, {}, {}, {}
    ground = function() return 0 end
    local clock = Scheduler.new(step or 1)
    local merged = {targetOffset = 0, maxTargetRadius = 16}
    for key, value in pairs(options or {}) do merged[key] = value end
    resetCalls()
    return Missiles.new(clock, merged), clock
end
-- Adds a unit of collision size 1 to the world, after the ones already there.
local function target(name, x, y, fields)
    local unit = {name = name, x = x, y = y or 0, alive = true, size = 1, fly = 0}
    for key, value in pairs(fields or {}) do unit[key] = value end
    world[#world + 1] = unit
    return unit
end
-- A missile from the origin at ground level, flying +x at 100 per second, with radius 1.
local function shot(fields)
    local request = {x = 0, y = 0, height = 0, vx = 100, vy = 0, radius = 1, lifetime = 10}
    for key, value in pairs(fields or {}) do request[key] = value end
    return request
end
local function join(list) return table.concat(list, ',') end
local function recorder(hits) return function(_, unit) hits[#hits + 1] = unit.handle.name end end

test('a swept missile hits fast crossings by distance, then in enumeration order', function()
    local system, clock = setup()
    target('c', 80); target('b', 30); target('a', 30)
    local hits = {}
    local missile = system:launch(shot({maxHits = 3, onHit = recorder(hits)}))
    clock:advance()
    eq(join(hits), 'b,a,c'); eq(missile:isActive(), false); eq(missile:getHitCount(), 3)
    local x, y, z = missile:getPosition()
    eq(x, 78.0); eq(y, 0.0); eq(z, 0.0)
    eq(#PRINTED, 0)
end)

test('ties keep the enumeration order, whatever the handles are', function()
    local system, clock = setup()
    target('9', 50); target('4', 50); target('7', 50)
    local hits = {}
    system:launch(shot({maxHits = 3, onHit = recorder(hits)}))
    clock:advance()
    eq(join(hits), '9,4,7')
end)

test('the sphere test uses height, and a unit is hit once', function()
    local system, clock = setup()
    target('low', 0); target('high', 0, 0, {fly = 5})
    local hits = {}
    system:launch(shot({vx = 0, maxHits = 10, onHit = recorder(hits)}))
    clock:advance(); clock:advance()
    eq(join(hits), 'low')
end)

test('tangent contacts count; units behind the travel do not', function()
    local system, clock = setup()
    target('beside', 50, 2); target('behind', -10)
    local hits = {}
    local missile = system:launch(shot({onHit = recorder(hits)}))
    clock:advance()
    eq(join(hits), 'beside')
    local x, y = missile:getPosition()
    eq(x, 50.0); eq(y, 0.0)
end)

test('lifetime and range clip the sweep, and a missile that stands still expires', function()
    local system, clock = setup()
    target('far', 40)
    local hits, ends = {}, {}
    local onEnd = function(missile, reason) ends[#ends + 1] = reason end
    local short = system:launch(shot({lifetime = 0.25, onHit = recorder(hits), onEnd = onEnd}))
    local ranged = system:launch(shot({maxRange = 20, onHit = recorder(hits), onEnd = onEnd}))
    local still = system:launch(shot({vx = 0, lifetime = 0.1, onEnd = onEnd}))
    clock:advance()
    eq(join(hits), ''); eq(join(ends), 'expired,range,expired')
    eq((short:getPosition()), 25.0); eq(short:getAge(), 0.25); eq(short:getTravelled(), 25.0)
    eq((ranged:getPosition()), 20.0); eq(ranged:getTravelled(), 20); eq(ranged:getAge(), 0.2)
    eq(still:isActive(), false); eq(system:getCount(), 0)
    -- The range ends a missile before a lifetime that would end it later in the same step.
    local both = system:launch(shot({lifetime = 0.5, maxRange = 20, onEnd = onEnd}))
    clock:advance()
    eq(ends[4], 'range'); eq(both:getAge(), 0.2)
    -- When both end it at the same moment, the lifetime is named.
    system:launch(shot({lifetime = 0.2, maxRange = 20, onEnd = onEnd}))
    clock:advance()
    eq(ends[5], 'expired')
    -- The distance flown ends at exactly maxRange, where adding up the steps would miss it.
    system, clock = setup(0.25)
    local exact = system:launch(shot({vx = 700, maxRange = 90}))
    clock:advance()
    eq(exact:isActive(), false); eq(exact:getTravelled(), 90)
end)

test('a missile launched in a callback waits for the next step; a unit killed by a hit is skipped', function()
    local system, clock = setup()
    target('first', 10)
    local second = target('second', 20)
    local hits, child = {}, nil
    system:launch(shot({maxHits = 3, onHit = function(_, unit)
        hits[#hits + 1] = unit.handle.name
        second.alive = false
        child = system:launch(shot())
    end}))
    clock:advance()
    eq(join(hits), 'first'); eq((child:getPosition()), 0); eq(child:isActive(), true)
    clock:advance()
    eq(child:isActive(), false); eq(child:getHitCount(), 1)
end)

test('filter decides who is hit, and a refused unit is asked again', function()
    local system, clock = setup()
    target('ally', 0, 0, {team = 'ally'}); target('enemy', 0, 0, {team = 'enemy'})
    local hits, asked = {}, {}
    local missile = system:launch(shot({vx = 0, maxHits = 5, onHit = recorder(hits), filter = function(unit, missile)
        asked[#asked + 1] = unit.handle.name
        eq(missile:isActive(), true)
        return unit.handle.team == 'enemy'
    end}))
    clock:advance(); clock:advance()
    eq(join(hits), 'enemy'); eq(join(asked), 'ally,enemy,ally'); eq(missile:getHitCount(), 1)
    -- A filter that disposes the missile ends the step: nothing is hit.
    local quitter = system:launch(shot({vx = 0, onHit = recorder(hits), filter = function(_, missile)
        missile:dispose()
        return true
    end}))
    clock:advance()
    eq(join(hits), 'enemy'); eq(quitter:getHitCount(), 0); eq(#PRINTED, 0)
end)

test('a target larger than maxTargetRadius is hit as if it had that radius', function()
    local system, clock = setup()
    target('giant', 40, 30, {size = 500})
    local hits = {}
    system:launch(shot({onHit = recorder(hits)}))
    clock:advance()
    eq(join(hits), '') -- 30 away from the path: beyond 1 + 16
    system, clock = setup()
    target('giant', 40, 15, {size = 500})
    local missile = system:launch(shot({onHit = recorder(hits)}))
    clock:advance()
    eq(join(hits), 'giant'); eq((missile:getPosition()), 32.0) -- 17 from the centre, not at the start
end)

test('heights are above the ground: the start, the targets and the landing follow the terrain', function()
    local system, clock = setup(0.25)
    ground = function(x) return x >= 50 and 100 or 0 end
    -- Launched on the hill at 240 above it: level with the gryphon's fly height, far above the footman.
    target('footman', 100); target('gryphon', 100, 0, {fly = 240})
    local hits = {}
    local high = system:launch(shot({x = 60, height = 240, onHit = recorder(hits)}))
    eq(select(3, high:getPosition()), 340)
    -- Launched on the low ground at 60: the hill's side is in its way.
    local reason
    local low = system:launch(shot({height = 60, onEnd = function(_, why) reason = why end}))
    clock:advance(); clock:advance()
    eq(join(hits), 'gryphon')
    eq(reason, 'ground')
    local x, _, z = low:getPosition()
    eq(x, 50.0); eq(z, 100)
end)

test('terrain = false: the ground is flat at 0 and no terrain is sampled', function()
    local system, clock = setup(1, {terrain = false})
    ground = function() return 1000 end
    target('gryphon', 50, 0, {fly = 240})
    local hits = {}
    local missile = system:launch(shot({height = 240, onHit = recorder(hits)}))
    eq(select(3, missile:getPosition()), 240)
    clock:advance()
    eq(join(hits), 'gryphon'); eq(callCount('Location'), 0); eq(callCount('GetLocationZ'), 0)
    local reason
    system:launch(shot({height = 10, vz = -100, onEnd = function(_, why) reason = why end}))
    clock:advance()
    eq(reason, 'ground')
end)

test('gravity arcs a missile into the ground', function()
    local system, clock = setup(0.1)
    local reason
    local missile = system:launch(shot({vz = 100, az = -200, onEnd = function(_, why) reason = why end}))
    for _ = 1, 20 do
        if missile:isActive() then clock:advance() end
    end
    eq(reason, 'ground')
    local x, _, z = missile:getPosition()
    eq(z, 0); assert(x > 90 and x < 110, 'landed at ' .. x)
end)

test('followGround keeps the height over a rise and never lands', function()
    local system, clock = setup(0.25)
    ground = function(x) return x >= 50 and 100 or 0 end
    local missile = system:launch(shot({height = 60, followGround = true, model = 'bolt.mdl'}))
    clock:advance()
    eq(select(3, missile:getPosition()), 60)
    clock:advance()
    local x, _, z = missile:getPosition()
    eq(x, 50.0); eq(z, 160); eq(missile:isActive(), true)
    assert(effects[1].pitch < 0, 'the bolt noses up the rise: ' .. tostring(effects[1].pitch))
    failsAt(function() missile:setVelocity(100, 0, 5) end,
        'Missile.setVelocity: a followGround missile has no vertical velocity')
    failsAt(function() system:launch(shot({followGround = true, vz = 1})) end,
        'Missiles.launch: expected a missile request: followGround')
    failsAt(function() system:launch(shot({followGround = true, az = -1})) end,
        'Missiles.launch: expected a missile request: followGround')
end)

test('steering with turnToward homes on a target beside the path', function()
    local system, clock = setup(1 / 32)
    target('goal', 0, 500)
    local hit = false
    local missile = system:launch(shot({vx = 300, lifetime = 20, onHit = function() hit = true end,
        steer = function(missile, dt)
            local x, y, z = missile:getPosition()
            local vx, vy, vz = missile:getVelocity()
            missile:setVelocity(Geometry.turnToward(vx, vy, vz, 0 - x, 500 - y, 0 - z, math.pi * dt))
        end}))
    for _ = 1, 400 do
        if missile:isActive() then clock:advance() end
    end
    eq(hit, true); eq(#PRINTED, 0)
end)

test('a model becomes an effect that is placed, scaled, turned along the travel and destroyed once', function()
    local system, clock = setup()
    ground = function() return 10 end
    local missile = system:launch(shot({vx = 0, vy = 100, height = 60, model = 'bolt.mdl', scale = 2, lifetime = 2}))
    local effect = effects[1]
    expectCall('AddSpecialEffect', 'bolt.mdl', 0, 0)
    eq(effect.z, 70); eq(effect.scale, 2); eq(effect.yaw, math.pi / 2); eq(effect.pitch, 0); eq(effect.turns, 1)
    eq(missile:getEffect().handle, effect)
    clock:advance()
    eq(effect.y, 100.0); eq(effect.z, 70); eq(effect.turns, 1) -- the same direction: not turned again
    missile:setVelocity(100, 0, 0)
    clock:advance()
    eq(effect.yaw, 0); eq(effect.turns, 2); eq(effect.destroyed, 1); eq(missile:isActive(), false)
    missile:dispose(); system:dispose()
    eq(effect.destroyed, 1); eq(callCount('DestroyEffect'), 1)
end)

test('an Effect is taken over; face = false leaves its orientation alone', function()
    local system, clock = setup()
    local own = Effect.create('own.mdl', 5, 5)
    local missile = system:launch(shot({effect = own, face = false, lifetime = 1}))
    eq(missile:getEffect(), own); eq(effects[1].x, 0); eq(effects[1].turns, 0)
    clock:advance()
    eq(effects[1].x, 100.0); eq(effects[1].turns, 0); eq(own:isDisposed(), true); eq(effects[1].destroyed, 1)
    -- An effect its owner destroyed first is not destroyed again.
    local early = Effect.create('own.mdl', 0, 0)
    local second = system:launch(shot({effect = early}))
    early:destroy()
    second:dispose()
    eq(effects[2].destroyed, 1); eq(#PRINTED, 0)
end)

test('the query covers the segment and the radii, with one reused group', function()
    local system, clock = setup()
    target('enumerated, but out of reach', 50, 60)
    system:launch(shot({radius = 2, lifetime = 2}))
    clock:advance()
    -- Units are enumerated by their origins: half the step, the missile's radius and the largest target radius.
    eq(queries[1].x, 50.0); eq(queries[1].y, 0.0); eq(queries[1].radius, 68.0)
    -- One native rules the unit out: the step's midpoint, half the step and the missile's radius.
    eq(#ranges, 1); eq(ranges[1].x, 50.0); eq(ranges[1].y, 0.0); eq(ranges[1].range, 52.0)
    eq(callCount('GetUnitX'), 0); eq(callCount('BlzGetUnitCollisionSize'), 0); eq(callCount('UnitAlive'), 0)
    eq(callCount('GetLocationZ'), 2) -- the launch and the landing check: nothing for the unit
    clock:advance()
    -- The next enumeration clears the group itself.
    eq(callCount('CreateGroup'), 1); eq(callCount('GroupClear'), 0)
    system:dispose(); system:dispose()
    eq(callCount('DestroyGroup'), 1)
end)

test('the cheap test never rules out a unit the step touches', function()
    -- Just past the step's end: the missile's radius reaches it from x = 99.5.
    local system, clock = setup()
    target('past the end', 101.5)
    local hits = {}
    local missile = system:launch(shot({onHit = recorder(hits)}))
    clock:advance()
    eq(join(hits), 'past the end'); eq((missile:getPosition()), 99.5)
    -- Beside the middle of the step: it passes the cheap test, and the sphere test refuses it.
    system, clock = setup()
    target('beside', 50, 40)
    hits = {}
    system:launch(shot({onHit = recorder(hits)}))
    clock:advance()
    eq(join(hits), ''); eq(callCount('GetUnitX'), 1); eq(callCount('BlzGetUnitCollisionSize'), 1)
    -- A unit already hit is enumerated again in the next step, and not asked again.
    system, clock = setup()
    target('pierced', 30)
    system:launch(shot({vx = 40, maxHits = 2}))
    clock:advance(); clock:advance()
    eq(#queries, 2); eq(#ranges, 1)
end)

test('a hit callback may dispose the missile: the dispatch stops and the effect is destroyed once', function()
    local system, clock = setup()
    target('first', 10); target('second', 20)
    local hits = {}
    local missile = system:launch(shot({maxHits = 10, model = 'bolt.mdl', onHit = function(missile, unit)
        hits[#hits + 1] = unit.handle.name
        missile:dispose()
    end}))
    clock:advance()
    missile:dispose(); system:dispose()
    eq(join(hits), 'first'); eq(effects[1].destroyed, 1)
end)

test('a missile ended by its own steer, or by another missile, does not move', function()
    local system, clock = setup()
    target('unit', 10)
    local moved = false
    local later
    local first = system:launch(shot({onHit = function() later:dispose() end}))
    later = system:launch(shot({y = 500, steer = function() moved = true end}))
    local quitter = system:launch(shot({y = 900, steer = function(missile) missile:dispose() end}))
    clock:advance()
    eq(first:isActive(), false); eq(moved, false); eq((later:getPosition()), 0)
    eq((quitter:getPosition()), 0); eq(quitter:getAge(), 0); eq(system:getCount(), 0)
end)

test('a failing callback ends that missile with error; the others still move', function()
    local messages = {}
    local system, clock = setup(0.5, {onError = function(message) messages[#messages + 1] = message end})
    target('unit', 10)
    local ends = {}
    local onEnd = function(_, reason) ends[#ends + 1] = reason end
    system:launch(shot({steer = function() error('bad steer', 0) end, onEnd = onEnd}))
    local hitter = system:launch(shot({model = 'bolt.mdl', onEnd = onEnd,
        onHit = function() error('hit failed', 0) end}))
    system:launch(shot({y = 100, filter = function() error('bad filter', 0) end, onEnd = onEnd}))
    target('other', 10, 100)
    local healthy = system:launch(shot({y = 500}))
    clock:advance()
    eq(join(ends), 'error,error,error'); eq(join(messages), 'bad steer,hit failed,bad filter')
    eq(hitter:isActive(), false); eq(effects[1].destroyed, 1)
    eq((healthy:getPosition()), 50.0); eq(system:getCount(), 1)
    -- A failing onEnd is reported and changes nothing else.
    system:launch(shot({lifetime = 0.5, y = 900, onEnd = function() error('end failed', 0) end}))
    clock:advance()
    eq(messages[4], 'end failed'); eq(#PRINTED, 0)
    system, clock = setup()
    system:launch(shot({steer = function() error('printed steer', 0) end}))
    clock:advance()
    eq(PRINTED[1], '[systems] Missile callback failed: printed steer')
end)

test('each missile reports exactly one end reason', function()
    local system, clock = setup()
    target('unit', 50)
    local ends = {}
    local onEnd = function(_, reason) ends[#ends + 1] = reason end
    system:launch(shot({onEnd = onEnd}))
    system:launch(shot({vx = 0, vy = 100, lifetime = 0.5, onEnd = onEnd}))
    system:launch(shot({vx = 0, vy = 100, maxRange = 20, onEnd = onEnd}))
    system:launch(shot({vx = 0, vy = 100, onEnd = onEnd})):dispose()
    clock:advance()
    system:launch(shot({vx = 0, vy = 100, onEnd = onEnd}))
    system:dispose()
    eq(join(ends), 'cancelled,hit-limit,expired,range,disposed')
end)

test('the system ticks only while missiles fly', function()
    local system, clock = setup()
    eq(clock:getPending(), 0)
    local first = system:launch(shot({lifetime = 1}))
    system:launch(shot({lifetime = 2}))
    eq(clock:getPending(), 1); eq(system:getCount(), 2)
    clock:advance()
    eq(first:isActive(), false); eq(clock:getPending(), 1); eq(system:getCount(), 1)
    clock:advance()
    eq(clock:getPending(), 0); eq(system:getCount(), 0)
    local third = system:launch(shot())
    eq(clock:getPending(), 1)
    third:dispose()
    eq(clock:getPending(), 0)
end)

test('dispose inside a callback ends every missile and removes the handles', function()
    local system, clock = setup()
    target('unit', 10)
    local ends = {}
    local onEnd = function(_, reason) ends[#ends + 1] = reason end
    system:launch(shot({onHit = function() system:dispose() end, onEnd = onEnd}))
    system:launch(shot({y = 500, onEnd = onEnd}))
    clock:advance()
    eq(join(ends), 'disposed,disposed'); eq(system:getCount(), 0); eq(clock:getPending(), 0)
    eq(callCount('DestroyGroup'), 1); eq(callCount('RemoveLocation'), 1)
    failsAt(function() system:launch(shot()) end, 'Missiles.launch: the system is disposed')
    eq(#PRINTED, 0)
end)

test('launch checks its request at the caller, before any effect is created', function()
    local system = setup()
    failsAt(function() system:launch(5) end, 'Missiles.launch: expected a missile request table')
    local own = Effect.create('own.mdl', 0, 0)
    local gone = Effect.create('own.mdl', 0, 0)
    gone:destroy()
    resetCalls()
    local cases = {
        {'x', {x = '0'}}, {'y', {y = 0 / 0}}, {'vx', {vx = math.huge}}, {'vy', {vy = false}}, {'radius', {radius = -1}},
        {'lifetime', {lifetime = 0}}, {'height', {height = 'high'}}, {'vz', {vz = {}}}, {'az', {az = '1'}},
        {'maxRange', {maxRange = 0}}, {'maxHits', {maxHits = 0}}, {'maxHits', {maxHits = 1.5}},
        {'velocity', {vx = 1e200}}, {'acceleration', {ax = 1e200}}, {'followGround', {followGround = 1}},
        {'face', {face = 'yes'}}, {'model', {model = ''}}, {'model', {model = 5}}, {'effect', {effect = {}}},
        {'effect', {effect = gone}}, {'model and effect', {model = 'bolt.mdl', effect = own}},
        {'scale', {scale = 2}}, {'scale', {scale = 2, effect = own}}, {'filter', {filter = 5}},
        {'steer', {steer = 'x'}}, {'onHit', {onHit = {}}}, {'onEnd', {onEnd = 1}},
        {'lifetime', {lifetime = -1, model = 'bolt.mdl'}}, {'onEnd', {onEnd = 1, model = 'bolt.mdl', scale = 2}},
    }
    for _, case in ipairs(cases) do
        failsAt(function() system:launch(shot(case[2])) end,
            'Missiles.launch: expected a missile request: ' .. case[1])
    end
    eq(callCount('AddSpecialEffect'), 0); eq(system:getCount(), 0)
    failsAt(function() system:launch(shot({model = 'missing.mdl'})) end,
        'Missiles.launch: [wrappers] Effect.create: native returned nil')
    eq(system:getCount(), 0)
    failsAt(function() Missiles.launch({}, shot()) end, 'Missiles.launch: expected Missiles')
end)

test('launch copies the request, and a missile carries its data', function()
    local system, clock = setup()
    local request = shot({data = {damage = 5}, lifetime = 1})
    local missile = system:launch(request)
    request.vx, request.lifetime = 999, 99
    clock:advance()
    eq((missile:getPosition()), 100.0); eq(missile:isActive(), false); eq(missile.data.damage, 5)
    eq(missile:getAge(), 1); eq(missile:getTravelled(), 100.0)
end)

test('new and the missile methods check their arguments at the caller', function()
    local clock = Scheduler.new(1)
    failsAt(function() Missiles.new({}) end, 'Missiles.new: expected Scheduler')
    failsAt(function() Missiles.new(clock, 5) end, 'Missiles.new: expected an options table')
    failsAt(function() Missiles.new(clock, {onError = 5}) end, 'Missiles.new: expected a callback function')
    for _, case in ipairs({{'terrain', 'yes'}, {'targetOffset', '50'}, {'maxTargetRadius', -1}}) do
        failsAt(function() Missiles.new(clock, {[case[1]] = case[2]}) end,
            'Missiles.new: expected missile options: ' .. case[1])
    end
    local system = setup()
    local missile = system:launch(shot())
    failsAt(function() missile:setVelocity(1, 2) end, 'Missile.setVelocity: expected a finite velocity')
    failsAt(function() missile:setVelocity(1e200, 0, 0) end, 'Missile.setVelocity: expected a finite velocity')
    failsAt(function() missile.getPosition({}) end, 'Missile.getPosition: expected Missile')
    failsAt(function() missile.dispose({}) end, 'Missile.dispose: expected Missile')
    failsAt(function() Missiles.getCount({}) end, 'Missiles.getCount: expected Missiles')
    failsAt(function() Missiles.dispose({}) end, 'Missiles.dispose: expected Missiles')
end)
