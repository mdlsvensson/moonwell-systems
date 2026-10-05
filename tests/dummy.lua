bj_MAX_PLAYER_SLOTS = 28
UNIT_STATE_MANA = {}
local PLAYER_RAW, LOCUST, MISSING = {}, 1097625443, 666
local accept = true
native('Player', function() return PLAYER_RAW end)
native('CreateUnit', function(owner, typeId, x, y, facing)
    return {owner = owner, typeId = typeId, x = x, y = y, facing = facing, abilities = {}}
end)
native('RemoveUnit', function(raw) raw.removed = true end)
native('UnitAddAbility', function(raw, id)
    if id == MISSING then return false end
    raw.abilities[id] = 1
    return true
end)
native('GetUnitAbilityLevel', function(raw, id) return raw.abilities[id] or 0 end)
native('SetUnitAbilityLevel', function(raw, id, level) raw.abilities[id] = level; return level end)
native('SetUnitInvulnerable', function(raw, flag) raw.invulnerable = flag end)
native('SetUnitPathing', function(raw, flag) raw.pathing = flag end)
native('BlzGetUnitMaxMana', function() return 300 end)
native('SetUnitState', function(raw, _, value) raw.mana = value end)
for _, name in ipairs({'IssueImmediateOrder', 'IssuePointOrder', 'IssueTargetOrder', 'IssueImmediateOrderById',
    'IssuePointOrderById', 'IssueTargetOrderById'}) do
    native(name, function(raw, order, a, b) raw.issued = {name, order, a, b}; return accept end)
end
local Scheduler = require('systems.scheduler')
local Dummies = require('systems.dummy')
local Unit = require('wrappers.unit')
local Player = require('wrappers.player')

local function request(fields)
    local result = {owner = Player.fromIndex(0), typeId = 1, x = 0, y = 0, ability = 2, order = 'slow', duration = 2}
    for key, value in pairs(fields or {}) do result[key] = value end
    return result
end

test('a lease lives through its duration and cleans up once; the dummy is configured', function()
    local clock = Scheduler.new({step = 1})
    local dummies = Dummies.new({clock = clock})
    local lease = dummies:cast(request())
    local raw = lease:getUnit().handle
    eq(lease:isOrderAccepted(), true); eq(dummies:getCount(), 1); eq(lease:isActive(), true)
    eq(raw.abilities[LOCUST], 1); eq(raw.invulnerable, true); eq(raw.pathing, false)
    eq(raw.abilities[2], 1); eq(raw.mana, 300); eq(raw.facing, 0)
    eq(raw.issued[1], 'IssueImmediateOrder'); eq(raw.issued[2], 'slow')
    clock:advance(); eq(dummies:getCount(), 1)
    clock:advance(); eq(dummies:getCount(), 0); eq(raw.removed, true); eq(lease:isActive(), false)
    lease:dispose()
    eq(callCount('RemoveUnit'), 1); eq(clock:getPending(), 0)
end)

test('a missing ability and a rejected order remove the dummy at once', function()
    local clock = Scheduler.new({step = 1})
    local dummies = Dummies.new({clock = clock})
    failsAt(function() dummies:cast(request({ability = MISSING})) end,
        'Dummies.cast: the dummy cannot get ability 666')
    eq(dummies:getCount(), 0); eq(callCount('RemoveUnit'), 1)
    accept = false
    local lease = dummies:cast(request())
    accept = true
    eq(lease:isOrderAccepted(), false); eq(lease:isActive(), false)
    eq(dummies:getCount(), 0); eq(clock:getPending(), 0)
end)

test('dispose removes every dummy in cast order and refuses new casts', function()
    local clock = Scheduler.new({step = 1})
    local dummies = Dummies.new({clock = clock})
    local first = dummies:cast(request({duration = 4})):getUnit().handle
    local second = dummies:cast(request({duration = 4})):getUnit().handle
    dummies:dispose(); dummies:dispose()
    eq(dummies:getCount(), 0); eq(clock:getPending(), 0); eq(callCount('RemoveUnit'), 2)
    expectCall('RemoveUnit', second) -- the last removal was the second cast
    eq(first.removed, true)
    failsAt(function() dummies:cast(request()) end, 'Dummies.cast: the manager is disposed')
end)

test('dummies attribute to their caster only while leased', function()
    local clock = Scheduler.new({step = 1})
    local dummies = Dummies.new({clock = clock})
    local hero = Unit.fromHandle({})
    local lease = dummies:cast(request({source = hero}))
    local unit = lease:getUnit()
    eq(dummies:isDummy(unit), true); eq(dummies:sourceOf(unit), hero); eq(lease:getSource(), hero)
    eq(dummies:sourceOf(hero), nil); eq(dummies:isDummy(hero), false)
    clock:advance(); clock:advance()
    eq(dummies:isDummy(unit), false); eq(dummies:sourceOf(unit), nil)
end)

test('point, target, order ids, level and facing reach the natives', function()
    local clock = Scheduler.new({step = 1})
    local dummies = Dummies.new({clock = clock})
    local raw = dummies:cast(request({point = {x = 5, y = 6}, level = 3, facing = 90})):getUnit().handle
    eq(raw.issued[1], 'IssuePointOrder'); eq(raw.issued[3], 5); eq(raw.issued[4], 6)
    eq(raw.abilities[2], 3); eq(raw.facing, 90)
    local target = Unit.fromHandle({})
    raw = dummies:cast(request({target = target, order = 852075})):getUnit().handle
    eq(raw.issued[1], 'IssueTargetOrderById'); eq(raw.issued[2], 852075); eq(raw.issued[3], target.handle)
    raw = dummies:cast(request({order = 852075})):getUnit().handle
    eq(raw.issued[1], 'IssueImmediateOrderById')
    raw = dummies:cast(request({target = target})):getUnit().handle
    eq(raw.issued[1], 'IssueTargetOrder')
    raw = dummies:cast(request({point = {x = 1, y = 2}, order = 852075})):getUnit().handle
    eq(raw.issued[1], 'IssuePointOrderById')
end)

test('a dummy removed by other code is not removed again', function()
    local clock = Scheduler.new({step = 1})
    local dummies = Dummies.new({clock = clock})
    local lease = dummies:cast(request())
    lease:getUnit():remove()
    clock:advance(); clock:advance()
    eq(callCount('RemoveUnit'), 1); eq(dummies:getCount(), 0)
end)

test('arguments are checked at the caller', function()
    local clock = Scheduler.new({step = 1})
    failsAt(function() Dummies.new({}) end, "Dummies.new: 'clock' expected a Scheduler")
    failsAt(function() Dummies.new(clock) end, 'Dummies.new: expected an options table')
    failsAt(function() Dummies.new({clock = clock, poll = 1}) end, "Dummies.new: unknown key 'poll'")
    failsAt(function() Dummies.new({clock = clock, onError = 5}) end, "Dummies.new: 'onError' expected a function")
    local dummies = Dummies.new({clock = clock})
    failsAt(function() dummies:cast(5) end, 'Dummies.cast: expected a cast request table')
    local bad = {
        {'owner', {owner = {}}}, {'typeId', {typeId = 1.5}}, {'x', {x = 0 / 0}}, {'y', {y = math.huge}},
        {'facing', {facing = 'north'}}, {'ability', {ability = '2'}}, {'level', {level = 0}},
        {'order', {order = ''}}, {'duration', {duration = 0}}, {'point', {point = {x = 1}}},
        {'target', {target = 5}}, {'point', {target = Unit.fromHandle({}), point = {x = 1, y = 1}}},
        {'source', {source = 'hero'}},
    }
    for _, case in ipairs(bad) do
        failsAt(function() dummies:cast(request(case[2])) end, "Dummies.cast: '" .. case[1] .. "'")
    end
    failsAt(function() dummies:cast(request({levle = 2})) end, "Dummies.cast: unknown key 'levle'")
    eq(callCount('CreateUnit'), 0)
    failsAt(function() Dummies.getCount({}) end, 'Dummies.getCount: expected Dummies')
end)
