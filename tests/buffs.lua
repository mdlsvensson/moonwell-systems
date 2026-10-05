local Scheduler = require('systems.scheduler')
local BuffStore = require('systems.buffs')
local Unit = require('wrappers.unit')

local function newUnit() return Unit.fromHandle({}) end
local function quiet(clock, onError) return BuffStore.new({clock = clock, pollInterval = 100, onError = onError}) end

test('independent stacks expire separately and respect the cap', function()
    local clock = Scheduler.new({step = 1})
    local buffs, u, changes = quiet(clock), newUnit(), {}
    local poison = {id = 'poison', kind = 'active', stacking = 'independent', maxStacks = 2, duration = 2,
        onStacks = function(buff) changes[#changes + 1] = buff:getStacks() end}
    local buff = buffs:apply(u, poison, 'caster')
    clock:advance()
    eq(buffs:apply(u, poison, 'caster'), buff)
    buffs:apply(u, poison, 'caster')
    eq(buff:getStacks(), 2)
    clock:advance(); eq(buff:getStacks(), 1)
    clock:advance(); eq(buff:isActive(), false)
    eq(table.concat(changes, ','), '2,1')
    eq(clock:getPending(), 1) -- only the store's poll
end)

test('refresh extends a buff and removal releases owned effects exactly once', function()
    local clock = Scheduler.new({step = 1})
    local buffs, u, cleaned = quiet(clock), newUnit(), 0
    local haste = {id = 'haste', kind = 'active', duration = 2,
        onApply = function(buff) buff:own(function() cleaned = cleaned + 1 end) end}
    local buff = buffs:apply(u, haste)
    clock:advance(); buffs:apply(u, haste); clock:advance()
    eq(buff:isActive(), true)
    clock:advance(); buff:dispose()
    eq(cleaned, 1); eq(#buffs:list(u), 0)
end)

test('callbacks can remove their buff; death keeps passive buffs; a disposed store refuses', function()
    local clock = Scheduler.new({step = 1})
    local buffs, u = quiet(clock), newUnit()
    local ephemeral = buffs:apply(u, {id = 'cancel', kind = 'active', duration = 2,
        onApply = function(buff) buff:dispose() end})
    eq(ephemeral:isActive(), false); eq(clock:getPending(), 1)
    buffs:apply(u, {id = 'talent', kind = 'passive'})
    buffs:apply(u, {id = 'poison', kind = 'active', duration = 5})
    buffs:apply(u, {id = 'kept', kind = 'active', removeOnDeath = false})
    buffs:clearUnit(u, 'death'); eq(#buffs:list(u), 2)
    buffs:clearUnit(u, 'removed'); eq(#buffs:list(u), 0)
    buffs:dispose(); buffs:dispose()
    failsAt(function() buffs:apply(u, {id = 'x', kind = 'passive'}) end, 'BuffStore.apply: the store is disposed')
    eq(clock:getPending(), 0)
end)

test('a failing release is reported and the rest still run', function()
    local clock, messages, cleanup = Scheduler.new({step = 1}), {}, 0
    local buffs, u = quiet(clock, function(message) messages[#messages + 1] = message end), newUnit()
    local buff = buffs:apply(u, {id = 'cleanup', kind = 'active', duration = 1, onApply = function(b)
        b:own(function() cleanup = cleanup + 1 end)
        b:own(function() error('broken effect') end)
    end})
    buff:dispose()
    eq(cleanup, 1); eq(buff:isActive(), false); eq(#messages, 1)
    assert(messages[1]:find('broken effect', 1, true), messages[1])
    eq(clock:getPending(), 1)
end)

test('periodic buffs tick, report remaining time and stop on removal', function()
    local clock = Scheduler.new({step = 1})
    local buffs, u, ticks = quiet(clock), newUnit(), 0
    local dot = {id = 'dot', kind = 'active', duration = 3, interval = 1, onTick = function() ticks = ticks + 1 end}
    local buff = buffs:apply(u, dot)
    eq(buff:getRemaining(), 3)
    clock:advance(); clock:advance()
    eq(ticks, 2); eq(buff:getRemaining(), 1)
    clock:advance()
    eq(buff:isActive(), false); eq(buff:getRemaining(), 0)
    clock:advance()
    eq(ticks, 3); eq(clock:getPending(), 1)
    eq(buffs:apply(u, {id = 'permanent', kind = 'passive'}):getRemaining(), nil)
end)

test('a failing tick or onApply removes the buff with reason error', function()
    local clock, messages, reasons = Scheduler.new({step = 1}), {}, {}
    local buffs, u = quiet(clock, function(message) messages[#messages + 1] = message end), newUnit()
    local record = function(_, reason) reasons[#reasons + 1] = reason end
    local buff = buffs:apply(u, {id = 'x', kind = 'active', interval = 1,
        onTick = function() error('tick') end, onRemove = record})
    clock:advance()
    eq(buff:isActive(), false); eq(table.concat(reasons, ','), 'error'); eq(#messages, 1)
    local plain = quiet(clock)
    local failed = plain:apply(u,
        {id = 'y', kind = 'active', onApply = function() error('apply') end, onRemove = record})
    eq(failed:isActive(), false); eq(table.concat(reasons, ','), 'error,error'); eq(#PRINTED, 1)
    assert(PRINTED[1]:find('[systems] Buff callback failed:', 1, true), PRINTED[1])
end)

test('lookups, replace and one definition per key', function()
    local clock = Scheduler.new({step = 1})
    local buffs, u, other = quiet(clock), newUnit(), newUnit()
    local sunder = {id = 'sunder', kind = 'active', stacking = 'stack', maxStacks = 5}
    buffs:apply(u, sunder, 'a'); buffs:apply(u, sunder, 'a'); buffs:apply(u, sunder, 'b')
    eq(buffs:stacks(u, 'sunder'), 3); eq(buffs:has(u, 'sunder', 'b'), true)
    eq(buffs:get(u, 'sunder'):getSource(), 'a'); eq(buffs:get(u, 'sunder'):getId(), 'sunder')
    eq(buffs:has(other, 'sunder'), false); eq(buffs:get(u, 'sunder'):getUnit(), u)
    eq(buffs:getScheduler(), clock)
    local reasons = {}
    local shield = {id = 'shield', kind = 'active', stacking = 'replace',
        onRemove = function(_, reason) reasons[#reasons + 1] = reason end}
    local first = buffs:apply(u, shield)
    local second = buffs:apply(u, shield)
    eq(first:isActive(), false); eq(second:isActive(), true); eq(reasons[1], 'replaced')
    eq(second:getDefinition(), shield)
    failsAt(function() buffs:apply(u, {id = 'shield', kind = 'active'}) end,
        'BuffStore.apply: use the same definition for a given id and source')
    buffs:clearSource('a')
    eq(buffs:has(u, 'sunder', 'a'), false); eq(buffs:has(u, 'sunder', 'b'), true)
end)

test('the poll clears removed, disposed and dead units; passive buffs survive death', function()
    native('GetUnitTypeId', function(raw) return raw.gone and 0 or 1 end)
    native('UnitAlive', function(raw) return not raw.dead end)
    native('RemoveUnit', function() end)
    local clock, reasons = Scheduler.new({step = 0.25}), {}
    local function track(name)
        return {id = name, kind = 'active',
            onRemove = function(_, reason) reasons[#reasons + 1] = name .. ':' .. reason end}
    end
    local gone, dead, disposed, fine = newUnit(), newUnit(), newUnit(), newUnit()
    local buffs = BuffStore.new({clock = clock})
    buffs:apply(gone, track('gone')); buffs:apply(dead, track('dead'))
    buffs:apply(dead, {id = 'talent', kind = 'passive',
        onRemove = function(_, reason) reasons[#reasons + 1] = 'talent:' .. reason end})
    buffs:apply(disposed, track('disposed')); buffs:apply(fine, track('fine'))
    gone.handle.gone = true; dead.handle.dead = true
    disposed:remove()
    resetCalls()
    clock:advance()
    eq(table.concat(reasons, ','), 'gone:removed,dead:death,disposed:removed')
    eq(buffs:has(dead, 'talent'), true); eq(buffs:has(fine, 'fine'), true)
    eq(callCount('GetUnitTypeId'), 3)
    buffs:dispose()
    eq(table.concat(reasons, ','), 'gone:removed,dead:death,disposed:removed,talent:disposed,fine:disposed')
    eq(clock:getPending(), 0)
end)

test('arguments are checked at the caller', function()
    local clock = Scheduler.new({step = 1})
    failsAt(function() BuffStore.new({}) end, "BuffStore.new: 'clock' expected a Scheduler")
    failsAt(function() BuffStore.new(clock) end, 'BuffStore.new: expected an options table')
    failsAt(function() BuffStore.new({clock = clock, extra = 5}) end, "BuffStore.new: unknown key 'extra'")
    failsAt(function() BuffStore.new({clock = clock, pollInterval = 0}) end,
        "BuffStore.new: 'pollInterval' expected a finite positive number")
    failsAt(function() BuffStore.new({clock = clock, onError = 5}) end, "BuffStore.new: 'onError' expected a function")
    local buffs, u = quiet(clock), newUnit()
    failsAt(function() buffs:apply({}, {id = 'x', kind = 'active'}) end, 'BuffStore.apply: expected Unit')
    failsAt(function() buffs:apply(u, 5) end, 'BuffStore.apply: expected a buff definition table')
    local bad = {
        {'id', {id = '', kind = 'active'}}, {'kind', {id = 'x', kind = 'weird'}},
        {'stacking', {id = 'x', kind = 'active', stacking = 'pile'}},
        {'maxStacks', {id = 'x', kind = 'active', maxStacks = 0}},
        {'maxStacks', {id = 'x', kind = 'active', maxStacks = math.huge}}, -- a cap is finite: no "no cap"
        {'duration', {id = 'x', kind = 'active', duration = -1}},
        {'interval', {id = 'x', kind = 'active', interval = 0}},
        {'removeOnDeath', {id = 'x', kind = 'active', removeOnDeath = 'yes'}},
        {'onTick', {id = 'x', kind = 'active', onTick = 5}},
    }
    for _, case in ipairs(bad) do
        failsAt(function() buffs:apply(u, case[2]) end, "BuffStore.apply: '" .. case[1] .. "' expected")
    end
    failsAt(function() buffs:clearUnit(u, 'gone') end, 'BuffStore.clearUnit: expected a removal reason')
    local buff = buffs:apply(u, {id = 'x', kind = 'active'})
    failsAt(function() buff:dispose('bad') end, 'Buff.dispose: expected a removal reason')
    failsAt(function() buff:own(5) end, 'Buff.own: expected a callback function')
    failsAt(function() buff.getStacks({}) end, 'Buff.getStacks: expected Buff')
    eq(#buffs:list(u), 1)
end)

test('a definition is checked once; open to the map own fields', function()
    local clock = Scheduler.new()
    local buffs = BuffStore.new({clock = clock})
    local u = newUnit()
    local definition = {id = 'mark', kind = 'active', damagePerTick = 5}
    buffs:apply(u, definition)
    definition.stacking = 'nonsense' -- not checked again: a definition is read when first applied
    buffs:apply(u, definition)
    eq(buffs:stacks(u, 'mark'), 1)
end)

test('a poll walks the units without building a key array, and one failing unit does not stop the others', function()
    local Ordered = require('systems.internal.ordered')
    local realKeys = Ordered.keys
    local keyCalls = 0
    Ordered.keys = function(...) keyCalls = keyCalls + 1; return realKeys(...) end
    local messages = {}
    local clock = Scheduler.new({step = 0.25})
    local buffs = BuffStore.new({clock = clock, onError = function(message) messages[#messages + 1] = message end})
    local broken, dead = newUnit(), newUnit()
    broken.exists = function() error('probe broke') end
    buffs:apply(broken, {id = 'a', kind = 'active'}); buffs:apply(dead, {id = 'b', kind = 'active'})
    dead.isAlive = function() return false end
    clock:advance()
    Ordered.keys = realKeys
    eq(keyCalls, 0); eq(#messages, 1); eq(buffs:has(dead, 'b'), false); eq(buffs:has(broken, 'a'), true)
end)

test('Buff:dispose ends a buff with a reason; remove is gone', function()
    local clock = Scheduler.new()
    local buffs = BuffStore.new({clock = clock})
    local reasons = {}
    local buff = buffs:apply(newUnit(), {id = 'x', kind = 'active',
        onRemove = function(_, reason) reasons[#reasons + 1] = reason end})
    eq(buff.remove, nil)
    buff:dispose(); buff:dispose('expired')
    eq(table.concat(reasons, ','), 'dispelled')
    failsAt(function() buffs:apply(newUnit(), {id = 'y', kind = 'active'}):dispose('gone') end,
        'Buff.dispose: expected a removal reason')
end)
