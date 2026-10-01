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
local BuffStore = require('systems.buffs')
local Aura = require('systems.aura')
local Dummies = require('systems.dummy')
local Unit = require('wrappers.unit')
local PlayerWrapper = require('wrappers.player')
local owner = PlayerWrapper.fromIndex(0)
local hero = Unit.create(owner, 1215324524, 0, 0, 0)
local buffs = scope:add(BuffStore.new(clock, {pollInterval = 0.5}))
local slow = {id = 'slow', kind = 'active', stacking = 'stack', maxStacks = 3, duration = 5, interval = 1,
    onApply = function(buff) buff:own(function() print(buff:getUnit():getName()) end) end,
    onTick = function(buff) print(buff:getStacks(), buff:getRemaining()) end,
    onRemove = function(buff, reason) print(buff:getId(), reason) end}
local applied = buffs:apply(hero, slow, 'caster')
print(applied:isActive(), buffs:has(hero, 'slow'), buffs:stacks(hero, 'slow'), #buffs:list(hero))
local aura = scope:add(Aura.new(buffs, {id = 'devotion', kind = 'aura'}, hero, function() return {hero} end))
aura:start(0.5)
local dummies = scope:add(Dummies.new(clock))
local lease = dummies:cast({owner = owner, typeId = 1697656880, x = 0, y = 0, ability = 1095267426,
    order = 'thunderbolt', target = hero, duration = 2, source = hero})
print(lease:isOrderAccepted(), dummies:sourceOf(lease:getUnit()), dummies:getCount())
local DamageSystem = require('systems.damage')
local damage = scope:add(DamageSystem.new({sourceOf = function(dealer) return dummies:sourceOf(dealer) end,
    onError = function(message) print(message) end, maxQueue = 16, maxChain = 8, maxPending = 8}))
damage:start()
scope:own(damage:beforeArmor(function(hit)
    hit:setAmount(hit.amount * 2)
    hit:setAttackType(ATTACK_TYPE_MAGIC); hit:setDamageType(DAMAGE_TYPE_MAGIC); hit:setWeaponType(WEAPON_TYPE_WHOKNOWS)
end, -1))
scope:own(damage:afterArmor(function(hit) if hit:isLethal() then hit:cancel() end end))
scope:own(damage:observe(function(hit)
    local source, dealer = hit.source, hit.dealer
    print(source and source:getName(), dealer and dealer:getName(), hit.target:getName(), hit.amount, hit.metadata,
        hit.phase, hit.initialAmount, hit.beforeArmorAmount, hit.armorAmount, hit.cancelled, hit.paired, hit.isAttack)
end))
damage:deal({source = hero, target = hero, amount = 5, attack = true, ranged = false, damageType = DAMAGE_TYPE_MAGIC,
    metadata = 'spell'})
local current = damage:getCurrent()
print(current and current.phase)
print(scope:isActive())
scope:dispose()
return true
