local Fields = require('systems.internal.fields')

local SPEC = {
    step = {'positive', default = 0.25},
    name = {'identifier', required = true},
    count = {Fields.integer(1, 10)},
    mode = {Fields.enum({'none', 'linear'}), default = 'none'},
    onError = {'function'},
}
-- Stand-ins for public functions: Fields raises at the caller of these.
local function new(options)
    local read = Fields.options(options, SPEC, 'Probe.new')
    return read
end
local function launch(request)
    local read = Fields.request(request, SPEC, 'Probe.launch', 'a probe request table')
    return read
end
local function helper(options)
    local read = Fields.options(options, SPEC, 'Probe.helper', 1)
    return read
end
local function viaHelper(options)
    local read = helper(options)
    return read
end

test('read returns a fresh table with defaults and never changes the input', function()
    local given = {name = 'abc', count = 3}
    local read = new(given)
    eq(read.name, 'abc'); eq(read.count, 3); eq(read.step, 0.25); eq(read.mode, 'none'); eq(read.onError, nil)
    eq(given.step, nil); assert(read ~= given)
end)

test('options may be nil; a request may not', function()
    failsAt(function() new(nil) end, "Probe.new: 'name' expected 1 to 32 letters, digits, - or _")
    failsAt(function() launch(nil) end, 'Probe.launch: expected a probe request table')
    failsAt(function() launch(5) end, 'Probe.launch: expected a probe request table')
    failsAt(function() new(5) end, 'Probe.new: expected an options table')
end)

test('a table with a metatable is not an options table (the old positional call)', function()
    local scheduler = setmetatable({advancing = false}, {})
    failsAt(function() new(scheduler) end, 'Probe.new: expected an options table')
    failsAt(function() launch(scheduler) end, 'Probe.launch: expected a probe request table')
    local open = Fields.request(setmetatable({name = 'x'}, {}), SPEC, 'Probe.open', 'a definition table', 0, true)
    eq(open.name, 'x')
end)

test('unknown keys are refused, the first in sorted order, array keys included', function()
    failsAt(function() new({name = 'a', zeta = 1, alpha = 2}) end, "Probe.new: unknown key 'alpha'")
    failsAt(function() new({name = 'a', zeta = 1}) end, "Probe.new: unknown key 'zeta'")
    failsAt(function() new({0.25}) end, "Probe.new: unknown key '1'")
    eq(Fields.request({name = 'a', extra = 1}, SPEC, 'Probe.open', 'x', 0, true).extra, nil)
    eq(Fields.unknown({b = 1, a = 2, name = 3}, SPEC), 'a'); eq(Fields.unknown({name = 1}, SPEC), nil)
end)

test('a key with no stable text is shown by its type, the same on every machine', function()
    failsAt(function() new({name = 'a', [{}] = 1}) end, "Probe.new: unknown key '<table>'")
    failsAt(function() new({name = 'a', [function() end] = 1}) end, "Probe.new: unknown key '<function>'")
    eq(Fields.unknown({[coroutine.create(function() end)] = 1}, SPEC), '<thread>')
    -- Strings, numbers and booleans keep their own text.
    eq(Fields.unknown({[true] = 1}, SPEC), 'true'); eq(Fields.unknown({[2.5] = 1}, SPEC), '2.5')
    -- The smallest by text is reported, whatever the table's address is: '<' sorts after the digits and before
    -- every letter.
    eq(Fields.unknown({name = 'a', [{}] = 1, [7] = 2}, SPEC), '7')
    for _ = 1, 20 do
        eq(Fields.unknown({name = 'a', [{}] = 1, zeta = 2}, SPEC), '<table>')
        eq(Fields.unknown({name = 'a', [{}] = 1, [function() end] = 2, zeta = 3}, SPEC), '<function>')
        failsAt(function() new({name = 'a', [{}] = 1, zeta = 2}) end, "Probe.new: unknown key '<table>'")
    end
end)

test('wrong values name the key and what was expected, the first in sorted order', function()
    failsAt(function() new({name = 'a', step = 0}) end, "Probe.new: 'step' expected a finite positive number")
    failsAt(function() new({name = 'a', count = 11}) end, "Probe.new: 'count' expected a whole number from 1 to 10")
    failsAt(function() new({name = 'a', mode = 'x'}) end, "Probe.new: 'mode' expected one of 'none', 'linear'")
    failsAt(function() new({name = 'a', onError = 1}) end, "Probe.new: 'onError' expected a function")
    failsAt(function() new({name = 'a b', step = 0}) end, "Probe.new: 'name' expected")
end)

test('an integral float is a whole number', function()
    eq(new({name = 'a', count = 4.0}).count, 4.0)
    failsAt(function() new({name = 'a', count = 1.5}) end, "'count' expected a whole number from 1 to 10")
end)

test('depth counts helper frames', function()
    failsAt(function() viaHelper({name = 'a', step = -1}) end, "Probe.helper: 'step' expected")
end)

test('every kind and its description', function()
    local Class = {}
    local cases = {
        {'finite', 1.5, 0 / 0, 'a finite number'},
        {'nonNegative', 0, -1, 'a finite non-negative number'},
        {'boolean', false, 'no', 'true or false'},
        {'string', 'x', '', 'a non-empty string'},
        {'any', {}, nil, nil},
        {Fields.integer(), -3, 0.5, 'a whole number'},
        {Fields.integer(2), 2, 1, 'a whole number of at least 2'},
        {Fields.class(Class, 'a Probe'), setmetatable({}, Class), {}, 'a Probe'},
        {Fields.test(function(v) return v == 7 end, 'seven'), 7, 8, 'seven'},
    }
    local function kind(value, spec)
        local read = Fields.options({value = value}, spec, 'Probe.kind')
        return read
    end
    for _, case in ipairs(cases) do
        local spec = {value = {case[1], required = true}}
        eq(kind(case[2], spec).value, case[2])
        if case[4] then
            failsAt(function() kind(case[3], spec) end,
                "Probe.kind: 'value' expected " .. case[4])
        end
    end
end)
