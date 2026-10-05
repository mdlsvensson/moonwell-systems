local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')

-- Stand-ins for public functions: the checks raise at the caller of these.
local function api(value) Callback.check(value, 'Probe.api') end
local function maybe(value) Callback.optional(value, 'Probe.maybe') end
local function helper(value) Callback.check(value, 'Probe.helper', 1) end
local function viaHelper(value) helper(value) end
local Class = {}
local function method(self) Check.receiver(self, Class, 'Probe', 'Probe.method') end

test('call runs the function with its arguments and reports success', function()
    local seen
    eq(Callback.call('Probe', nil, function(a, b) seen = a + b end, 2, 3), true)
    eq(seen, 5); eq(#PRINTED, 0)
end)

test('a failure goes to onError, or is printed', function()
    local messages = {}
    eq(Callback.call('Probe', function(message) messages[#messages + 1] = message end, error, 'first'), false)
    eq(#messages, 1); eq(messages[1], 'first'); eq(#PRINTED, 0)
    eq(Callback.call('Probe', nil, error, 'second'), false)
    eq(#PRINTED, 1); eq(PRINTED[1], '[systems] Probe failed: second')
end)

test('a failing onError is printed with the failure', function()
    eq(Callback.call('Probe', function() error('handler broke', 0) end, error, 'task broke', 0), false)
    eq(#PRINTED, 2)
    eq(PRINTED[1], '[systems] Probe error handler failed: handler broke')
    eq(PRINTED[2], '[systems] Probe failed: task broke')
end)

test('report sends a message to onError, or prints it', function()
    local messages = {}
    Callback.report('Probe', function(message) messages[#messages + 1] = message end, 'first')
    eq(#messages, 1); eq(messages[1], 'first'); eq(#PRINTED, 0)
    Callback.report('Probe', nil, 'second')
    eq(#PRINTED, 1); eq(PRINTED[1], '[systems] Probe failed: second')
    Callback.report('Probe', function() error('handler broke', 0) end, 'third')
    eq(PRINTED[2], '[systems] Probe error handler failed: handler broke')
    eq(PRINTED[3], '[systems] Probe failed: third')
end)

test('an unprintable error is still reported', function()
    local weird = setmetatable({}, {__tostring = function() error('no') end})
    Callback.call('Probe', nil, error, weird)
    eq(PRINTED[1], '[systems] Probe failed: <unprintable error>')
end)

test('check and optional raise at the public caller', function()
    failsAt(function() api(5) end, 'Probe.api: expected a callback function')
    api(function() end)
    failsAt(function() maybe('x') end, 'Probe.maybe: expected a callback function')
    maybe(nil); maybe(print)
    failsAt(function() viaHelper(nil) end, 'Probe.helper: expected a callback function')
end)

test('receiver and finite', function()
    failsAt(function() method({}) end, 'Probe.method: expected Probe')
    method(setmetatable({}, Class))
    eq(Check.finite(1), true); eq(Check.finite(-2.5), true)
    eq(Check.finite(0 / 0), false); eq(Check.finite(math.huge), false); eq(Check.finite(-math.huge), false)
    eq(Check.finite('1'), false); eq(Check.finite(nil), false)
end)

test('integer, positive, nonNegative and identifier', function()
    eq(Check.integer(3), true); eq(Check.integer(-2), true); eq(Check.integer(4.0), true)
    eq(Check.integer(1.5), false); eq(Check.integer('3'), false); eq(Check.integer(math.huge), false)
    eq(Check.integer(0 / 0), false); eq(Check.integer(nil), false)
    eq(Check.positive(0.5), true); eq(Check.positive(0), false); eq(Check.positive(math.huge), false)
    eq(Check.positive('1'), false)
    eq(Check.nonNegative(0), true); eq(Check.nonNegative(-0.1), false); eq(Check.nonNegative(math.huge), false)
    eq(Check.identifier('mw-save_1'), true); eq(Check.identifier(string.rep('a', 32)), true)
    eq(Check.identifier(string.rep('a', 33)), false); eq(Check.identifier(''), false)
    eq(Check.identifier('a b'), false); eq(Check.identifier(5), false)
end)

test('liveUnit takes the class it checks against', function()
    local Unit = {}
    local live = setmetatable({isDisposed = function() return false end}, Unit)
    local gone = setmetatable({isDisposed = function() return true end}, Unit)
    eq(Check.liveUnit(live, Unit), true); eq(Check.liveUnit(gone, Unit), false)
    eq(Check.liveUnit({isDisposed = function() return false end}, Unit), false); eq(Check.liveUnit(nil, Unit), false)
end)

test('reason drops the position and a systems label, and keeps a wrappers label', function()
    eq(Callback.reason('src/x.lua:12: [systems] Codec.encode: field "a": bad'), 'field "a": bad')
    eq(Callback.reason('src/x.lua:3: [wrappers] Effect.create: native returned nil'),
        '[wrappers] Effect.create: native returned nil')
    eq(Callback.reason('plain'), 'plain')
    eq(Callback.reason(setmetatable({}, {__tostring = function() error('no') end})), '<unprintable error>')
end)

