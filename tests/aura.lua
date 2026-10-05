local Scheduler = require('systems.scheduler')
local BuffStore = require('systems.buffs')
local Aura = require('systems.aura')
local Unit = require('wrappers.unit')

local function newUnit() return Unit.fromHandle({}) end

test('emitters own independent contributions and recover after dispel', function()
    local clock = Scheduler.new({step = 1})
    local buffs, u = BuffStore.new({clock = clock, pollInterval = 100}), newUnit()
    local armor = {id = 'armor', kind = 'aura'}
    local targets = {u}
    local a = Aura.new({store = buffs, definition = armor, source = 'a', query = function() return targets end})
    local b = Aura.new({store = buffs, definition = armor, source = 'b', query = function() return {u} end})
    a:update(); b:update(); eq(#buffs:list(u), 2)
    a:dispose(); eq(#buffs:list(u), 1)
    buffs:clearUnit(u, 'dispelled'); b:update(); eq(#buffs:list(u), 1)
    targets = {}; b:dispose(); eq(#buffs:list(u), 0)
end)

test('start updates at once and on its interval; dispose stops the timer', function()
    local clock = Scheduler.new({step = 1})
    local buffs, u, v = BuffStore.new({clock = clock, pollInterval = 100}), newUnit(), newUnit()
    local targets = {u}
    local aura = Aura.new({store = buffs, definition = {id = 'a', kind = 'aura'}, source = 'src',
        query = function() return targets end, interval = 2})
    eq(aura:start(), aura)
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
    local buffs, u, v = BuffStore.new({clock = clock, pollInterval = 100}), newUnit(), newUnit()
    local order, broken = {}, false
    local definition = {id = 'ordered', kind = 'aura',
        onApply = function(buff) order[#order + 1] = buff:getUnit() == u and 'u' or 'v' end}
    local aura = Aura.new({store = buffs, definition = definition, source = 'src', query = function()
        if broken then error('query probe') end
        return {v, u}
    end, onError = function(message) messages[#messages + 1] = message end, interval = 1})
    aura:start()
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
    local buffs = BuffStore.new({clock = clock, pollInterval = 100})
    local devotion = {id = 'a', kind = 'aura'}
    local query = function() return {} end
    failsAt(function() Aura.new({store = {}, definition = devotion, query = query}) end,
        "Aura.new: 'store' expected a BuffStore")
    failsAt(function() Aura.new({store = buffs, definition = {id = 'a', kind = 'active'}, query = query}) end,
        "Aura.new: 'definition' expected an aura buff definition")
    failsAt(function() Aura.new({store = buffs, definition = devotion, query = 5}) end,
        "Aura.new: 'query' expected a function")
    failsAt(function() Aura.new({store = buffs, definition = devotion, query = query, onError = 5}) end,
        "Aura.new: 'onError' expected a function")
    failsAt(function() Aura.new({store = buffs, definition = devotion, query = query, interval = 0}) end,
        "Aura.new: 'interval' expected a finite positive number")
    failsAt(function() Aura.new({store = buffs, definition = devotion, query = query, intervall = 1}) end,
        "[systems] Aura.new: unknown key 'intervall'")
    failsAt(function() Aura.update({}) end, 'Aura.update: expected Aura')
end)
