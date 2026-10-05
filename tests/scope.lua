local Scope = require('systems.scope')

local function joined(list) return table.concat(list, ',') end

test('releases in reverse order, continues after failures and releases late owners at once', function()
    local seen, messages = {}, {}
    local scope = Scope.new({onError = function(message) messages[#messages + 1] = message end})
    scope:own(function() seen[#seen + 1] = 'first' end)
    scope:own(function() error('boom') end)
    scope:add({dispose = function() seen[#seen + 1] = 'second' end})
    eq(scope:isActive(), true)
    scope:dispose(); scope:dispose()
    eq(scope:isActive(), false)
    eq(joined(seen), 'second,first')
    eq(#messages, 1); assert(messages[1]:find('boom', 1, true), messages[1])
    scope:own(function() seen[#seen + 1] = 'late' end)
    scope:add({destroy = function() seen[#seen + 1] = 'late add' end})
    eq(joined(seen), 'second,first,late,late add')
end)

test('without onError a failing release is printed and the others still run', function()
    local seen = {}
    local scope = Scope.new()
    scope:own(function() seen[#seen + 1] = 'ran' end)
    scope:own(function() error('printed release probe') end)
    scope:dispose()
    eq(joined(seen), 'ran'); eq(#PRINTED, 1)
    assert(PRINTED[1]:find('[systems] Scope release failed:', 1, true), PRINTED[1])
end)

test('add prefers dispose, then destroy, then remove, and returns the value', function()
    local seen = {}
    local both = {dispose = function(self) seen[#seen + 1] = 'dispose'; eq(self ~= nil, true) end,
        destroy = function() seen[#seen + 1] = 'destroy' end}
    local destroyable = {destroy = function() seen[#seen + 1] = 'destroy' end}
    local removable = {remove = function() seen[#seen + 1] = 'remove' end}
    local scope = Scope.new()
    eq(scope:add(both), both); eq(scope:add(destroyable), destroyable); eq(scope:add(removable), removable)
    scope:dispose()
    eq(joined(seen), 'remove,destroy,dispose')
end)

test('arguments are checked at the caller', function()
    failsAt(function() Scope.new({onError = 'x'}) end, "Scope.new: 'onError' expected a function")
    failsAt(function() Scope.new({onEror = print}) end, "[systems] Scope.new: unknown key 'onEror'")
    local scope = Scope.new()
    failsAt(function() scope:own(5) end, 'Scope.own: expected a callback function')
    failsAt(function() scope:add({}) end, 'Scope.add: expected a value with dispose, destroy or remove')
    failsAt(function() scope:add(7) end, 'Scope.add: expected a value with dispose, destroy or remove')
    failsAt(function() Scope.dispose({}) end, 'Scope.dispose: expected Scope')
end)
