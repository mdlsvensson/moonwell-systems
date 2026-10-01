local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
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

local function integer(value) return math.type(value) ~= nil and math.floor(value) == value end

---@return string? field The first invalid field, or nil.
local function invalid(request)
    if getmetatable(request.owner) ~= PlayerWrapper then return 'owner' end
    if not integer(request.typeId) then return 'typeId' end
    if not Check.finite(request.x) then return 'x' end
    if not Check.finite(request.y) then return 'y' end
    if request.facing ~= nil and not Check.finite(request.facing) then return 'facing' end
    if not integer(request.ability) then return 'ability' end
    if request.level ~= nil and not (integer(request.level) and request.level >= 1) then return 'level' end
    local order = request.order
    if not ((type(order) == 'string' and order ~= '') or math.type(order) == 'integer') then return 'order' end
    if not (Check.finite(request.duration) and request.duration > 0) then return 'duration' end
    local target, point = request.target, request.point
    if target ~= nil and point ~= nil then return 'target and point' end
    if target ~= nil and not (type(target) == 'table' and type(target.getLife) == 'function') then return 'target' end
    if point ~= nil and not (type(point) == 'table' and Check.finite(point.x) and Check.finite(point.y)) then
        return 'point'
    end
    if request.source ~= nil and getmetatable(request.source) ~= Unit then return 'source' end
    return nil
end

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

---@param clock MoonwellSystems.Scheduler Schedules each dummy's removal.
---@param options {onError: (fun(message: string): ...)?}?
---@return MoonwellSystems.Dummies
function Dummies.new(clock, options)
    Check.receiver(clock, Scheduler, 'Scheduler', 'Dummies.new')
    if options ~= nil and type(options) ~= 'table' then error('[systems] Dummies.new: expected an options table', 2) end
    options = options or {}
    Callback.optional(options.onError, 'Dummies.new')
    return setmetatable({clock = clock, onError = options.onError, leases = Ordered.new(), disposed = false}, Dummies)
end

---Creates a dummy, configures it (Locust, invulnerable, no pathing, the ability, full mana), orders the cast and
---schedules its removal. A rejected order removes the dummy at once.
---@param request MoonwellSystems.DummyCast
---@return MoonwellSystems.DummyLease
function Dummies:cast(request)
    local dummies = Check.receiver(self, Dummies, 'Dummies', 'Dummies.cast')
    if dummies.disposed then error('[systems] Dummies.cast: the manager is disposed', 2) end
    if type(request) ~= 'table' then error('[systems] Dummies.cast: expected a cast request table', 2) end
    local field = invalid(request)
    if field then error('[systems] Dummies.cast: expected a cast request: ' .. field, 2) end
    local unit = Unit.create(request.owner, request.typeId, request.x, request.y, request.facing or 0)
    ---@type MoonwellSystems.DummyLease
    local lease = setmetatable({manager = dummies, unit = unit, source = request.source, accepted = false, live = true},
        DummyLease)
    dummies.leases:set(unit, lease)
    unit:addAbility(LOCUST)
    unit:setInvulnerable(true)
    unit:setPathing(false)
    if not unit:addAbility(request.ability) and unit:getAbilityLevel(request.ability) == 0 then
        release(lease)
        error('[systems] Dummies.cast: the dummy cannot get ability ' .. request.ability, 2)
    end
    unit:setAbilityLevel(request.ability, request.level or 1)
    unit:setMana(unit:getMaxMana())
    local issued, accepted = pcall(issue, unit, request)
    if not issued then
        release(lease)
        error(accepted, 0)
    end
    lease.accepted = accepted
    if accepted then
        lease.cancel = dummies.clock:after(request.duration, function() release(lease) end)
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
