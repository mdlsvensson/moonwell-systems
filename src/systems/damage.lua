local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Fields = require('systems.internal.fields')
local Listeners = require('systems.internal.listeners')
local Events = require('wrappers.damage')
local Timer = require('wrappers.timer')
local Unit = require('wrappers.unit')

---A damage pipeline on wrappers.damage: listeners before armor, after armor and once the final amount is known; script
---damage that never nests inside another hit's listeners; and attribution of a hit to its real caster. Nothing is
---created before start().
---@class MoonwellSystems.DamageSystem
---@field package before MoonwellSystems.Listeners
---@field package after MoonwellSystems.Listeners
---@field package observers MoonwellSystems.Listeners
---@field package pending MoonwellSystems.Hit[] Hits whose DAMAGED has not come, oldest first.
---@field package sourceOf (fun(dealer: MoonwellWrappers.Unit): MoonwellWrappers.Unit?)?
---@field package onError (fun(message: string): ...)?
---@field package maxQueue integer
---@field package maxChain integer
---@field package maxPending integer
---@field package depth integer Hits whose listeners are running.
---@field package running boolean
---@field package disposed boolean
---@field package current MoonwellSystems.Hit?
---@field package timer MoonwellWrappers.Timer? The settle timer.
---@field package scheduled boolean Whether the settle timer is running.
---@field package onSettle fun(): ...
---@field package damagingToken MoonwellWrappers.DamageListener?
---@field package damagedToken MoonwellWrappers.DamageListener?
---@field package queue table<integer, MoonwellSystems.DamageDeal> Deals waiting for the current hit, from `first`.
---@field package first integer
---@field package last integer
---@field package chain integer Deals issued since the queue was last empty.
---@field package draining boolean
---@field package invocation MoonwellSystems.DamageDeal? The deal whose damageTarget call is running.
local DamageSystem = {}
DamageSystem.__index = DamageSystem

---@class MoonwellSystems.DamageOptions
---@field sourceOf (fun(dealer: MoonwellWrappers.Unit): MoonwellWrappers.Unit?)? Credits a hit to another Unit.
---@field onError (fun(message: string): ...)? Receives failures; default prints them.
---@field maxQueue integer? Most deals that may wait. Default 128.
---@field maxChain integer? Most deals in one chain. Default 64.
---@field maxPending integer? Most hits awaiting their DAMAGED event. Default 64.

---@class MoonwellSystems.DamageRequest
---@field source MoonwellWrappers.Unit The Unit that deals the damage.
---@field target MoonwellWrappers.Unit
---@field amount number Finite and not negative.
---@field attack boolean? Default false.
---@field ranged boolean? Default false.
---@field attackType attacktype? Default ATTACK_TYPE_NORMAL.
---@field damageType damagetype? Default DAMAGE_TYPE_NORMAL.
---@field weaponType weapontype? Default WEAPON_TYPE_WHOKNOWS.
---@field metadata any The resulting hit's metadata.

---A queued copy of a request.
---@class MoonwellSystems.DamageDeal
---@field source MoonwellWrappers.Unit
---@field target MoonwellWrappers.Unit
---@field amount number
---@field attack boolean
---@field ranged boolean
---@field attackType attacktype
---@field damageType damagetype
---@field weaponType weapontype
---@field metadata any
---@field claimed boolean Whether a hit has taken the metadata.
---@field hit MoonwellSystems.Hit? The hit that took it.

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

local function liveUnit(value) return Check.liveUnit(value, Unit) end

local OPTIONS = {
    sourceOf = {'function'},
    onError = {'function'},
    maxQueue = {Fields.integer(1), default = 128},
    maxChain = {Fields.integer(1), default = 64},
    maxPending = {Fields.integer(1), default = 64},
}

local DEAL = {
    source = {Fields.test(liveUnit, 'a live Unit'), required = true},
    target = {Fields.test(liveUnit, 'a live Unit'), required = true},
    amount = {'nonNegative', required = true},
    attack = {'boolean', default = false},
    ranged = {'boolean', default = false},
    attackType = {'any'},
    damageType = {'any'},
    weaponType = {'any'},
    metadata = {'any'},
}

---@param system MoonwellSystems.DamageSystem
---@return integer
local function queued(system) return system.last - system.first + 1 end

---@param system MoonwellSystems.DamageSystem
local function emptyQueue(system) system.queue, system.first, system.last = {}, 1, 0 end

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

---Runs the hit's listeners of one list: those that existed when the hit began and are still registered (dispose()
---and a remove function clear the callback).
---@param system MoonwellSystems.DamageSystem
---@param list MoonwellSystems.Listeners
---@param hit MoonwellSystems.Hit
local function dispatch(system, list, hit)
    local cutoff, cells = hit.cutoff, list:current()
    for index = 1, #cells do
        local cell = cells[index]
        local callback = cell.callback
        if callback and cell.id <= cutoff then
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

---The Unit a hit is credited to: what sourceOf answers, or the dealer.
---@param system MoonwellSystems.DamageSystem
---@param dealer MoonwellWrappers.Unit?
---@return MoonwellWrappers.Unit?
local function resolve(system, dealer)
    local sourceOf = system.sourceOf
    if not sourceOf or not dealer then return dealer end
    local ok, result = pcall(sourceOf, dealer)
    if not ok then
        Callback.report('Damage sourceOf', system.onError, result)
        return dealer
    end
    if result == nil then return dealer end
    if getmetatable(result) ~= Unit then
        Callback.report('Damage sourceOf', system.onError, 'expected a Unit or nil')
        return dealer
    end
    return result
end

---@param pending MoonwellSystems.Hit[]
---@param hit MoonwellSystems.Hit
local function forget(pending, hit)
    for index = #pending, 1, -1 do
        if pending[index] == hit then table.remove(pending, index); return end
    end
end

---Deals queued requests one at a time, while no hit is being handled and none is pending.
---@param system MoonwellSystems.DamageSystem
local function drain(system)
    if not system.running or system.draining or system.depth > 0 then return end
    system.draining = true
    while system.running and queued(system) > 0 and #system.pending == 0 do
        if system.chain >= system.maxChain then
            local dropped = queued(system)
            emptyQueue(system)
            system.chain = 0
            Callback.report('Damage chain', system.onError,
                'more than ' .. system.maxChain .. ' deals in one chain; ' .. dropped .. ' queued deals dropped')
            break
        end
        system.chain = system.chain + 1
        local deal = system.queue[system.first]
        system.queue[system.first] = nil
        system.first = system.first + 1
        local source, target = deal.source, deal.target
        if not source:isDisposed() and not target:isDisposed() then
            local previous = system.invocation
            system.invocation = deal
            source:damageTarget(target, deal.amount, deal.attack, deal.ranged, deal.attackType, deal.damageType,
                deal.weaponType)
            system.invocation = previous
            -- A hit of this deal that is still pending got no DAMAGED: drop it, so nothing later pairs with it.
            if deal.hit then forget(system.pending, deal.hit) end
        end
    end
    system.draining = false
    -- Every slot that was read is nil again: reset the indexes and keep the table. This runs after every hit.
    if queued(system) == 0 then system.first, system.last, system.chain = 1, 0, 0 end
end

---@param system MoonwellSystems.DamageSystem
---@param event MoonwellWrappers.DamagingEvent
local function damaging(system, event)
    if not system.running then return end
    local target = event.target
    if not target then return end
    arm(system)
    local dealer = event.source
    local metadata
    local deal = system.invocation
    if deal and not deal.claimed and deal.source == dealer and deal.target == target then
        deal.claimed = true
        metadata = deal.metadata
    else
        deal = nil
    end
    local amount = event.amount
    ---@type MoonwellSystems.Hit
    local hit = setmetatable({
        source = resolve(system, dealer), dealer = dealer, target = target, amount = amount,
        isAttack = event.isAttack, attackType = event.attackType, damageType = event.damageType,
        weaponType = event.weaponType, metadata = metadata, phase = 'beforeArmor', initialAmount = amount,
        beforeArmorAmount = amount, cancelled = false, paired = true, system = system,
        cutoff = system.before:getLastId(),
    }, Hit)
    local pending = system.pending
    if #pending >= system.maxPending then table.remove(pending, 1) end
    pending[#pending + 1] = hit
    if deal then deal.hit = hit end
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
            source = resolve(system, dealer), dealer = dealer, target = target, isAttack = isAttack,
            initialAmount = amount, beforeArmorAmount = amount, cancelled = false, paired = false, system = system,
            cutoff = system.before:getLastId(),
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
    drain(system)
end

---@param system MoonwellSystems.DamageSystem
local function settle(system)
    system.scheduled = false
    if not system.running then return end
    if #system.pending > 0 then system.pending = {} end
    drain(system)
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
    local read = Fields.options(options, OPTIONS, 'DamageSystem.new')
    local ids = {last = 0}
    ---@type MoonwellSystems.DamageSystem
    local system = setmetatable({
        before = Listeners.new(ids), after = Listeners.new(ids), observers = Listeners.new(ids), pending = {},
        sourceOf = read.sourceOf, onError = read.onError, maxQueue = read.maxQueue, maxChain = read.maxChain,
        maxPending = read.maxPending, depth = 0, running = false, disposed = false, scheduled = false, queue = {},
        first = 1, last = 0, chain = 0, draining = false,
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
        local reason = Callback.reason(failure)
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
    local remove = system[key]:add(callback, priority)
    return remove
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

---Deals damage through the pipeline. Outside damage events it runs at once; inside a listener it is queued and runs,
---first in first out, after the current hit. The hit it causes carries `request.metadata`.
---@param request MoonwellSystems.DamageRequest
function DamageSystem:deal(request)
    local system = Check.receiver(self, DamageSystem, 'DamageSystem', 'DamageSystem.deal')
    if system.disposed then error('[systems] DamageSystem.deal: the system is disposed', 2) end
    if not system.running then error('[systems] DamageSystem.deal: the system is not started', 2) end
    local read = Fields.request(request, DEAL, 'DamageSystem.deal', 'a damage request table')
    if queued(system) >= system.maxQueue then
        error('[systems] DamageSystem.deal: the queue is full (' .. system.maxQueue .. ' deals)', 2)
    end
    system.last = system.last + 1
    system.queue[system.last] = {
        source = read.source, target = read.target, amount = read.amount, attack = read.attack,
        ranged = read.ranged, attackType = read.attackType or ATTACK_TYPE_NORMAL,
        damageType = read.damageType or DAMAGE_TYPE_NORMAL, weaponType = read.weaponType or WEAPON_TYPE_WHOKNOWS,
        metadata = read.metadata, claimed = false,
    }
    drain(system)
end

---The hit whose listeners are running (the innermost one), or nil outside damage events.
---@return MoonwellSystems.Hit?
function DamageSystem:getCurrent()
    return Check.receiver(self, DamageSystem, 'DamageSystem', 'DamageSystem.getCurrent').current
end

---Stops listening and drops every listener, queued deal and pending hit. Inside a listener, the hit's remaining
---listeners do not run. Idempotent.
function DamageSystem:dispose()
    local system = Check.receiver(self, DamageSystem, 'DamageSystem', 'DamageSystem.dispose')
    if system.disposed then return end
    system.disposed = true
    system.running = false
    emptyQueue(system)
    system.pending, system.chain = {}, 0
    system.before:clear(); system.after:clear(); system.observers:clear()
    release(system)
end

return DamageSystem
