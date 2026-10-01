local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Events = require('wrappers.damage')
local Timer = require('wrappers.timer')

---A damage pipeline on wrappers.damage: listeners before armor, after armor and once the final amount is known.
---Nothing is created before start().
---@class MoonwellSystems.DamageSystem
---@field package before MoonwellSystems.DamageListener[] Replaced, never changed in place: a dispatch keeps its list.
---@field package after MoonwellSystems.DamageListener[]
---@field package observers MoonwellSystems.DamageListener[]
---@field package pending MoonwellSystems.Hit[] Hits whose DAMAGED has not come, oldest first.
---@field package sourceOf (fun(dealer: MoonwellWrappers.Unit): MoonwellWrappers.Unit?)?
---@field package onError (fun(message: string): ...)?
---@field package maxQueue integer
---@field package maxChain integer
---@field package maxPending integer
---@field package nextListener integer The id of the newest listener; a hit runs the listeners up to its cutoff.
---@field package depth integer Hits whose listeners are running.
---@field package running boolean
---@field package disposed boolean
---@field package current MoonwellSystems.Hit?
---@field package timer MoonwellWrappers.Timer? The settle timer.
---@field package scheduled boolean Whether the settle timer is running.
---@field package onSettle fun(): ...
---@field package damagingToken MoonwellWrappers.DamageListener?
---@field package damagedToken MoonwellWrappers.DamageListener?
local DamageSystem = {}
DamageSystem.__index = DamageSystem

---@class MoonwellSystems.DamageOptions
---@field sourceOf (fun(dealer: MoonwellWrappers.Unit): MoonwellWrappers.Unit?)? Credits a hit to another Unit.
---@field onError (fun(message: string): ...)? Receives failures; default prints them.
---@field maxQueue integer? Most deals that may wait. Default 128.
---@field maxChain integer? Most deals in one chain. Default 64.
---@field maxPending integer? Most hits awaiting their DAMAGED event. Default 64.

---@class MoonwellSystems.DamageListener
---@field id integer
---@field priority number
---@field callback function? Nil once removed.

---One hit, passed to every listener of every phase. The fields are for reading: change the hit with its methods.
---@class MoonwellSystems.Hit
---@field source MoonwellWrappers.Unit? The credited Unit; nil when the game gives no source.
---@field dealer MoonwellWrappers.Unit? The Unit the game reported.
---@field target MoonwellWrappers.Unit
---@field amount number The current amount.
---@field isAttack boolean The game's value: false for script damage.
---@field attackType attacktype
---@field damageType damagetype
---@field weaponType weapontype
---@field metadata any The deal request's metadata; nil for every other hit.
---@field phase 'beforeArmor'|'afterArmor'|'observe'
---@field initialAmount number The amount the game first reported.
---@field beforeArmorAmount number The amount after the beforeArmor listeners.
---@field armorAmount number? The amount DAMAGED reported; nil before that.
---@field cancelled boolean
---@field paired boolean False when DAMAGED came without a known DAMAGING.
---@field package system MoonwellSystems.DamageSystem
---@field package cutoff integer
---@field package event (MoonwellWrappers.DamagingEvent|MoonwellWrappers.DamagedEvent)? Set while modifiers run.
local Hit = {}
Hit.__index = Hit
DamageSystem.Hit = Hit

local DEFAULTS = {maxQueue = 128, maxChain = 64, maxPending = 64}
local LIMITS = {'maxQueue', 'maxChain', 'maxPending'}
local LISTS = {'before', 'after', 'observers'}

-- Hit

---The wrappers event to write to. Warcraft's setters act on the innermost event, so only the hit being handled may
---change, and only while its modifier listeners run.
---@param hit MoonwellSystems.Hit
---@param operation string
---@param types boolean? Whether the setter changes a type.
---@return MoonwellWrappers.DamagingEvent|MoonwellWrappers.DamagedEvent
local function writable(hit, operation, types)
    if getmetatable(hit) ~= Hit then error('[systems] ' .. operation .. ': expected Hit', 3) end
    if hit.system.current == hit then
        if hit.phase == 'observe' then error('[systems] ' .. operation .. ': observers cannot change a hit', 3) end
        if types and hit.phase ~= 'beforeArmor' then
            error('[systems] ' .. operation .. ': types can change only before armor', 3)
        end
        if hit.event then return hit.event end
    end
    error('[systems] ' .. operation .. ': the hit is not being handled', 3)
end

---Sets the amount. Does nothing on a cancelled hit.
---@param amount number Finite and not negative.
function Hit:setAmount(amount)
    local event = writable(self, 'Hit.setAmount')
    if not Check.finite(amount) or amount < 0 then
        error('[systems] Hit.setAmount: expected a finite non-negative amount', 2)
    end
    if self.cancelled then return end
    event:setAmount(amount)
    self.amount = amount
end

---Cancels the hit: the amount becomes 0 and stays 0 in the later phases.
function Hit:cancel()
    local event = writable(self, 'Hit.cancel')
    if self.cancelled then return end
    self.cancelled = true
    event:setAmount(0)
    self.amount = 0
end

---Sets the attack type, which picks the armor table. Before armor only.
---@param attackType attacktype
function Hit:setAttackType(attackType)
    local event = writable(self, 'Hit.setAttackType', true) --[[@as MoonwellWrappers.DamagingEvent]]
    if attackType == nil then error('[systems] Hit.setAttackType: expected an attack type', 2) end
    event:setAttackType(attackType)
    self.attackType = attackType
end

---Sets the damage type, which decides immunity and spell reduction. Before armor only.
---@param damageType damagetype
function Hit:setDamageType(damageType)
    local event = writable(self, 'Hit.setDamageType', true) --[[@as MoonwellWrappers.DamagingEvent]]
    if damageType == nil then error('[systems] Hit.setDamageType: expected a damage type', 2) end
    event:setDamageType(damageType)
    self.damageType = damageType
end

---Sets the weapon type, which decides the impact sound. Before armor only.
---@param weaponType weapontype
function Hit:setWeaponType(weaponType)
    local event = writable(self, 'Hit.setWeaponType', true) --[[@as MoonwellWrappers.DamagingEvent]]
    if weaponType == nil then error('[systems] Hit.setWeaponType: expected a weapon type', 2) end
    event:setWeaponType(weaponType)
    self.weaponType = weaponType
end

---Whether the current amount would kill the target (0.405 is Warcraft's death threshold). A heuristic for afterArmor:
---later listeners, mana shield and native effects can still change the outcome. False for a disposed target wrapper.
---@return boolean
function Hit:isLethal()
    if getmetatable(self) ~= Hit then error('[systems] Hit.isLethal: expected Hit', 2) end
    local target = self.target
    if target:isDisposed() then return false end
    return target:getLife() - self.amount <= 0.405
end

-- The pipeline

---@param value unknown
---@return boolean
local function whole(value) return math.type(value) ~= nil and math.floor(value) == value end

---Runs the hit's listeners of one list: those that existed when the hit began and are still registered (dispose()
---and a remove function clear the callback).
---@param system MoonwellSystems.DamageSystem
---@param list MoonwellSystems.DamageListener[]
---@param hit MoonwellSystems.Hit
local function dispatch(system, list, hit)
    local cutoff = hit.cutoff
    for index = 1, #list do
        local listener = list[index]
        local callback = listener.callback
        if callback and listener.id <= cutoff then
            Callback.call('Damage listener', system.onError, callback, hit)
        end
    end
end

---Starts the settle timer, once per engine turn: when it fires, hits still pending never got their DAMAGED event.
---@param system MoonwellSystems.DamageSystem
local function arm(system)
    if system.scheduled then return end
    system.scheduled = true
    system.timer:start(0, false, system.onSettle)
end

---@param system MoonwellSystems.DamageSystem
---@param event MoonwellWrappers.DamagingEvent
local function damaging(system, event)
    if not system.running then return end
    local target = event.target
    if not target then return end
    arm(system)
    local dealer, amount = event.source, event.amount
    ---@type MoonwellSystems.Hit
    local hit = setmetatable({
        source = dealer, dealer = dealer, target = target, amount = amount,
        isAttack = event.isAttack, attackType = event.attackType, damageType = event.damageType,
        weaponType = event.weaponType, phase = 'beforeArmor', initialAmount = amount,
        beforeArmorAmount = amount, cancelled = false, paired = true, system = system, cutoff = system.nextListener,
    }, Hit)
    local pending = system.pending
    if #pending >= system.maxPending then table.remove(pending, 1) end
    pending[#pending + 1] = hit
    local previous = system.current
    system.current = hit
    system.depth = system.depth + 1
    hit.event = event
    dispatch(system, system.before, hit)
    hit.event = nil
    system.depth = system.depth - 1
    system.current = previous
    hit.beforeArmorAmount = hit.amount
end

---@param system MoonwellSystems.DamageSystem
---@param event MoonwellWrappers.DamagedEvent
local function damaged(system, event)
    if not system.running then return end
    local target = event.target
    if not target then return end
    arm(system)
    local dealer, isAttack, amount = event.source, event.isAttack, event.amount
    local pending = system.pending
    ---@type MoonwellSystems.Hit?
    local hit
    -- The newest matching hit: native hits nest, and unrelated hits without a DAMAGED stay until the settle.
    for index = #pending, 1, -1 do
        local candidate = pending[index]
        if candidate.dealer == dealer and candidate.target == target and candidate.isAttack == isAttack then
            hit = candidate
            table.remove(pending, index)
            break
        end
    end
    if not hit then
        hit = setmetatable({
            source = dealer, dealer = dealer, target = target, isAttack = isAttack,
            initialAmount = amount, beforeArmorAmount = amount, cancelled = false, paired = false, system = system,
            cutoff = system.nextListener,
        }, Hit)
    end
    hit.phase = 'afterArmor'
    hit.armorAmount = amount
    hit.attackType, hit.damageType, hit.weaponType = event.attackType, event.damageType, event.weaponType
    if hit.cancelled then
        if amount ~= 0 then event:setAmount(0) end
        amount = 0
    end
    hit.amount = amount
    local previous = system.current
    system.current = hit
    system.depth = system.depth + 1
    hit.event = event
    dispatch(system, system.after, hit)
    hit.event = nil
    hit.phase = 'observe'
    dispatch(system, system.observers, hit)
    system.depth = system.depth - 1
    system.current = previous
end

---@param system MoonwellSystems.DamageSystem
local function settle(system)
    system.scheduled = false
    if not system.running then return end
    if #system.pending > 0 then system.pending = {} end
end

---Removes what start() added.
---@param system MoonwellSystems.DamageSystem
local function release(system)
    if system.damagingToken then Events.off(system.damagingToken); system.damagingToken = nil end
    if system.damagedToken then Events.off(system.damagedToken); system.damagedToken = nil end
    if system.timer then system.timer:destroy(); system.timer = nil end
    system.scheduled = false
end

-- DamageSystem

---Creates a stopped system: add listeners, then call start().
---@param options MoonwellSystems.DamageOptions?
---@return MoonwellSystems.DamageSystem
function DamageSystem.new(options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then error('[systems] DamageSystem.new: expected an options table', 2) end
    for _, name in ipairs({'sourceOf', 'onError'}) do
        if options[name] ~= nil and type(options[name]) ~= 'function' then
            error('[systems] DamageSystem.new: expected damage options: ' .. name, 2)
        end
    end
    local limits = {}
    for _, name in ipairs(LIMITS) do
        local value = options[name]
        if value == nil then value = DEFAULTS[name] end
        if not whole(value) or value < 1 then
            error('[systems] DamageSystem.new: expected damage options: ' .. name, 2)
        end
        limits[name] = value
    end
    ---@type MoonwellSystems.DamageSystem
    local system = setmetatable({
        before = {}, after = {}, observers = {}, pending = {}, sourceOf = options.sourceOf,
        onError = options.onError, maxQueue = limits.maxQueue, maxChain = limits.maxChain,
        maxPending = limits.maxPending, nextListener = 0, depth = 0, running = false, disposed = false,
        scheduled = false,
    }, DamageSystem)
    system.onSettle = function() settle(system) end
    return system
end

---Registers for Warcraft's damage events. Idempotent while running; raises after dispose().
function DamageSystem:start()
    local system = Check.receiver(self, DamageSystem, 'DamageSystem', 'DamageSystem.start')
    if system.disposed then error('[systems] DamageSystem.start: the system is disposed', 2) end
    if system.running then return end
    local ok, failure = pcall(function()
        system.timer = Timer.create()
        system.damagingToken = Events.onDamaging(function(event) damaging(system, event) end)
        system.damagedToken = Events.onDamaged(function(event) damaged(system, event) end)
    end)
    if not ok then
        release(system)
        -- The wrappers' message without its position, raised at this function's caller.
        local reason = tostring(failure):gsub('^.-:%d+: ', '')
        error('[systems] DamageSystem.start: ' .. reason, 2)
    end
    system.running = true
end

---@param system MoonwellSystems.DamageSystem
---@param key 'before'|'after'|'observers'
---@param callback fun(hit: MoonwellSystems.Hit): ...
---@param priority number?
---@param operation string
---@return fun() remove
local function listen(system, key, callback, priority, operation)
    if system.disposed then error('[systems] ' .. operation .. ': the system is disposed', 3) end
    Callback.check(callback, operation, 1)
    if priority == nil then priority = 0 end
    if not Check.finite(priority) then error('[systems] ' .. operation .. ': expected a finite priority', 3) end
    system.nextListener = system.nextListener + 1
    ---@type MoonwellSystems.DamageListener
    local listener = {id = system.nextListener, priority = priority, callback = callback}
    local list, copy, placed = system[key], {}, false
    for index = 1, #list do
        if not placed and list[index].priority > priority then
            copy[#copy + 1] = listener
            placed = true
        end
        copy[#copy + 1] = list[index]
    end
    if not placed then copy[#copy + 1] = listener end
    system[key] = copy
    return function()
        if not listener.callback then return end
        listener.callback = nil
        local kept = {}
        for _, other in ipairs(system[key]) do
            if other ~= listener then kept[#kept + 1] = other end
        end
        system[key] = kept
    end
end

---Adds a modifier that runs before armor. Lower `priority` runs first; equal priorities keep registration order. A
---listener added while a hit is in flight waits for the next hit.
---@param callback fun(hit: MoonwellSystems.Hit): ...
---@param priority number? Default 0.
---@return fun() remove Idempotent.
function DamageSystem:beforeArmor(callback, priority)
    local system = Check.receiver(self, DamageSystem, 'DamageSystem', 'DamageSystem.beforeArmor')
    return (listen(system, 'before', callback, priority, 'DamageSystem.beforeArmor'))
end

---Adds a modifier that runs after armor, the last point where the amount can change.
---@param callback fun(hit: MoonwellSystems.Hit): ...
---@param priority number? Default 0.
---@return fun() remove Idempotent.
function DamageSystem:afterArmor(callback, priority)
    local system = Check.receiver(self, DamageSystem, 'DamageSystem', 'DamageSystem.afterArmor')
    return (listen(system, 'after', callback, priority, 'DamageSystem.afterArmor'))
end

---Adds an observer that runs once the hit's final amount is known. Observers cannot change the hit.
---@param callback fun(hit: MoonwellSystems.Hit): ...
---@param priority number? Default 0.
---@return fun() remove Idempotent.
function DamageSystem:observe(callback, priority)
    local system = Check.receiver(self, DamageSystem, 'DamageSystem', 'DamageSystem.observe')
    return (listen(system, 'observers', callback, priority, 'DamageSystem.observe'))
end

---The hit whose listeners are running (the innermost one), or nil outside damage events.
---@return MoonwellSystems.Hit?
function DamageSystem:getCurrent()
    return Check.receiver(self, DamageSystem, 'DamageSystem', 'DamageSystem.getCurrent').current
end

---Stops listening and drops every listener and pending hit. Inside a listener, the hit's remaining listeners do
---not run. Idempotent.
function DamageSystem:dispose()
    local system = Check.receiver(self, DamageSystem, 'DamageSystem', 'DamageSystem.dispose')
    if system.disposed then return end
    system.disposed = true
    system.running = false
    system.pending = {}
    for _, key in ipairs(LISTS) do
        for _, listener in ipairs(system[key]) do listener.callback = nil end
        system[key] = {}
    end
    release(system)
end

return DamageSystem
