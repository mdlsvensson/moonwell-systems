local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Fields = require('systems.internal.fields')
local Ordered = require('systems.internal.ordered')
local Scheduler = require('systems.scheduler')
local Unit = require('wrappers.unit')
local PlayerWrapper = require('wrappers.player')

---Fresh dummy casters: each cast creates a unit, configures it, orders the cast and removes it after `duration`.
---No pooling. The dummy unit type comes from the map's object data (README).
---@class MoonwellSystems.Dummies
---@field package clock MoonwellSystems.Scheduler
---@field package onError (fun(message: string): ...)?
---@field package leases MoonwellSystems.Ordered Unit -> MoonwellSystems.DummyLease, in cast order.
---@field package disposed boolean
local Dummies = {}
Dummies.__index = Dummies

---Ownership of one live dummy. Disposing it, or its duration running out, removes the unit.
---@class MoonwellSystems.DummyLease
---@field package manager MoonwellSystems.Dummies
---@field package unit MoonwellWrappers.Unit
---@field package source MoonwellWrappers.Unit?
---@field package accepted boolean
---@field package cancel fun()?
---@field package live boolean
local DummyLease = {}
DummyLease.__index = DummyLease

---@class MoonwellSystems.DummyCast
---@field owner MoonwellWrappers.Player
---@field typeId integer The dummy unit type.
---@field x number
---@field y number
---@field facing number? Default 0.
---@field ability integer
---@field level integer? Default 1.
---@field order string|integer An order string, or an order id.
---@field target MoonwellWrappers.Widget? A target widget; set target or point, not both.
---@field point {x: number, y: number}?
---@field duration number Seconds; cover cast point, channel time and projectile travel.
---@field source MoonwellWrappers.Unit? The real caster, for sourceOf.

local LOCUST = 1097625443 -- 'Aloc'

local OPTIONS = {clock = {Fields.class(Scheduler, 'a Scheduler'), required = true}, onError = {'function'}}

local function order(value) return (type(value) == 'string' and value ~= '') or math.type(value) == 'integer' end
local function widget(value) return type(value) == 'table' and type(value.getLife) == 'function' end
local function point(value) return type(value) == 'table' and Check.finite(value.x) and Check.finite(value.y) end

local CAST = {
    owner = {Fields.class(PlayerWrapper, 'a Player'), required = true},
    typeId = {Fields.integer(), required = true},
    x = {'finite', required = true},
    y = {'finite', required = true},
    facing = {'finite', default = 0},
    ability = {Fields.integer(), required = true},
    level = {Fields.integer(1), default = 1},
    order = {Fields.test(order, 'an order string or order id'), required = true},
    target = {Fields.test(widget, 'a widget')},
    point = {Fields.test(point, 'a point {x, y} of finite numbers')},
    duration = {'positive', required = true},
    source = {Fields.class(Unit, 'a Unit')},
}

---@param unit MoonwellWrappers.Unit
---@param request MoonwellSystems.DummyCast
---@return boolean accepted
local function issue(unit, request)
    local order, target, point = request.order, request.target, request.point
    if type(order) == 'string' then
        if target ~= nil then return unit:issueTargetOrder(order, target) end
        if point ~= nil then return unit:issuePointOrder(order, point.x, point.y) end
        return unit:issueOrder(order)
    end
    if target ~= nil then return unit:issueTargetOrderById(order, target) end
    if point ~= nil then return unit:issuePointOrderById(order, point.x, point.y) end
    return unit:issueOrderById(order)
end

---@param lease MoonwellSystems.DummyLease
local function release(lease)
    if not lease.live then return end
    lease.live = false
    if lease.cancel then lease.cancel(); lease.cancel = nil end
    lease.manager.leases:delete(lease.unit)
    local unit = lease.unit
    Callback.call('Dummy release', lease.manager.onError, function()
        if not unit:isDisposed() then unit:remove() end
    end)
end

---@param options {clock: MoonwellSystems.Scheduler, onError: (fun(message: string): ...)?}
---@return MoonwellSystems.Dummies
function Dummies.new(options)
    local read = Fields.options(options, OPTIONS, 'Dummies.new')
    return setmetatable({clock = read.clock, onError = read.onError, leases = Ordered.new(), disposed = false},
        Dummies)
end

---Creates a dummy, configures it (Locust, invulnerable, no pathing, the ability, full mana), orders the cast and
---schedules its removal. A rejected order removes the dummy at once.
---@param request MoonwellSystems.DummyCast
---@return MoonwellSystems.DummyLease
function Dummies:cast(request)
    local dummies = Check.receiver(self, Dummies, 'Dummies', 'Dummies.cast')
    if dummies.disposed then error('[systems] Dummies.cast: the manager is disposed', 2) end
    local cast = Fields.request(request, CAST, 'Dummies.cast', 'a cast request table')
    if cast.target ~= nil and cast.point ~= nil then
        error("[systems] Dummies.cast: 'point' cannot be given with 'target'", 2)
    end
    local unit = Unit.create(cast.owner, cast.typeId, cast.x, cast.y, cast.facing)
    ---@type MoonwellSystems.DummyLease
    local lease = setmetatable({manager = dummies, unit = unit, source = cast.source, accepted = false, live = true},
        DummyLease)
    dummies.leases:set(unit, lease)
    unit:addAbility(LOCUST)
    unit:setInvulnerable(true)
    unit:setPathing(false)
    if not unit:addAbility(cast.ability) and unit:getAbilityLevel(cast.ability) == 0 then
        release(lease)
        error('[systems] Dummies.cast: the dummy cannot get ability ' .. cast.ability, 2)
    end
    unit:setAbilityLevel(cast.ability, cast.level)
    unit:setMana(unit:getMaxMana())
    local issued, accepted = pcall(issue, unit, cast)
    if not issued then
        release(lease)
        error(accepted, 0)
    end
    lease.accepted = accepted
    if accepted then
        lease.cancel = dummies.clock:after(cast.duration, function() release(lease) end)
    else
        release(lease)
    end
    return lease
end

---True while `unit` is a live dummy of this manager.
---@return boolean
function Dummies:isDummy(unit) return Check.receiver(self, Dummies, 'Dummies', 'Dummies.isDummy').leases:has(unit) end

---The caster a live dummy acts for; nil for other units and for dummies cast without a source.
---@return MoonwellWrappers.Unit?
function Dummies:sourceOf(unit)
    local lease = Check.receiver(self, Dummies, 'Dummies', 'Dummies.sourceOf').leases:get(unit)
    return lease and lease.source
end

---@return integer
function Dummies:getCount() return Check.receiver(self, Dummies, 'Dummies', 'Dummies.getCount').leases:getSize() end

---Removes every live dummy in cast order. Casting afterwards raises. Idempotent.
function Dummies:dispose()
    local dummies = Check.receiver(self, Dummies, 'Dummies', 'Dummies.dispose')
    if dummies.disposed then return end
    dummies.disposed = true
    dummies.leases:each(function(_, lease) release(lease) end)
end

---@return MoonwellWrappers.Unit
function DummyLease:getUnit() return Check.receiver(self, DummyLease, 'DummyLease', 'DummyLease.getUnit').unit end
---@return MoonwellWrappers.Unit?
function DummyLease:getSource() return Check.receiver(self, DummyLease, 'DummyLease', 'DummyLease.getSource').source end
---False once the dummy has been removed.
---@return boolean
function DummyLease:isActive() return Check.receiver(self, DummyLease, 'DummyLease', 'DummyLease.isActive').live end
---Whether the game accepted the cast order.
---@return boolean
function DummyLease:isOrderAccepted()
    return Check.receiver(self, DummyLease, 'DummyLease', 'DummyLease.isOrderAccepted').accepted
end
---Removes the dummy now. Idempotent.
function DummyLease:dispose() release(Check.receiver(self, DummyLease, 'DummyLease', 'DummyLease.dispose')) end

return Dummies
