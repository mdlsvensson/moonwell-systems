bj_MAX_PLAYER_SLOTS = 28
EVENT_PLAYER_UNIT_DAMAGING, EVENT_PLAYER_UNIT_DAMAGED = {}, {}
ATTACK_TYPE_NORMAL, ATTACK_TYPE_CHAOS = {}, {}
DAMAGE_TYPE_NORMAL, DAMAGE_TYPE_UNIVERSAL = {}, {}
WEAPON_TYPE_WHOKNOWS, WEAPON_TYPE_METAL = {}, {}
local actions, timers, writes, dealt = {}, {}, {}, {}
local raw -- the event the game is delivering
local omitPost, onDeal, rejected = false, nil, false

-- Delivers one event: runs the action of every enabled trigger registered for it. Returns `data`, whose fields the
-- setter doubles change.
local function fire(event, data)
    local saved = raw
    raw = data
    for _, action in ipairs(actions) do
        if action.trigger.enabled and action.trigger.events[1] == event then action.callback() end
    end
    raw = saved
    return data
end

native('Player', function(index) return {index = index} end)
native('CreateTrigger', function() return {events = {}, enabled = true} end)
native('TriggerRegisterPlayerUnitEvent', function(trigger, _, event) trigger.events[#trigger.events + 1] = event end)
native('TriggerAddAction', function(trigger, callback)
    actions[#actions + 1] = {trigger = trigger, callback = callback}
    return {}
end)
native('EnableTrigger', function(trigger) trigger.enabled = true end)
native('DisableTrigger', function(trigger) trigger.enabled = false end)
native('CreateTimer', function()
    local timer = {}
    timers[#timers + 1] = timer
    return timer
end)
native('TimerStart', function(timer, _, _, callback) timer.callback = callback end)
native('PauseTimer', function(timer) timer.callback = nil end)
native('DestroyTimer', function() end)
native('GetEventDamageSource', function() return raw.source end)
native('BlzGetEventDamageTarget', function() return raw.target end)
native('GetEventDamage', function() return raw.amount end)
native('BlzGetEventIsAttack', function() return raw.isAttack end)
native('BlzGetEventAttackType', function() return raw.attackType end)
native('BlzGetEventDamageType', function() return raw.damageType end)
native('BlzGetEventWeaponType', function() return raw.weaponType end)
native('BlzSetEventDamage', function(amount) raw.amount = amount; writes[#writes + 1] = amount end)
native('BlzSetEventAttackType', function(value) raw.attackType = value end)
native('BlzSetEventDamageType', function(value) raw.damageType = value end)
native('BlzSetEventWeaponType', function(value) raw.weaponType = value end)
native('GetWidgetLife', function(handle) return handle.life end)
native('RemoveUnit', function() end)
-- The game's side of a script hit: DAMAGING, then DAMAGED with half the amount (the armor).
native('UnitDamageTarget', function(source, target, amount, _, _, attackType, damageType, weaponType)
    if rejected then return false end
    dealt[#dealt + 1] = target.name
    local event = fire(EVENT_PLAYER_UNIT_DAMAGING, {source = source, target = target, amount = amount,
        isAttack = false, attackType = attackType, damageType = damageType, weaponType = weaponType})
    if onDeal then onDeal() end
    if not omitPost then
        fire(EVENT_PLAYER_UNIT_DAMAGED, {source = source, target = target, amount = event.amount / 2,
            isAttack = false, attackType = event.attackType, damageType = event.damageType,
            weaponType = event.weaponType})
    end
    return true
end)
local DamageSystem = require('systems.damage')
local Unit = require('wrappers.unit')
eq(totalCalls(), 0)

-- Units are named: one raw handle per name.
local handles = {}
local function handle(name)
    handles[name] = handles[name] or {name = name}
    return handles[name]
end
local function unit(name) return Unit.fromHandle(handle(name)) end
local function nameOf(wrapper) return wrapper and wrapper.handle.name or 'nobody' end
local function join(list) return table.concat(list, ',') end

local function data(target, amount, source)
    return {source = handle(source or 's'), target = handle(target), amount = amount, isAttack = false,
        attackType = ATTACK_TYPE_NORMAL, damageType = DAMAGE_TYPE_NORMAL, weaponType = WEAPON_TYPE_WHOKNOWS}
end
-- A native hit's two events, from unit 's' unless `source` names another.
local function pre(target, amount, source)
    return fire(EVENT_PLAYER_UNIT_DAMAGING, data(target, amount or 10, source))
end
local function post(target, amount, source)
    return fire(EVENT_PLAYER_UNIT_DAMAGED, data(target, amount or 5, source))
end
-- The end of the engine turn: runs every started timer.
local function settle()
    for _, timer in ipairs(timers) do
        local callback = timer.callback
        if callback then
            timer.callback = nil
            callback()
        end
    end
end

-- Every test starts with new(): it disposes the previous test's system and resets the doubles.
local live
local function new(options)
    if live then live:dispose() end
    writes, dealt, omitPost, onDeal, rejected = {}, {}, false, nil, false
    live = DamageSystem.new(options)
    return live
end

test('a failed start registers nothing and can be retried', function()
    local system = new()
    local seen, created = 0, 0
    system:observe(function() seen = seen + 1 end)
    native('CreateTrigger', function()
        created = created + 1
        if created == 2 then return nil end
        return {events = {}, enabled = true}
    end)
    failsAt(function() system:start() end, 'DamageSystem.start: [wrappers] Damage.onDamaged: native returned nil')
    eq(callCount('DestroyTimer'), 1); eq(callCount('DisableTrigger'), 1)
    pre('t'); post('t'); eq(seen, 0)
    system:start()
    eq(callCount('CreateTimer'), 2); eq(callCount('EnableTrigger'), 1)
    pre('t'); post('t'); eq(seen, 1)
end)

test('nothing is created before start; start is idempotent; dispose releases and is final', function()
    local system = new()
    resetCalls()
    local seen = 0
    system:observe(function() seen = seen + 1 end)
    eq(totalCalls(), 0)
    pre('t'); post('t'); eq(seen, 0)
    system:start(); system:start()
    eq(callCount('CreateTimer'), 1)
    pre('t'); post('t'); eq(seen, 1)
    system:dispose(); system:dispose()
    eq(callCount('DestroyTimer'), 1)
    pre('t'); post('t'); eq(seen, 1)
    failsAt(function() system:start() end, 'DamageSystem.start: the system is disposed')
    failsAt(function() system:observe(function() end) end, 'DamageSystem.observe: the system is disposed')
    eq(#PRINTED, 0)
end)

test('phases run in priority order and the hit records each amount', function()
    local system = new()
    local order, observed = {}, nil
    system:beforeArmor(function(hit) order[#order + 1] = 'late:' .. hit.phase end, 10)
    system:beforeArmor(function(hit) order[#order + 1] = 'early:' .. hit.amount end, -1)
    system:beforeArmor(function() order[#order + 1] = 'default' end)
    system:afterArmor(function(hit) order[#order + 1] = 'after:' .. hit.phase .. ':' .. hit.amount end)
    system:observe(function(hit) order[#order + 1] = 'observe:' .. hit.phase; observed = hit end)
    system:start()
    pre('t', 10); eq(system:getCurrent(), nil)
    post('t', 4)
    eq(join(order), 'early:10,default,late:beforeArmor,after:afterArmor:4,observe:observe')
    eq(nameOf(observed.source), 's'); eq(nameOf(observed.dealer), 's'); eq(nameOf(observed.target), 't')
    eq(observed.initialAmount, 10); eq(observed.beforeArmorAmount, 10); eq(observed.armorAmount, 4)
    eq(observed.amount, 4); eq(observed.isAttack, false); eq(observed.metadata, nil)
    eq(observed.cancelled, false); eq(observed.paired, true)
    eq(observed.attackType, ATTACK_TYPE_NORMAL); eq(observed.damageType, DAMAGE_TYPE_NORMAL)
    eq(observed.weaponType, WEAPON_TYPE_WHOKNOWS)
    eq(system:getCurrent(), nil); eq(#PRINTED, 0)
end)

test('a removed listener stops at once and an added one waits for the next hit', function()
    local system = new()
    local seen, remove = {}, nil
    system:beforeArmor(function()
        seen[#seen + 1] = 'first'
        remove()
        system:beforeArmor(function() seen[#seen + 1] = 'added' end)
    end)
    remove = system:beforeArmor(function() seen[#seen + 1] = 'removed' end)
    system:start()
    pre('a'); post('a'); pre('b')
    eq(join(seen), 'first,first,added'); eq(#PRINTED, 0)
end)

test('an observer added before armor waits for the next hit', function()
    local system = new()
    local seen = {}
    system:beforeArmor(function()
        system:observe(function(hit) seen[#seen + 1] = nameOf(hit.target) end)
    end)
    system:start()
    pre('first'); post('first'); pre('second'); post('second')
    eq(join(seen), 'second')
end)

test('a nested native hit restores the current hit', function()
    local system = new()
    local seen = {}
    system:beforeArmor(function(hit)
        if nameOf(hit.target) == 'outer' then
            pre('inner'); post('inner')
            eq(system:getCurrent(), hit)
            seen[#seen + 1] = 'outer resumed'
        else
            seen[#seen + 1] = 'inner current ' .. tostring(system:getCurrent() == hit)
        end
    end)
    system:observe(function(hit) seen[#seen + 1] = 'observed ' .. nameOf(hit.target) end)
    system:start()
    pre('outer'); post('outer')
    eq(join(seen), 'inner current true,observed inner,outer resumed,observed outer')
    eq(system:getCurrent(), nil); eq(#PRINTED, 0)
end)

test('a missing DAMAGED expires at the settle without taking another hit', function()
    local system = new()
    local seen, last = {}, nil
    system:observe(function(hit)
        seen[#seen + 1] = nameOf(hit.target) .. ':' .. tostring(hit.paired)
        last = hit
    end)
    system:start()
    pre('outer'); pre('missing'); post('outer')
    settle()
    post('missing', 3)
    eq(join(seen), 'outer:true,missing:false')
    eq(last.initialAmount, 3); eq(last.beforeArmorAmount, 3); eq(last.armorAmount, 3); eq(last.amount, 3)
    eq(#PRINTED, 0)
end)

test('the pending limit drops the oldest hit silently', function()
    local system = new({maxPending = 2})
    local seen = {}
    system:observe(function(hit) seen[#seen + 1] = nameOf(hit.target) .. ':' .. tostring(hit.paired) end)
    system:start()
    pre('a'); pre('b'); pre('c')
    post('c'); post('b'); post('a')
    eq(join(seen), 'c:true,b:true,a:false'); eq(#PRINTED, 0)
end)

test('a hit with no source runs the pipeline; one with no target is ignored', function()
    local system = new()
    local seen, count = nil, 0
    system:beforeArmor(function(hit) count = count + 1; hit:setAmount(1) end)
    system:observe(function(hit) seen = hit end)
    system:start()
    local event = {target = handle('t'), amount = 10, isAttack = false, attackType = ATTACK_TYPE_NORMAL,
        damageType = DAMAGE_TYPE_NORMAL, weaponType = WEAPON_TYPE_WHOKNOWS}
    fire(EVENT_PLAYER_UNIT_DAMAGING, event)
    eq(event.amount, 1)
    event.amount = 0.5
    fire(EVENT_PLAYER_UNIT_DAMAGED, event)
    eq(seen.source, nil); eq(seen.dealer, nil); eq(seen.paired, true); eq(seen.amount, 0.5)
    fire(EVENT_PLAYER_UNIT_DAMAGING, {source = handle('s'), amount = 10})
    fire(EVENT_PLAYER_UNIT_DAMAGED, {source = handle('s'), amount = 10})
    eq(count, 1); eq(#PRINTED, 0)
end)

test('a failing listener is reported and the others still run', function()
    local messages = {}
    local system = new({onError = function(message) messages[#messages + 1] = message end})
    local seen = {}
    system:beforeArmor(function(hit)
        if nameOf(hit.target) == 'bad' then error('bad listener', 0) end
    end)
    system:beforeArmor(function(hit) seen[#seen + 1] = nameOf(hit.target) end)
    system:start()
    pre('bad'); post('bad'); pre('good'); post('good')
    eq(join(seen), 'bad,good'); eq(#messages, 1); eq(messages[1], 'bad listener')
    eq(system:getCurrent(), nil); eq(#PRINTED, 0)
    system = new()
    system:observe(function() error('printed listener', 0) end)
    system:start()
    pre('t'); post('t')
    eq(#PRINTED, 1); eq(PRINTED[1], '[systems] Damage listener failed: printed listener')
end)

test('dispose inside a listener stops the remaining listeners of the hit', function()
    local system = new()
    local called = false
    system:beforeArmor(function() system:dispose() end)
    system:beforeArmor(function() called = true end)
    system:afterArmor(function() called = true end)
    system:start()
    resetCalls()
    pre('t'); post('t')
    eq(called, false); eq(callCount('DestroyTimer'), 1); eq(system:getCurrent(), nil); eq(#PRINTED, 0)
end)

test('setAmount and cancel change the hit and the game event', function()
    local system = new()
    local amounts = {}
    system:beforeArmor(function(hit)
        hit:setAmount(hit.amount * 2)
        if nameOf(hit.target) == 'cancel' then
            hit:cancel(); hit:cancel()
            hit:setAmount(50)
        end
    end)
    system:afterArmor(function(hit)
        if nameOf(hit.target) == 'cancel' then hit:setAmount(99) else hit:setAmount(math.max(hit.amount - 1, 0)) end
    end)
    system:observe(function(hit)
        amounts[#amounts + 1] = table.concat({hit.initialAmount, hit.beforeArmorAmount, hit.armorAmount, hit.amount,
            tostring(hit.cancelled)}, '/')
    end)
    system:start()
    eq(pre('t', 10).amount, 20); eq(post('t', 8).amount, 7)
    eq(pre('cancel', 10).amount, 0)
    eq(post('cancel', 3).amount, 0) -- the game still reported 3: the system zeroes a cancelled hit again
    pre('zero', 0); post('zero', 0)
    eq(join(amounts), '10/20/8/7/false,10/0/3/0/true,0/0/0/0/false')
    eq(join(writes), '20,7,20,0,0,0,0'); eq(#PRINTED, 0)
end)

test('type setters reach the game before armor; after armor the hit shows the game\'s types', function()
    local system = new()
    local seen
    system:beforeArmor(function(hit)
        hit:setAttackType(ATTACK_TYPE_CHAOS)
        hit:setDamageType(DAMAGE_TYPE_UNIVERSAL)
        hit:setWeaponType(WEAPON_TYPE_METAL)
        seen = hit
    end)
    system:start()
    local event = pre('t')
    eq(event.attackType, ATTACK_TYPE_CHAOS); eq(event.damageType, DAMAGE_TYPE_UNIVERSAL)
    eq(event.weaponType, WEAPON_TYPE_METAL)
    eq(seen.attackType, ATTACK_TYPE_CHAOS); eq(seen.damageType, DAMAGE_TYPE_UNIVERSAL)
    eq(seen.weaponType, WEAPON_TYPE_METAL)
    post('t')
    eq(seen.attackType, ATTACK_TYPE_NORMAL); eq(#PRINTED, 0)
end)

test('setters work only in their phase and only on the hit being handled', function()
    local system = new()
    local outer, kept
    system:beforeArmor(function(hit)
        if nameOf(hit.target) == 'outer' then
            outer = hit
            pre('inner'); post('inner')
            hit:setAmount(7)
        else
            failsAt(function() outer:setAmount(1) end, 'Hit.setAmount: the hit is not being handled')
            failsAt(function() outer:cancel() end, 'Hit.cancel: the hit is not being handled')
        end
    end)
    system:afterArmor(function(hit)
        failsAt(function() hit:setAttackType(ATTACK_TYPE_CHAOS) end,
            'Hit.setAttackType: types can change only before armor')
        failsAt(function() hit:setDamageType(DAMAGE_TYPE_UNIVERSAL) end,
            'Hit.setDamageType: types can change only before armor')
        failsAt(function() hit:setWeaponType(WEAPON_TYPE_METAL) end,
            'Hit.setWeaponType: types can change only before armor')
    end)
    system:observe(function(hit)
        kept = hit
        failsAt(function() hit:setAmount(1) end, 'Hit.setAmount: observers cannot change a hit')
        failsAt(function() hit:cancel() end, 'Hit.cancel: observers cannot change a hit')
        failsAt(function() hit:setDamageType(DAMAGE_TYPE_UNIVERSAL) end,
            'Hit.setDamageType: observers cannot change a hit')
    end)
    system:start()
    eq(pre('outer').amount, 7)
    failsAt(function() outer:setAmount(1) end, 'Hit.setAmount: the hit is not being handled')
    post('outer')
    failsAt(function() kept:setAmount(1) end, 'Hit.setAmount: the hit is not being handled')
    eq(join(writes), '7'); eq(#PRINTED, 0)
end)

test('setters and isLethal check their arguments at the caller', function()
    local system = new()
    local ran = false
    system:beforeArmor(function(hit)
        for _, bad in ipairs({'1', -1, 0 / 0, math.huge}) do
            failsAt(function() hit:setAmount(bad) end, 'Hit.setAmount: expected a finite non-negative amount')
        end
        failsAt(function() hit:setAttackType(nil) end, 'Hit.setAttackType: expected an attack type')
        failsAt(function() hit:setDamageType(nil) end, 'Hit.setDamageType: expected a damage type')
        failsAt(function() hit:setWeaponType(nil) end, 'Hit.setWeaponType: expected a weapon type')
        failsAt(function() hit.setAmount({}, 1) end, 'Hit.setAmount: expected Hit')
        failsAt(function() hit.isLethal({}) end, 'Hit.isLethal: expected Hit')
        ran = true
    end)
    system:start()
    pre('t')
    eq(ran, true); eq(#writes, 0); eq(#PRINTED, 0)
end)

test('isLethal compares the amount with the target\'s life', function()
    local system = new()
    local answers = {}
    system:afterArmor(function(hit)
        answers[#answers + 1] = tostring(hit:isLethal())
        if nameOf(hit.target) == 'gone' then
            hit.target:remove()
            answers[#answers + 1] = tostring(hit:isLethal())
        end
    end)
    system:start()
    handle('t').life = 10
    pre('t'); post('t', 9)
    pre('t'); post('t', 9.6)
    handle('gone').life = 1
    pre('gone'); post('gone', 5)
    eq(join(answers), 'false,true,true,false'); eq(#PRINTED, 0)
end)

test('new and the listener functions check their arguments at the caller', function()
    failsAt(function() DamageSystem.new(5) end, 'DamageSystem.new: expected an options table')
    local cases = {{'sourceOf', 5}, {'onError', 'x'}, {'maxQueue', 0}, {'maxChain', 1.5}, {'maxPending', '2'},
        -- A cap is a finite whole number: no "no cap".
        {'maxQueue', math.huge}, {'maxChain', math.huge}, {'maxPending', math.huge}}
    for _, case in ipairs(cases) do
        failsAt(function() DamageSystem.new({[case[1]] = case[2]}) end,
            "DamageSystem.new: '" .. case[1] .. "'")
    end
    local system = new({maxQueue = 1, maxChain = 1, maxPending = 1})
    failsAt(function() system:beforeArmor(5) end, 'DamageSystem.beforeArmor: expected a callback function')
    failsAt(function() system:afterArmor(nil) end, 'DamageSystem.afterArmor: expected a callback function')
    failsAt(function() system:observe(function() end, 'high') end, 'DamageSystem.observe: expected a finite priority')
    failsAt(function() system:beforeArmor(function() end, 0 / 0) end,
        'DamageSystem.beforeArmor: expected a finite priority')
    failsAt(function() DamageSystem.getCurrent({}) end, 'DamageSystem.getCurrent: expected DamageSystem')
    failsAt(function() DamageSystem.dispose({}) end, 'DamageSystem.dispose: expected DamageSystem')
end)

-- Script damage and attribution.

local function deal(system, target, amount, metadata, source)
    system:deal({source = unit(source or 's'), target = unit(target), amount = amount, metadata = metadata})
end

test('deal needs a started system, runs at once and carries its metadata', function()
    local system = new()
    local seen = {}
    system:beforeArmor(function(hit) hit:setAmount(hit.amount + 2) end)
    system:observe(function(hit)
        seen[#seen + 1] = tostring(hit.metadata) .. ':' .. hit.amount .. ':' .. tostring(hit.isAttack)
    end)
    failsAt(function() system:deal({source = unit('s'), target = unit('t'), amount = 10}) end,
        'DamageSystem.deal: the system is not started')
    system:start()
    resetCalls()
    deal(system, 't', 10, 'spell')
    eq(join(seen), 'spell:6.0:false')
    expectCall('UnitDamageTarget', handle('s'), handle('t'), 10, false, false, ATTACK_TYPE_NORMAL, DAMAGE_TYPE_NORMAL,
        WEAPON_TYPE_WHOKNOWS)
    system:deal({source = unit('s'), target = unit('t'), amount = 0, attack = true, ranged = true,
        attackType = ATTACK_TYPE_CHAOS, damageType = DAMAGE_TYPE_UNIVERSAL, weaponType = WEAPON_TYPE_METAL})
    expectCall('UnitDamageTarget', handle('s'), handle('t'), 0, true, true, ATTACK_TYPE_CHAOS, DAMAGE_TYPE_UNIVERSAL,
        WEAPON_TYPE_METAL)
    eq(system:getCurrent(), nil); eq(#PRINTED, 0)
end)

test('a nested native hit never inherits metadata, and the same two units claim it once', function()
    local system = new()
    local seen, nested = {}, false
    system:beforeArmor(function(hit)
        seen[#seen + 1] = 'pre ' .. nameOf(hit.target) .. ' ' .. tostring(hit.metadata)
        if nameOf(hit.target) == 'outer' and not nested then
            nested = true
            pre('inner'); post('inner')
            pre('outer'); post('outer')
        end
    end)
    system:observe(function(hit) seen[#seen + 1] = 'post ' .. nameOf(hit.target) .. ' ' .. tostring(hit.metadata) end)
    system:start()
    deal(system, 'outer', 10, 'spell')
    pre('attack'); post('attack')
    eq(join(seen), 'pre outer spell,pre inner nil,post inner nil,pre outer nil,post outer nil,post outer spell,'
        .. 'pre attack nil,post attack nil')
    eq(#PRINTED, 0)
end)

test('deals from listeners run first in first out after the hit, and the chain limit recovers', function()
    local messages = {}
    local system = new({maxChain = 3, onError = function(message) messages[#messages + 1] = message end})
    local order = {}
    system:beforeArmor(function(hit)
        local target = nameOf(hit.target)
        order[#order + 1] = 'pre:' .. target
        deal(system, target .. '+', 1)
        if target == 'a' then deal(system, 'b', 1) end
    end)
    system:observe(function(hit) order[#order + 1] = 'post:' .. nameOf(hit.target) end)
    system:start()
    deal(system, 'a', 10)
    eq(join(dealt), 'a,a+,b')
    eq(join(order), 'pre:a,post:a,pre:a+,post:a+,pre:b,post:b')
    eq(#messages, 1); eq(messages[1], 'more than 3 deals in one chain; 2 queued deals dropped')
    eq(system:getCurrent(), nil)
    deal(system, 'c', 1)
    eq(join(dealt), 'a,a+,b,c,c+,c++')
    eq(#messages, 2); eq(messages[2], 'more than 3 deals in one chain; 1 queued deals dropped')
    eq(#PRINTED, 0)
end)

test('a deal from an afterArmor listener waits until the observers have run', function()
    local system = new()
    local order = {}
    system:afterArmor(function(hit)
        if nameOf(hit.target) == 'a' then deal(system, 'b', 1) end
    end)
    system:observe(function(hit) order[#order + 1] = nameOf(hit.target) end)
    system:start()
    pre('a'); post('a')
    eq(join(order), 'a,b'); eq(system:getCurrent(), nil); eq(#PRINTED, 0)
end)

test('separate deals do not share a chain', function()
    local system = new({maxChain = 2})
    system:start()
    for _ = 1, 5 do deal(system, 't', 1) end
    eq(#dealt, 5); eq(#PRINTED, 0)
end)

test('a full queue raises at the listener and keeps the accepted deals', function()
    local messages = {}
    local system = new({maxQueue = 2, onError = function(message) messages[#messages + 1] = message end})
    system:beforeArmor(function(hit)
        if nameOf(hit.target) == 'a' then
            for _, target in ipairs({'b', 'c', 'd'}) do deal(system, target, 1) end
        end
    end)
    system:start()
    deal(system, 'a', 1)
    eq(join(dealt), 'a,b,c'); eq(#messages, 1)
    assert(messages[1]:find('DamageSystem.deal: the queue is full (2 deals)', 1, true), messages[1])
    assert(messages[1]:find('^tests/damage%.lua:%d+: '), messages[1])
end)

test('the chain budget survives a settle', function()
    local messages = {}
    local system = new({maxChain = 2, onError = function(message) messages[#messages + 1] = message end})
    system:beforeArmor(function(hit)
        if nameOf(hit.target) == 'spell' then deal(system, 'spell', 1) end
    end)
    onDeal = function() pre('missing') end
    system:start()
    deal(system, 'spell', 1)
    eq(join(dealt), 'spell')
    settle(); settle(); settle()
    eq(join(dealt), 'spell,spell')
    eq(#messages, 1); eq(messages[1], 'more than 2 deals in one chain; 1 queued deals dropped')
end)

test('a deal with no DAMAGED releases its metadata before the next hit', function()
    local system = new()
    local seen = {}
    system:beforeArmor(function(hit) seen[#seen + 1] = tostring(hit.metadata) end)
    system:observe(function(hit)
        seen[#seen + 1] = 'observed ' .. tostring(hit.metadata) .. ' ' .. tostring(hit.paired)
    end)
    system:start()
    omitPost = true
    deal(system, 'same', 0, 'cancelled-spell')
    post('same') -- must not pair with the deal's hit
    pre('same'); post('same')
    eq(join(seen), 'cancelled-spell,observed nil false,nil,observed nil true'); eq(#PRINTED, 0)
end)

test('a queued deal with a disposed wrapper is skipped, and a rejected native call is silent', function()
    local system = new()
    local seen = 0
    system:beforeArmor(function(hit)
        if nameOf(hit.target) == 'a' then
            deal(system, 'doomed', 1); deal(system, 'b', 1)
            unit('doomed'):remove()
        end
    end)
    system:observe(function() seen = seen + 1 end)
    system:start()
    deal(system, 'a', 1)
    eq(join(dealt), 'a,b'); eq(seen, 2)
    rejected = true
    resetCalls()
    deal(system, 't', 1); deal(system, 't', 1)
    eq(callCount('UnitDamageTarget'), 2); eq(seen, 2); eq(#PRINTED, 0)
end)

test('deal copies the request', function()
    local system = new()
    local request = {source = unit('s'), target = unit('later'), amount = 3}
    system:beforeArmor(function(hit)
        if nameOf(hit.target) == 'a' then
            system:deal(request)
            request.target, request.amount = unit('changed'), 99
        end
    end)
    system:start()
    deal(system, 'a', 1)
    eq(join(dealt), 'a,later')
    expectCall('UnitDamageTarget', handle('s'), handle('later'), 3, false, false, ATTACK_TYPE_NORMAL,
        DAMAGE_TYPE_NORMAL, WEAPON_TYPE_WHOKNOWS)
    eq(#PRINTED, 0)
end)

test('dispose inside a listener drops the queued deals', function()
    local system = new()
    system:beforeArmor(function()
        deal(system, 'never', 1)
        system:dispose()
    end)
    system:start()
    deal(system, 'outer', 1)
    eq(join(dealt), 'outer'); eq(system:getCurrent(), nil)
    failsAt(function() system:deal({source = unit('s'), target = unit('t'), amount = 1}) end,
        'DamageSystem.deal: the system is disposed')
    eq(#PRINTED, 0)
end)

test('sourceOf credits another Unit; nil, a failure and a wrong value keep the dealer', function()
    local messages, answer = {}, nil
    local system = new({
        onError = function(message) messages[#messages + 1] = message end,
        sourceOf = function(dealer)
            if answer == 'fail' then error('resolver broke', 0) end
            if answer == 'wrong' then return 5 end
            if nameOf(dealer) == 'dummy' then return unit('hero') end
            return nil
        end,
    })
    local seen = {}
    system:observe(function(hit)
        seen[#seen + 1] = nameOf(hit.source) .. ' via ' .. nameOf(hit.dealer) .. ' ' .. tostring(hit.metadata)
    end)
    system:start()
    pre('t', 10, 'dummy'); post('t', 5, 'dummy')
    pre('t'); post('t')
    deal(system, 't', 1, 'spell', 'dummy')
    post('t', 5, 'dummy')
    eq(join(seen), 'hero via dummy nil,s via s nil,hero via dummy spell,hero via dummy nil'); eq(#messages, 0)
    answer = 'fail'
    pre('t', 10, 'dummy'); post('t', 5, 'dummy')
    answer = 'wrong'
    pre('t', 10, 'dummy'); post('t', 5, 'dummy')
    eq(seen[5], 'dummy via dummy nil'); eq(seen[6], 'dummy via dummy nil')
    eq(#messages, 2); eq(messages[1], 'resolver broke'); eq(messages[2], 'expected a Unit or nil')
    eq(#PRINTED, 0)
    system = new({sourceOf = function() error('printed resolver', 0) end})
    system:start()
    pre('t'); post('t')
    eq(#PRINTED, 1); eq(PRINTED[1], '[systems] Damage sourceOf failed: printed resolver')
end)

test('deal checks its arguments at the caller', function()
    local system = new()
    system:start()
    resetCalls()
    failsAt(function() system:deal(5) end, 'DamageSystem.deal: expected a damage request table')
    local gone = unit('gone')
    gone:remove()
    local cases = {
        {'source', {source = 5}}, {'source', {source = gone}}, {'target', {target = {}}}, {'target', {target = gone}},
        {'amount', {amount = -1}}, {'amount', {amount = 0 / 0}}, {'amount', {amount = '1'}},
        {'attack', {attack = 1}}, {'ranged', {ranged = 'yes'}},
    }
    for _, case in ipairs(cases) do
        local request = {source = unit('s'), target = unit('t'), amount = 1}
        for key, value in pairs(case[2]) do request[key] = value end
        failsAt(function() system:deal(request) end, "DamageSystem.deal: '" .. case[1] .. "'")
    end
    eq(callCount('UnitDamageTarget'), 0)
    failsAt(function() DamageSystem.deal({}, {}) end, 'DamageSystem.deal: expected DamageSystem')
end)

test('unknown keys are refused in options and in deals', function()
    failsAt(function() DamageSystem.new({maxQueu = 4}) end, "DamageSystem.new: unknown key 'maxQueu'")
    local system = new()
    system:start()
    local source, target = unit('s'), unit('t')
    failsAt(function() system:deal({source = source, target = target, amount = 1, ammount = 2}) end,
        "DamageSystem.deal: unknown key 'ammount'")
end)

test('a listener added during a hit waits for the next hit, in every phase', function()
    local system = new()
    system:start()
    local source, target = unit('s'), unit('t')
    local late = 0
    system:beforeArmor(function()
        system:afterArmor(function() late = late + 1 end)
    end)
    system:deal({source = source, target = target, amount = 1})
    eq(late, 0)
    system:deal({source = source, target = target, amount = 1})
    eq(late, 1)
end)

test('a full queue drains in order through the head index', function()
    local system = new({maxQueue = 3})
    system:start()
    local source, target = unit('s'), unit('t')
    local order = {}
    system:observe(function(hit) order[#order + 1] = hit.metadata end)
    system:beforeArmor(function(hit)
        if hit.metadata == 0 then
            for index = 1, 3 do system:deal({source = source, target = target, amount = 1, metadata = index}) end
            failsAt(function() system:deal({source = source, target = target, amount = 1}) end,
                'DamageSystem.deal: the queue is full (3 deals)')
        end
    end)
    system:deal({source = source, target = target, amount = 1, metadata = 0})
    eq(table.concat(order, ','), '0,1,2,3')
end)

test('a drained queue keeps its table: a native hit, a settle and a deal allocate none', function()
    local system = new()
    system:beforeArmor(function(hit)
        if hit.metadata == 'outer' then deal(system, 't', 1, 'queued') end
    end)
    system:start()
    local queue = system.queue
    pre('t'); post('t')
    assert(system.queue == queue, 'a native hit replaced the queue table')
    pre('t'); settle()
    assert(system.queue == queue, 'a settle replaced the queue table')
    deal(system, 't', 1)
    assert(system.queue == queue, 'a deal that drained replaced the queue table')
    deal(system, 't', 1, 'outer')
    assert(system.queue == queue, 'a deal with a queued deal replaced the queue table')
    eq(join(dealt), 't,t,t'); eq(next(queue), nil); eq(system.first, 1); eq(system.last, 0); eq(system.chain, 0)
    eq(#PRINTED, 0)
end)
