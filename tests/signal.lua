local Signal = require('systems.signal')

local function joined(list) return table.concat(list, ',') end

test('snapshots additions and honors removals with priority ordering', function()
    local signal = Signal.new()
    local seen, off = {}, function() end
    signal:subscribe(function(value)
        seen[#seen + 1] = value; off()
        signal:subscribe(function(other) seen[#seen + 1] = other + 10 end)
    end, -1)
    off = signal:subscribe(function(value) seen[#seen + 1] = value + 1 end)
    signal:emit(1)
    eq(joined(seen), '1')
    signal:emit(2)
    eq(joined(seen), '1,2,12')
    signal:dispose(); signal:emit(3)
    eq(joined(seen), '1,2,12')
    failsAt(function() signal:subscribe(function() end) end, 'Signal.subscribe: the signal is disposed')
end)

test('lower priority first, equal priorities in subscription order, every argument passed', function()
    local signal = Signal.new()
    local seen = {}
    signal:subscribe(function(a, b) seen[#seen + 1] = 'five' .. a .. b end, 5)
    signal:subscribe(function(a, b) seen[#seen + 1] = 'low' .. a .. b end, -1)
    signal:subscribe(function(a, b) seen[#seen + 1] = 'zeroA' .. a .. b end)
    local off = signal:subscribe(function(a, b) seen[#seen + 1] = 'zeroB' .. a .. b end, 0)
    eq(signal:getCount(), 4)
    signal:emit('x', 1)
    eq(joined(seen), 'lowx1,zeroAx1,zeroBx1,fivex1')
    off(); off()
    eq(signal:getCount(), 3)
end)

test('a failing listener is isolated; onError receives it', function()
    local messages, count = {}, 0
    local signal = Signal.new({onError = function(message) messages[#messages + 1] = message end})
    signal:subscribe(function() error('intentional signal probe') end)
    signal:subscribe(function() count = count + 1 end)
    signal:emit()
    eq(count, 1); eq(#messages, 1); eq(#PRINTED, 0)
    assert(messages[1]:find('intentional signal probe', 1, true), messages[1])
    local plain = Signal.new()
    plain:subscribe(function() error('printed probe') end)
    plain:emit()
    eq(#PRINTED, 1)
    assert(PRINTED[1]:find('[systems] Signal listener failed:', 1, true), PRINTED[1])
end)

test('arguments are checked at the caller', function()
    failsAt(function() Signal.new({onError = 5}) end, "Signal.new: 'onError' expected a function")
    failsAt(function() Signal.new({onEror = print}) end, "[systems] Signal.new: unknown key 'onEror'")
    local signal = Signal.new()
    failsAt(function() signal:subscribe(nil) end, 'Signal.subscribe: expected a callback function')
    failsAt(function() signal:subscribe(print, 'high') end, 'Signal.subscribe: expected a finite priority')
    failsAt(function() signal:subscribe(print, math.huge) end, 'Signal.subscribe: expected a finite priority')
    failsAt(function() Signal.emit({}) end, 'Signal.emit: expected Signal')
    eq(signal:getCount(), 0)
end)

test('an emit walks the listeners without copying them, and dispose is idempotent', function()
    local signal = Signal.new()
    local moved = 0
    local realMove = table.move
    table.move = function(...) moved = moved + 1; return realMove(...) end
    signal:subscribe(function() end)
    signal:emit(); signal:emit()
    table.move = realMove
    eq(moved, 0)
    signal:dispose(); signal:dispose(); eq(signal:getCount(), 0)
end)
