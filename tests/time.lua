local Time = require('systems.time')

local MIN, MAX = -2147483648, 2147483647

local function same(actual, expected)
    for _, key in ipairs({'year', 'month', 'day', 'hour', 'minute', 'second'}) do eq(actual[key], expected[key]) end
end

test('calendar conversion: epoch, negative timestamps, leap days and century rules', function()
    eq(Time.isLeapYear(2000), true); eq(Time.isLeapYear(1900), false); eq(Time.isLeapYear(2024), true)
    eq(Time.isLeapYear(0), false); eq(Time.isLeapYear(2024.5), false)
    eq(Time.utcToUnix({year = 1970, month = 1, day = 1}), 0)
    same(Time.unixToUtc(-1), {year = 1969, month = 12, day = 31, hour = 23, minute = 59, second = 59})
    eq(Time.utcToUnix({year = 2000, month = 2, day = 29, hour = 12}), 951825600)
    eq(Time.utcToUnix({year = 2023, month = 2, day = 29}), nil)
    eq(Time.utcToUnix({year = 2024, month = 13, day = 1}), nil)
    eq(Time.utcToUnix({year = 2024, month = 2, day = 30}), nil)
    eq(Time.utcToUnix({year = 2024, month = 2, day = 1, minute = 60}), nil)
    eq(Time.unixToUtc(0 / 0), nil); eq(Time.unixToUtc(0.5), nil); eq(Time.unixToUtc('0'), nil)
    for _, year in ipairs({1902, 1970, 2000, 2024, 2037}) do
        local date = {year = year, month = 12, day = 31, hour = 23, minute = 59, second = 59}
        same(Time.unixToUtc(Time.utcToUnix(date)), date)
    end
    eq(math.type(Time.utcToUnix({year = 2000.0, month = 1.0, day = 1.0})), 'integer')
end)

test('the range is 32-bit, checked at its edges', function()
    local first = {year = 1901, month = 12, day = 13, hour = 20, minute = 45, second = 52}
    local last = {year = 2038, month = 1, day = 19, hour = 3, minute = 14, second = 7}
    eq(Time.utcToUnix(first), MIN); eq(Time.utcToUnix(last), MAX)
    eq(Time.utcToUnix({year = 1901, month = 12, day = 13, hour = 20, minute = 45, second = 51}), nil)
    eq(Time.utcToUnix({year = 2038, month = 1, day = 19, hour = 3, minute = 14, second = 8}), nil)
    eq(Time.utcToUnix({year = 1900, month = 1, day = 1}), nil)
    eq(Time.utcToUnix({year = 2100, month = 1, day = 1}), nil)
    same(Time.unixToUtc(MIN), first); same(Time.unixToUtc(MAX), last)
    eq(Time.unixToUtc(MIN - 1), nil); eq(Time.unixToUtc(MAX + 1), nil)
    eq(Time.dayOfWeek(MAX + 1), nil)
end)

test('display helpers format durations, UTC dates and weekdays', function()
    eq(Time.formatDuration(0), '0:00'); eq(Time.formatDuration(65.9), '1:05')
    eq(Time.formatDuration(3725), '1:02:05'); eq(Time.formatDuration(-3), '0:00')
    eq(Time.formatUtc(Time.unixToUtc(951782400)), '2000-02-29 00:00:00')
    eq(Time.formatUtc({year = 12, month = 3, day = 4, hour = 5, minute = 6, second = 7}), '0012-03-04 05:06:07')
    eq(Time.dayOfWeek(0), 4); eq(Time.dayOfWeek(-86400), 3); eq(Time.dayOfWeek(951782400), 2)
    eq(Time.dayOfWeek(0.5), nil)
end)

test('localUtc reads os.time and returns nil when it is missing, raises or is out of range', function()
    local original = os.time
    local ok, err = pcall(function()
        os.time = function() return 1790760132 end
        eq(Time.localUtc(), 1790760132)
        os.time = function() error('unavailable') end
        eq(Time.localUtc(), nil)
        os.time = function() return MAX + 1 end
        eq(Time.localUtc(), nil)
        os.time = function() return 5.5 end
        eq(Time.localUtc(), nil)
        os.time = nil
        eq(Time.localUtc(), nil)
    end)
    os.time = original
    assert(ok, err)
    eq(math.type(Time.localUtc()), 'integer')
end)

test('arguments are checked at the caller', function()
    failsAt(function() Time.utcToUnix(5) end, 'Time.utcToUnix: expected a date table')
    failsAt(function() Time.formatUtc({year = 2000}) end,
        'Time.formatUtc: expected a date with numeric year, month, day, hour, minute and second')
    failsAt(function() Time.formatUtc(nil) end,
        'Time.formatUtc: expected a date with numeric year, month, day, hour, minute and second')
    failsAt(function() Time.formatDuration('5') end, 'Time.formatDuration: expected a number')
end)
