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
Scheduler.new({step = 'fast'}) -- EXPECT assign-type-mismatch
local date = Time.unixToUtc(0)
print(date.year) -- EXPECT need-check-nil
local BuffStore = require('systems.buffs')
local Dummies = require('systems.dummy')
BuffStore.new({clock = clock}):apply(clock, {id = 'x', kind = 'active'}) -- EXPECT param-type-mismatch
Dummies.new(5) -- EXPECT param-type-mismatch
Dummies.new({clock = clock}):nonexistent() -- EXPECT undefined-field
local DamageSystem = require('systems.damage')
local damage = DamageSystem.new()
damage:beforeArmor('x') -- EXPECT param-type-mismatch
damage:nonexistent() -- EXPECT undefined-field
damage:observe(function(hit) hit:setAmount('1') end) -- EXPECT param-type-mismatch
local current = damage:getCurrent()
print(current.amount) -- EXPECT need-check-nil
DamageSystem.new({maxQueue = 'many'}) -- EXPECT assign-type-mismatch
local Geometry = require('systems.geometry')
local Terrain = require('systems.terrain')
local Missiles = require('systems.missile')
local Knockbacks = require('systems.knockback')
Geometry.length('3', 4) -- EXPECT param-type-mismatch
Terrain.new():height(0) -- EXPECT missing-parameter
Missiles.new({clock = clock}):nonexistent() -- EXPECT undefined-field
Missiles.new({clock = clock, terrain = 'yes'}) -- EXPECT assign-type-mismatch
Knockbacks.new({clock = clock, pathing = 'walls'}) -- EXPECT assign-type-mismatch
Knockbacks.new({clock = clock}):apply(clock, {angle = 0, distance = 1, duration = 1}) -- EXPECT param-type-mismatch
local Codec = require('systems.codec')
local Sync = require('systems.sync')
local Savefile = require('systems.savefile')
Codec.new({version = '1', secret = 's', schemas = {}}) -- EXPECT assign-type-mismatch
Codec.new({version = 1, secret = 's', schemas = {}}):encode('data') -- EXPECT param-type-mismatch
Sync.new({clock = clock}):ask(clock, print, print) -- EXPECT param-type-mismatch
Sync.new({clock = clock, timeout = 'soon'}) -- EXPECT assign-type-mismatch
Savefile.new({clock = clock, codec = clock, folder = 'Vale'}) -- EXPECT assign-type-mismatch
Savefile.new():start() -- EXPECT missing-parameter
return true
