local Scheduler = require('systems.scheduler')
local Signal = require('systems.signal')
local Scope = require('systems.scope')
local Time = require('systems.time')

local scope = Scope.new(function(message) print(message) end)
local clock = scope:add(Scheduler.new(1 / 32))
scope:own(clock:start())
local cancel = clock:every(1, function() print(clock:getElapsed(), clock:getTick(), clock:getPending()) end)
clock:after(0.5, function() cancel() end)
print(clock:ticks(0.5), clock:getStep())
local changed = scope:add(Signal.new())
scope:own(changed:subscribe(function(value, text) print(value, text) end, -1))
changed:emit(1, 'one')
print(changed:getCount())
local now = Time.localUtc()
if now then
    local date = Time.unixToUtc(now)
    if date then print(Time.formatUtc(date), Time.dayOfWeek(now)) end
end
print(Time.formatDuration(125), Time.isLeapYear(2024), Time.utcToUnix({year = 2000, month = 2, day = 29}))
print(scope:isActive())
scope:dispose()
return true
