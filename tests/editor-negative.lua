local Scheduler = require('systems.scheduler')
local Signal = require('systems.signal')
local Scope = require('systems.scope')
local Time = require('systems.time')
local clock = Scheduler.new()
clock:after('1', function() end) -- EXPECT param-type-mismatch
clock:nonexistent() -- EXPECT undefined-field
Scope.new():own(5) -- EXPECT param-type-mismatch
Time.formatDuration('5') -- EXPECT param-type-mismatch
Signal.new():subscribe(function() end, 'high') -- EXPECT param-type-mismatch
local date = Time.unixToUtc(0)
print(date.year) -- EXPECT need-check-nil
local BuffStore = require('systems.buffs')
local Dummies = require('systems.dummy')
BuffStore.new(clock):apply(clock, {id = 'x', kind = 'active'}) -- EXPECT param-type-mismatch
Dummies.new(5) -- EXPECT param-type-mismatch
Dummies.new(clock):nonexistent() -- EXPECT undefined-field
return true
