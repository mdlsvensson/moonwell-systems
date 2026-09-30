---Calendar and display helpers for UTC dates and Unix seconds, and the local clock. Timestamps are Warcraft's 32-bit
---integers: from -2147483648 (1901-12-13 20:45:52) to 2147483647 (2038-01-19 03:14:07). Pure except localUtc().
local Time = {}

---@class MoonwellSystems.UtcDate
---@field year integer
---@field month integer 1..12
---@field day integer 1..31, valid for the month.
---@field hour integer? 0..23; default 0 in utcToUnix.
---@field minute integer? 0..59; default 0 in utcToUnix.
---@field second integer? 0..59; default 0 in utcToUnix.

local MIN, MAX = -2147483648, 2147483647

local function integer(value, low, high)
    return math.type(value) ~= nil and value >= low and value <= high and math.floor(value) == value
end

---The value as an integer; the caller has checked it with integer().
---@param value number
---@return integer
local function whole(value) return math.tointeger(value) --[[@as integer]] end

---Whether `year` (1..9999) is a Gregorian leap year.
---@param year integer
---@return boolean
function Time.isLeapYear(year)
    return integer(year, 1, 9999) and year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function daysBeforeYear(year)
    local prior = year - 1
    return prior * 365 + prior // 4 - prior // 100 + prior // 400
end

local function daysInMonth(year, month)
    if month == 2 then return Time.isLeapYear(year) and 29 or 28 end
    if month == 4 or month == 6 or month == 9 or month == 11 then return 30 end
    return 31
end

---Converts a UTC date to Unix seconds. Missing time fields read 0.
---@param date MoonwellSystems.UtcDate
---@return integer? seconds Nil when a field is out of range or not an integer, or the date is outside the range.
function Time.utcToUnix(date)
    if type(date) ~= 'table' then error('[systems] Time.utcToUnix: expected a date table', 2) end
    local year, month, day = date.year, date.month, date.day
    local hour, minute, second = date.hour or 0, date.minute or 0, date.second or 0
    if not (integer(year, 1, 9999) and integer(month, 1, 12)) then return nil end
    year, month = whole(year), whole(month)
    if not (integer(day, 1, daysInMonth(year, month)) and integer(hour, 0, 23) and integer(minute, 0, 59)
        and integer(second, 0, 59)) then
        return nil
    end
    day, hour, minute, second = whole(day), whole(hour), whole(minute), whole(second)
    local days = daysBeforeYear(year) - 719162 + day - 1
    for earlier = 1, month - 1 do days = days + daysInMonth(year, earlier) end
    local rest = hour * 3600 + minute * 60 + second
    -- Warcraft's integers wrap silently, so check the range before multiplying: 24855 days and 11647 s is MAX,
    -- -24856 days and 74752 s is MIN.
    if days > 24855 or (days == 24855 and rest > 11647) then return nil end
    if days < -24856 or (days == -24856 and rest < 74752) then return nil end
    if days < 0 then return (days + 1) * 86400 + (rest - 86400) end
    return days * 86400 + rest
end

---Converts Unix seconds to a UTC date.
---@param seconds integer
---@return MoonwellSystems.UtcDate? date Nil for a non-integer or a value outside the range.
function Time.unixToUtc(seconds)
    if not integer(seconds, MIN, MAX) then return nil end
    seconds = whole(seconds)
    local day, rest = seconds // 86400, seconds % 86400
    local absoluteDay = day + 719162
    local low, high = 1, 10000
    while high - low > 1 do
        local middle = (low + high) // 2
        if daysBeforeYear(middle) <= absoluteDay then low = middle else high = middle end
    end
    local year, month, dayOfYear = low, 1, absoluteDay - daysBeforeYear(low)
    while dayOfYear >= daysInMonth(year, month) do
        dayOfYear = dayOfYear - daysInMonth(year, month)
        month = month + 1
    end
    local hour = rest // 3600
    rest = rest - hour * 3600
    local minute = rest // 60
    return {year = year, month = month, day = dayOfYear + 1, hour = hour, minute = minute, second = rest - minute * 60}
end

---0 = Sunday .. 6 = Saturday.
---@param seconds integer
---@return integer? weekday Nil for a value unixToUtc rejects.
function Time.dayOfWeek(seconds)
    if not integer(seconds, MIN, MAX) then return nil end
    return (whole(seconds) // 86400 + 4) % 7
end

---"YYYY-MM-DD HH:MM:SS".
---@param date MoonwellSystems.UtcDate Every field present.
---@return string
function Time.formatUtc(date)
    local fields = type(date) == 'table'
        and {date.year, date.month, date.day, date.hour, date.minute, date.second} or {}
    for index = 1, 6 do
        if type(fields[index]) ~= 'number' then
            error('[systems] Time.formatUtc: expected a date with numeric year, month, day, hour, minute and second', 2)
        end
        fields[index] = math.floor(fields[index])
    end
    return string.format('%04d-%02d-%02d %02d:%02d:%02d', table.unpack(fields, 1, 6))
end

---Whole-second countdown text: "M:SS", or "H:MM:SS" from one hour. Negative reads "0:00".
---@param seconds number
---@return string
function Time.formatDuration(seconds)
    if type(seconds) ~= 'number' then error('[systems] Time.formatDuration: expected a number', 2) end
    local total = seconds > 0 and math.floor(seconds) or 0
    local hours = total // 3600
    local minutes = (total - hours * 3600) // 60
    local rest = total - hours * 3600 - minutes * 60
    if hours > 0 then return string.format('%d:%02d:%02d', hours, minutes, rest) end
    return string.format('%d:%02d', minutes, rest)
end

---This machine's clock as Unix seconds (os.time, present in Warcraft 3.0.0.24268). Local and untrusted: sync it before
---it affects shared state.
---@return integer? seconds Nil when os.time is missing, raises or gives a value outside the range.
function Time.localUtc()
    local clock = os.time
    if type(clock) ~= 'function' then return nil end
    local ok, seconds = pcall(clock)
    if ok and integer(seconds, MIN, MAX) then return whole(seconds) end
    return nil
end

return Time
