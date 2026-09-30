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
