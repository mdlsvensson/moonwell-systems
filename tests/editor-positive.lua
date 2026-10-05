local Scheduler = require('systems.scheduler')
local Signal = require('systems.signal')
local Scope = require('systems.scope')
local Time = require('systems.time')

local scope = Scope.new({onError = function(message) print(message) end})
local clock = scope:add(Scheduler.new({step = 1 / 32}))
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
local buffs = scope:add(BuffStore.new({clock = clock, pollInterval = 0.5}))
local slow = {id = 'slow', kind = 'active', stacking = 'stack', maxStacks = 3, duration = 5, interval = 1,
    onApply = function(buff) buff:own(function() print(buff:getUnit():getName()) end) end,
    onTick = function(buff) print(buff:getStacks(), buff:getRemaining()) end,
    onRemove = function(buff, reason) print(buff:getId(), reason) end}
local applied = buffs:apply(hero, slow, 'caster')
print(applied:isActive(), buffs:has(hero, 'slow'), buffs:stacks(hero, 'slow'), #buffs:list(hero))
local aura = scope:add(Aura.new({store = buffs, definition = {id = 'devotion', kind = 'aura'}, source = hero,
    query = function() return {hero} end, interval = 0.5}))
aura:start()
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
local Geometry = require('systems.geometry')
local Terrain = require('systems.terrain')
local Missiles = require('systems.missile')
local Knockbacks = require('systems.knockback')
local Effect = require('wrappers.effect')
local terrain = scope:add(Terrain.new({itemType = 2003790951}))
print(terrain:height(0, 0), terrain:isWalkable(0, 0), terrain:isClear(0, 0), terrain:inBounds(0, 0))
print(Geometry.length(3, 4), Geometry.segmentSphere(0, 0, 0, 1, 0, 0, 1, 0, 0, 1), Geometry.orientation(1, 0, 0))
local bolt = 'Abilities\\Weapons\\BallistaMissile\\BallistaMissile.mdl'
local missiles = scope:add(Missiles.new(clock, {terrain = true, targetOffset = 50, maxTargetRadius = 128}))
local missile = missiles:launch({x = 0, y = 0, height = 60, vx = 900, vy = 0, az = -100, radius = 16, lifetime = 2,
    maxRange = 1000, maxHits = 3, model = bolt, scale = 1.5, data = {damage = 40},
    filter = function(unit, flying) return unit ~= hero and flying:isActive() end,
    steer = function(flying, dt)
        local x, y, z = flying:getPosition()
        local vx, vy, vz = flying:getVelocity()
        flying:setVelocity(Geometry.turnToward(vx, vy, vz, hero:getX() - x, hero:getY() - y, -z, 3 * dt))
    end,
    onHit = function(flying, unit) damage:deal({source = hero, target = unit, amount = flying.data.damage}) end,
    onEnd = function(flying, reason) print(flying:getAge(), flying:getTravelled(), flying:getHitCount(), reason) end})
print(missile:getEffect(), missiles:getCount())
missiles:launch({x = 0, y = 0, vx = 500, vy = 0, radius = 8, lifetime = 1, followGround = true, face = false,
    effect = Effect.create(bolt, 0, 0)}):dispose()
local knockbacks = scope:add(Knockbacks.new(clock, {sampleStep = 16, pathing = function(unit, fromX, fromY, toX, toY)
    return unit ~= hero and terrain:isClear(toX, toY) and fromX ~= fromY
end}))
local knockback = knockbacks:apply(hero, {angle = math.atan(1, 0), distance = 300, duration = 0.4, falloff = 'linear',
    onEnd = function(ended, reason) print(ended:getUnit():getName(), reason) end})
print(knockback:isActive(), knockback:getRemaining(), knockbacks:get(hero) == knockback, knockbacks:getCount())
local Codec = require('systems.codec')
local Sync = require('systems.sync')
local Savefile = require('systems.savefile')
local codec = Codec.new({version = 2, secret = 'k3-vale-of-ash', schemas = {
    {version = 1, fields = {{key = 'gold', kind = 'integer', min = 0, max = 1000000}},
        migrate = function(old) return {gold = old.gold, items = {}, name = '', hardMode = false} end},
    {version = 2, fields = {{key = 'gold', kind = 'integer', min = 0, max = 1000000},
        {key = 'items', kind = 'list', maxLength = 6, of = {kind = 'integer', min = 0, max = 2147483647}},
        {key = 'name', kind = 'string', maxLength = 16}, {key = 'hardMode', kind = 'boolean'}}}}})
local code = codec:encode({gold = 500, items = {1, 2}, name = 'Hero', hardMode = true}, owner:getName())
local decoded, why, detail = codec:decode(code, owner:getName())
print(decoded and decoded.gold, why, detail, codec:getVersion(), codec:getMaxLength())
local sync = scope:add(Sync.new(clock, {prefix = 'ask', timeout = 5, maxLength = 100}))
sync:start()
sync:ask(owner, function() return tostring(Time.localUtc()) end, function(text, reason) print(text, reason) end)
local saves = scope:add(Savefile.new(clock, {codec = codec, folder = 'Vale', prefix = 'save', timeout = 5,
    abilities = {1097690227, 1097035619}, onError = print}))
saves:start()
saves:save(owner, 'slot1', {gold = 1, items = {}, name = '', hardMode = false})
saves:load(owner, 'slot1', function(data, reason) print(data and data.gold, reason) end)
print(scope:isActive())
scope:dispose()
return true
