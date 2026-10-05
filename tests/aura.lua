local Scheduler = require('systems.scheduler')
local BuffStore = require('systems.buffs')
local Aura = require('systems.aura')
local Unit = require('wrappers.unit')

local function newUnit() return Unit.fromHandle({}) end

test('emitters own independent contributions and recover after dispel', function()
    local clock = Scheduler.new({step = 1})
    local buffs, u = BuffStore.new(clock, {pollInterval = 100}), newUnit()
    local armor = {id = 'armor', kind = 'aura'}
    local targets = {u}
    local a = Aura.new(buffs, armor, 'a', function() return targets end)
    local b = Aura.new(buffs, armor, 'b', function() return {u} end)
    a:update(); b:update(); eq(#buffs:list(u), 2)
    a:dispose(); eq(#buffs:list(u), 1)
    buffs:clearUnit(u, 'dispelled'); b:update(); eq(#buffs:list(u), 1)
    targets = {}; b:dispose(); eq(#buffs:list(u), 0)
end)

test('start updates at once and on its interval; dispose stops the timer', function()
    local clock = Scheduler.new({step = 1})
    local buffs, u, v = BuffStore.new(clock, {pollInterval = 100}), newUnit(), newUnit()
    local targets = {u}
    local aura = Aura.new(buffs, {id = 'a', kind = 'aura'}, 'src', function() return targets end)
    eq(aura:start(2), aura)
    eq(buffs:has(u, 'a'), true)
    targets = {v}
    clock:advance(); eq(buffs:has(v, 'a'), false)
    clock:advance(); eq(buffs:has(v, 'a'), true); eq(buffs:has(u, 'a'), false)
    aura:dispose(); aura:dispose()
    eq(clock:getPending(), 1); eq(buffs:has(v, 'a'), false)
    failsAt(function() aura:start() end, 'Aura.start: the aura is disposed')
end)

test('members follow the query order; a failing query is reported and the timer goes on', function()
    local clock, messages = Scheduler.new({step = 1}), {}
    local buffs, u, v = BuffStore.new(clock, {pollInterval = 100}), newUnit(), newUnit()
    local order, broken = {}, false
    local definition = {id = 'ordered', kind = 'aura',
        onApply = function(buff) order[#order + 1] = buff:getUnit() == u and 'u' or 'v' end}
    local aura = Aura.new(buffs, definition, 'src', function()
        if broken then error('query probe') end
        return {v, u}
    end, function(message) messages[#messages + 1] = message end)
    aura:start(1)
    eq(table.concat(order, ','), 'v,u')
    broken = true
    clock:advance()
    eq(#messages, 1); assert(messages[1]:find('query probe', 1, true), messages[1])
    eq(clock:getPending(), 2) -- the poll and the aura
    broken = false
    buffs:clearUnit(u, 'dispelled')
    clock:advance()
    eq(table.concat(order, ','), 'v,u,u')
end)

test('arguments are checked at the caller', function()
    local clock = Scheduler.new({step = 1})
    local buffs = BuffStore.new(clock, {pollInterval = 100})
    failsAt(function() Aura.new({}, {id = 'a', kind = 'aura'}, nil, print) end, 'Aura.new: expected BuffStore')
    failsAt(function() Aura.new(buffs, {id = 'a', kind = 'active'}, nil, print) end,
        'Aura.new: expected an aura buff definition')
    failsAt(function() Aura.new(buffs, {id = 'a', kind = 'aura'}, nil, 5) end, 'Aura.new: expected a callback function')
    failsAt(function() Aura.new(buffs, {id = 'a', kind = 'aura'}, nil, print, 5) end,
        'Aura.new: expected a callback function')
    local aura = Aura.new(buffs, {id = 'a', kind = 'aura'}, nil, function() return {} end)
    failsAt(function() aura:start(0) end, 'Aura.start: expected a finite positive interval')
    failsAt(function() Aura.update({}) end, 'Aura.update: expected Aura')
end)
