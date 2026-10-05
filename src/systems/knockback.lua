local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Fields = require('systems.internal.fields')
local Ground = require('systems.internal.ground')
local Ordered = require('systems.internal.ordered')
local Stepper = require('systems.internal.stepper')
local Scheduler = require('systems.scheduler')
local Unit = require('wrappers.unit')

local sqrt, ceil, cos, sin = math.sqrt, math.ceil, math.cos, math.sin

---Knockbacks: a unit is pushed a distance along an angle over a duration. One knockback per unit; a new one replaces
---the old. The system ticks from its scheduler while units are being pushed, and moves them with SetUnitX/Y, which
---keeps their orders and never pauses them. Raw natives on the unit handles by design (spec Part 1 §3).
---@class MoonwellSystems.Knockbacks
---@field package clock MoonwellSystems.Scheduler
---@field package onError (fun(message: string): ...)?
---@field package pathing 'obstacles'|'terrain'|'none'|MoonwellSystems.KnockbackPathing
---@field package sampleStep number
---@field package ground MoonwellSystems.GroundState
---@field package active MoonwellSystems.Ordered Unit to its Knockback, in apply order.
---@field package stepper MoonwellSystems.Stepper
---@field package disposed boolean
local Knockbacks = {}
Knockbacks.__index = Knockbacks

---@alias MoonwellSystems.KnockbackEnd 'completed'|'replaced'|'interrupted'|'invalid'|'blocked'|'disposed'|'error'

---Whether a unit may move from (fromX, fromY) to (toX, toY).
---@alias MoonwellSystems.KnockbackPathing
---| fun(unit: MoonwellWrappers.Unit, fromX: number, fromY: number, toX: number, toY: number): ...

---@class MoonwellSystems.KnockbackOptions
---@field clock MoonwellSystems.Scheduler Drives the knockbacks; units move once per scheduler step.
---@field onError (fun(message: string): ...)? Receives callback failures; default prints them.
---@field pathing ('obstacles'|'terrain'|'none'|MoonwellSystems.KnockbackPathing)? Default 'obstacles'.
---@field sampleStep number? The largest gap between pathing samples along a move. Default 32.

---@class MoonwellSystems.KnockbackRequest
---@field angle number Radians, as math.atan(dy, dx) gives. (The wrappers' facings are degrees.)
---@field distance number Not negative.
---@field duration number Positive seconds.
---@field falloff ('none'|'linear')? 'linear' decays the speed to zero at the end. Default 'none'.
---@field onEnd (fun(knockback: MoonwellSystems.Knockback, reason: MoonwellSystems.KnockbackEnd): ...)?

---One unit's knockback, returned by apply().
---@class MoonwellSystems.Knockback
---@field package system MoonwellSystems.Knockbacks
---@field package unit MoonwellWrappers.Unit
---@field package raw unit The unit's handle, for the loop.
---@field package active boolean
---@field package dirX number
---@field package dirY number
---@field package speed number The starting speed.
---@field package duration number
---@field package linear boolean
---@field package elapsed number
---@field package onEnd function?
local Knockback = {}
Knockback.__index = Knockback
Knockbacks.Knockback = Knockback

local MAX_SAMPLES = 4096

local function pathingPolicy(value)
    return type(value) == 'function' or value == 'obstacles' or value == 'terrain' or value == 'none'
end

local OPTIONS = {
    clock = {Fields.class(Scheduler, 'a Scheduler'), required = true},
    onError = {'function'},
    pathing = {Fields.test(pathingPolicy, "'obstacles', 'terrain', 'none' or a function"), default = 'obstacles'},
    sampleStep = {'positive', default = 32},
}

local PUSH = {
    angle = {'finite', required = true},
    distance = {'nonNegative', required = true},
    duration = {'positive', required = true},
    falloff = {Fields.enum({'none', 'linear'}), default = 'none'},
    onEnd = {'function'},
}

---Ends a knockback once: releases the unit (unless a newer knockback owns it), then runs onEnd.
---@param item MoonwellSystems.Knockback
---@param reason MoonwellSystems.KnockbackEnd
local function finish(item, reason)
    if not item.active then return end
    item.active = false
    local system = item.system
    local active = system.active
    if active:get(item.unit) == item then active:delete(item.unit) end
    local onEnd = item.onEnd
    if onEnd then Callback.call('Knockback end', system.onError, onEnd, item, reason) end
    system.stepper:settle()
end

---Whether the move is allowed. Nil when the pathing function failed and the knockback has ended.
---@param system MoonwellSystems.Knockbacks
---@param item MoonwellSystems.Knockback
---@param fx number
---@param fy number
---@param tx number
---@param ty number
---@return boolean?
local function allowed(system, item, fx, fy, tx, ty)
    local ground = system.ground
    -- SetUnitX outside the world bounds can crash the game: no policy allows it.
    if not Ground.inBounds(ground, tx, ty) then return false end
    local pathing = system.pathing
    if pathing == 'none' then return true end
    if type(pathing) == 'function' then
        local ok, result = pcall(pathing, item.unit, fx, fy, tx, ty)
        if not ok then
            Callback.report('Knockback pathing', system.onError, result)
            finish(item, 'error')
            return nil
        end
        return result and true or false
    end
    if IsUnitType(item.raw, UNIT_TYPE_FLYING) then return true end
    local dx, dy = tx - fx, ty - fy
    local samples = ceil(sqrt(dx * dx + dy * dy) / system.sampleStep)
    if samples > MAX_SAMPLES then return false end
    local check = pathing == 'terrain' and Ground.isWalkable or Ground.isClear
    for sample = 1, samples do
        if not check(ground, fx + dx * sample / samples, fy + dy * sample / samples) then return false end
    end
    return true
end

---@param system MoonwellSystems.Knockbacks
---@param item MoonwellSystems.Knockback
---@param dt number
local function advance(system, item, dt)
    local raw = item.raw
    -- False for a dead unit and for a removed one. That covers a disposed wrapper, which ends by remove() or, since
    -- wrappers v0.9.0, by Unit.autoDispose after its unit was removed.
    if not UnitAlive(raw) then
        finish(item, 'invalid')
        return
    end
    local duration, t0 = item.duration, item.elapsed
    local t1 = t0 + dt
    if t1 > duration then t1 = duration end
    -- The exact distance for this step; linear: speed(t) = speed * (1 - t / duration).
    local travel = t1 - t0
    if item.linear then travel = travel - (t1 * t1 - t0 * t0) / (2 * duration) end
    travel = travel * item.speed
    local fx, fy = GetUnitX(raw), GetUnitY(raw)
    local tx, ty = fx + item.dirX * travel, fy + item.dirY * travel
    local free = allowed(system, item, fx, fy, tx, ty)
    if free == nil then return end
    if not free then
        finish(item, 'blocked')
        return
    end
    if not item.active then return end
    SetUnitX(raw, tx)
    SetUnitY(raw, ty)
    item.elapsed = t1
    if t1 >= duration then finish(item, 'completed') end
end

---@param options MoonwellSystems.KnockbackOptions
---@return MoonwellSystems.Knockbacks
function Knockbacks.new(options)
    local read = Fields.options(options, OPTIONS, 'Knockbacks.new')
    ---@type MoonwellSystems.Knockbacks
    local system = setmetatable({
        clock = read.clock, onError = read.onError, pathing = read.pathing, sampleStep = read.sampleStep,
        ground = Ground.new(), active = Ordered.new(), disposed = false,
    }, Knockbacks)
    local function visit(_, item) advance(system, item, read.clock:getStep()) end
    system.stepper = Stepper.new(read.clock, function() system.active:each(visit) end,
        function() return system.active:getSize() == 0 end)
    return system
end

---Pushes a unit, replacing its current knockback (which ends with 'replaced'). It first moves on the next scheduler
---step.
---@param unit MoonwellWrappers.Unit
---@param request MoonwellSystems.KnockbackRequest
---@return MoonwellSystems.Knockback
function Knockbacks:apply(unit, request)
    local system = Check.receiver(self, Knockbacks, 'Knockbacks', 'Knockbacks.apply')
    if system.disposed then error('[systems] Knockbacks.apply: the system is disposed', 2) end
    if not Check.liveUnit(unit, Unit) then error('[systems] Knockbacks.apply: expected a live Unit', 2) end
    local push = Fields.request(request, PUSH, 'Knockbacks.apply', 'a knockback request table')
    local linear = push.falloff == 'linear'
    ---@type MoonwellSystems.Knockback
    local item = setmetatable({
        system = system, unit = unit, raw = unit:getHandle(), active = true, dirX = cos(push.angle),
        dirY = sin(push.angle), speed = (linear and 2 or 1) * push.distance / push.duration,
        duration = push.duration, linear = linear, elapsed = 0, onEnd = push.onEnd,
    }, Knockback)
    local previous = system.active:get(unit)
    -- Install first: if the old knockback's onEnd applies again, that newer one replaces this one.
    system.active:set(unit, item)
    if previous then finish(previous, 'replaced') end
    system.stepper:wake()
    return item
end

---The unit's active knockback, or nil.
---@param unit MoonwellWrappers.Unit
---@return MoonwellSystems.Knockback?
function Knockbacks:get(unit)
    local system = Check.receiver(self, Knockbacks, 'Knockbacks', 'Knockbacks.get')
    if getmetatable(unit) ~= Unit then error('[systems] Knockbacks.get: expected Unit', 2) end
    return system.active:get(unit)
end

---Active knockbacks.
---@return integer
function Knockbacks:getCount()
    return Check.receiver(self, Knockbacks, 'Knockbacks', 'Knockbacks.getCount').active:getSize()
end

---Ends every knockback with 'disposed', in apply order, and removes the owned handles. Applying afterwards raises.
---Idempotent.
function Knockbacks:dispose()
    local system = Check.receiver(self, Knockbacks, 'Knockbacks', 'Knockbacks.dispose')
    if system.disposed then return end
    system.disposed = true
    system.active:each(function(_, item) finish(item, 'disposed') end)
    system.stepper:dispose()
    Ground.dispose(system.ground)
end

---@return MoonwellWrappers.Unit
function Knockback:getUnit() return Check.receiver(self, Knockback, 'Knockback', 'Knockback.getUnit').unit end
---False once the knockback has ended.
---@return boolean
function Knockback:isActive() return Check.receiver(self, Knockback, 'Knockback', 'Knockback.isActive').active end
---Seconds left; 0 once it has ended.
---@return number
function Knockback:getRemaining()
    local item = Check.receiver(self, Knockback, 'Knockback', 'Knockback.getRemaining')
    return item.active and item.duration - item.elapsed or 0
end

---Ends the knockback with 'interrupted'. Idempotent.
function Knockback:dispose()
    finish(Check.receiver(self, Knockback, 'Knockback', 'Knockback.dispose'), 'interrupted')
end

return Knockbacks
