local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Ground = require('systems.internal.ground')
local Vector = require('systems.internal.vector')
local Scheduler = require('systems.scheduler')
local Effect = require('wrappers.effect')
local Unit = require('wrappers.unit')

local sqrt = math.sqrt
local segmentSphere, orientation = Vector.segmentSphere, Vector.orientation
local height = Ground.height

---Missiles with swept collision: each step tests the whole segment a missile travels, so a fast missile never jumps
---over a unit. The system ticks from its scheduler while missiles are in flight. The per-tick loop calls raw natives
---on the handles it owns or has just enumerated (spec Part 1 §3), and wraps a unit only for a callback.
---@class MoonwellSystems.Missiles
---@field package clock MoonwellSystems.Scheduler
---@field package onError (fun(message: string): ...)?
---@field package ground MoonwellSystems.GroundState? Nil with `terrain = false`: the ground is then the plane z = 0.
---@field package targetOffset number
---@field package maxTargetRadius number
---@field package list MoonwellSystems.Missile[] In launch order; ended missiles leave after the step.
---@field package count integer Missiles in flight.
---@field package ended boolean Whether `list` holds ended missiles.
---@field package ticking boolean
---@field package cancel (fun())? Cancels the scheduler task; nil while nothing flies.
---@field package group group? One reused group for every query.
---@field package units unit[] The contacts of the missile being advanced, by fraction.
---@field package fractions number[]
---@field package disposed boolean
local Missiles = {}
Missiles.__index = Missiles

---@alias MoonwellSystems.MissileEnd 'hit-limit'|'expired'|'range'|'ground'|'cancelled'|'disposed'|'error'

---@class MoonwellSystems.MissileOptions
---@field onError (fun(message: string): ...)? Receives callback failures; default prints them.
---@field terrain boolean? Sample the ground under missiles and targets. Default true; false means flat ground at 0.
---@field targetOffset number? A target's centre above its feet. Default 50.
---@field maxTargetRadius number? The largest collision size hit exactly; larger targets are capped. Default 128.

---@class MoonwellSystems.MissileRequest
---@field x number
---@field y number
---@field height number? Start height above the ground. Default 60.
---@field vx number Units per second.
---@field vy number
---@field vz number? Default 0.
---@field ax number? Constant acceleration; default 0.
---@field ay number?
---@field az number? For example -1400 for an arc.
---@field radius number Not negative.
---@field lifetime number Positive seconds.
---@field maxRange number? Positive distance; the missile then ends with 'range'.
---@field maxHits integer? Default 1; more than 1 pierces.
---@field followGround boolean? Keep `height` above the ground; vz and az must then be 0.
---@field model string? An effect model; the missile creates and owns the effect.
---@field effect MoonwellWrappers.Effect? An effect to take over instead of `model`.
---@field scale number? The created effect's scale; only with `model`.
---@field face boolean? Turn the effect along its travel. Default true.
---@field filter (fun(unit: MoonwellWrappers.Unit, missile: MoonwellSystems.Missile): ...)? Default: any living unit.
---@field steer (fun(missile: MoonwellSystems.Missile, dt: number): ...)? Runs first in every step.
---@field onHit (fun(missile: MoonwellSystems.Missile, unit: MoonwellWrappers.Unit): ...)?
---@field onEnd (fun(missile: MoonwellSystems.Missile, reason: MoonwellSystems.MissileEnd): ...)?
---@field data any Kept as `missile.data`.

---A missile in flight, returned by launch().
---@class MoonwellSystems.Missile
---@field data any The request's `data`.
---@field package system MoonwellSystems.Missiles
---@field package active boolean
---@field package x number
---@field package y number
---@field package z number Absolute.
---@field package vx number
---@field package vy number
---@field package vz number
---@field package ax number
---@field package ay number
---@field package az number
---@field package radius number
---@field package lifetime number
---@field package maxRange number?
---@field package maxHits integer
---@field package followGround boolean
---@field package height number
---@field package effect MoonwellWrappers.Effect?
---@field package raw effect? The effect's handle, for the loop.
---@field package face boolean
---@field package yaw number The orientation last applied.
---@field package pitch number
---@field package filter function?
---@field package steer function?
---@field package onHit function?
---@field package onEnd function?
---@field package age number
---@field package travelled number
---@field package hits table<unit, true> Looked up, never iterated.
---@field package hitCount integer
local Missile = {}
Missile.__index = Missile
Missiles.Missile = Missile

local NUMBERS = {'x', 'y', 'vx', 'vy', 'radius', 'lifetime'}
local OPTIONAL = {'height', 'vz', 'ax', 'ay', 'az', 'maxRange', 'scale'}
local CALLBACKS = {'filter', 'steer', 'onHit', 'onEnd'}

-- Ending

---@param system MoonwellSystems.Missiles
local function stop(system)
    local cancel = system.cancel
    if cancel then
        system.cancel = nil
        cancel()
    end
end

---Ends a missile once: releases its place, destroys its effect, then runs onEnd.
---@param missile MoonwellSystems.Missile
---@param reason MoonwellSystems.MissileEnd
local function finish(missile, reason)
    if not missile.active then return end
    missile.active = false
    local system = missile.system
    system.count = system.count - 1
    system.ended = true
    missile.hits = {}
    local effect = missile.effect
    if effect then effect:destroy() end -- does nothing if its owner destroyed it first
    missile.raw = nil
    local onEnd = missile.onEnd
    if onEnd then Callback.call('Missile end', system.onError, onEnd, missile, reason) end
    if system.count == 0 and not system.ticking then stop(system) end
end

-- A step

---Moves the missile's effect to its position and, when asked, turns it along the travel (dx, dy, dz).
---@param missile MoonwellSystems.Missile
---@param dx number
---@param dy number
---@param dz number
local function show(missile, dx, dy, dz)
    local raw = missile.raw
    if not raw then return end
    BlzSetSpecialEffectPosition(raw, missile.x, missile.y, missile.z)
    if missile.face and (dx ~= 0 or dy ~= 0 or dz ~= 0) then
        local yaw, pitch = orientation(dx, dy, dz)
        if yaw ~= missile.yaw or pitch ~= missile.pitch then
            missile.yaw, missile.pitch = yaw, pitch
            BlzSetSpecialEffectOrientation(raw, yaw, pitch, 0)
        end
    end
end

---@param system MoonwellSystems.Missiles
---@param missile MoonwellSystems.Missile
---@param dt number
local function advance(system, missile, dt)
    local onError = system.onError
    local remaining = missile.lifetime - missile.age
    local expiring = remaining <= dt
    local seconds = expiring and remaining or dt
    local steer = missile.steer
    if steer then
        if not Callback.call('Missile callback', onError, steer, missile, seconds) then
            finish(missile, 'error')
            return
        end
        if not missile.active then return end
    end
    -- Semi-implicit Euler: velocity first, then position. Stable, and the same on every machine.
    local vx, vy, vz = missile.vx + missile.ax * seconds, missile.vy + missile.ay * seconds,
        missile.vz + missile.az * seconds
    missile.vx, missile.vy, missile.vz = vx, vy, vz
    local speed = sqrt(vx * vx + vy * vy + vz * vz)
    local maxRange, ranging = missile.maxRange, false
    if maxRange and speed > 0 then
        local left = (maxRange - missile.travelled) / speed
        if left <= seconds then
            ranging = true
            if left < seconds then seconds, expiring = left, false end
        end
    end
    local fx, fy, fz = missile.x, missile.y, missile.z
    local tx, ty, tz = fx + vx * seconds, fy + vy * seconds, fz + vz * seconds
    local ground, follow = system.ground, missile.followGround
    if follow then tz = (ground and height(ground, tx, ty) or 0) + missile.height end

    -- Candidates: the units within reach of the segment, in the engine's enumeration order.
    local group = system.group
    if not group then
        group = CreateGroup()
        system.group = group
    end
    local radius, cap = missile.radius, system.maxTargetRadius
    local dx, dy = tx - fx, ty - fy
    -- A unit the step touches is within half the step, the missile's radius and its own radius of the step's
    -- midpoint. The enumeration tests unit origins, so it reaches the largest target radius; it clears the group
    -- first, so the group is never cleared here (both measured on 3.0.0.24268).
    local mx, my, reach = (fx + tx) / 2, (fy + ty) / 2, sqrt(dx * dx + dy * dy) / 2 + radius
    -- Warcraft accepts a null filter; the generated JASS signature cannot express that.
    ---@diagnostic disable-next-line: param-type-mismatch
    GroupEnumUnitsInRange(group, mx, my, reach + cap, nil)
    local units, fractions, hits, offset = system.units, system.fractions, missile.hits, system.targetOffset
    local contacts = 0
    for index = 0, BlzGroupGetSize(group) - 1 do
        local unit = BlzGroupUnitAt(group, index)
        -- One native rules out most units, which then need no other: IsUnitInRangeXY is true up to the range plus
        -- the unit's collision size (measured).
        if not hits[unit] and IsUnitInRangeXY(unit, mx, my, reach) then
            local ux, uy = GetUnitX(unit), GetUnitY(unit)
            local size = BlzGetUnitCollisionSize(unit)
            if size > cap then size = cap end
            local uz = (ground and height(ground, ux, uy) or 0) + GetUnitFlyHeight(unit) + offset
            local fraction = segmentSphere(fx, fy, fz, tx, ty, tz, ux, uy, uz, radius + size)
            if fraction then
                -- Insertion sort by fraction; a tie keeps the enumeration order.
                local place = contacts
                while place > 0 and fractions[place] > fraction do
                    units[place + 1], fractions[place + 1] = units[place], fractions[place]
                    place = place - 1
                end
                units[place + 1], fractions[place + 1] = unit, fraction
                contacts = contacts + 1
            end
        end
    end

    local filter, onHit = missile.filter, missile.onHit
    for index = 1, contacts do
        local unit = units[index]
        -- Dead units are enumerated too, and an earlier hit of this step may have killed this one.
        if UnitAlive(unit) then
            local target = Unit.fromHandle(unit) --[[@as MoonwellWrappers.Unit]]
            local allowed = true
            if filter then
                local ok, result = pcall(filter, target, missile)
                if not ok then
                    Callback.report('Missile callback', onError, result)
                    finish(missile, 'error')
                    return
                end
                if not missile.active then return end
                allowed = result and true or false
            end
            if allowed then
                hits[unit] = true
                missile.hitCount = missile.hitCount + 1
                local fraction = fractions[index]
                missile.x, missile.y, missile.z = fx + dx * fraction, fy + dy * fraction, fz + (tz - fz) * fraction
                show(missile, dx, dy, tz - fz)
                if onHit and not Callback.call('Missile callback', onError, onHit, missile, target) then
                    finish(missile, 'error')
                    return
                end
                if not missile.active then return end
                if missile.hitCount >= missile.maxHits then
                    finish(missile, 'hit-limit')
                    return
                end
            end
        end
    end

    -- The ground is checked at the step's end only, so a hit earlier in the same step still counts.
    local landed = false
    if not follow then
        local surface = ground and height(ground, tx, ty) or 0
        if tz < surface then tz, landed = surface, true end
    end
    missile.x, missile.y, missile.z = tx, ty, tz
    missile.age = missile.age + seconds
    missile.travelled = ranging and maxRange or missile.travelled + speed * seconds
    show(missile, dx, dy, tz - fz)
    if landed then
        finish(missile, 'ground')
    elseif expiring then
        finish(missile, 'expired')
    elseif ranging then
        finish(missile, 'range')
    end
end

---One scheduler step: advances the missiles that were in flight when it began, in launch order.
---@param system MoonwellSystems.Missiles
local function tick(system)
    local list, dt = system.list, system.clock:getStep()
    system.ticking = true
    for index = 1, #list do
        local missile = list[index]
        if missile.active then advance(system, missile, dt) end
    end
    system.ticking = false
    if system.ended then
        local kept = {}
        for _, missile in ipairs(system.list) do
            if missile.active then kept[#kept + 1] = missile end
        end
        system.list, system.ended = kept, false
    end
    if system.count == 0 then stop(system) end
end

-- Missiles

---@param clock MoonwellSystems.Scheduler Drives the missiles; they move once per scheduler step.
---@param options MoonwellSystems.MissileOptions?
---@return MoonwellSystems.Missiles
function Missiles.new(clock, options)
    Check.receiver(clock, Scheduler, 'Scheduler', 'Missiles.new')
    if options == nil then options = {} end
    if type(options) ~= 'table' then error('[systems] Missiles.new: expected an options table', 2) end
    Callback.optional(options.onError, 'Missiles.new')
    local terrain, offset, cap = options.terrain, options.targetOffset, options.maxTargetRadius
    if terrain ~= nil and type(terrain) ~= 'boolean' then
        error('[systems] Missiles.new: expected missile options: terrain', 2)
    end
    if offset == nil then offset = 50 end
    if not Check.finite(offset) then error('[systems] Missiles.new: expected missile options: targetOffset', 2) end
    if cap == nil then cap = 128 end
    if not Check.finite(cap) or cap < 0 then
        error('[systems] Missiles.new: expected missile options: maxTargetRadius', 2)
    end
    return setmetatable({
        clock = clock, onError = options.onError, ground = terrain ~= false and Ground.new() or nil,
        targetOffset = offset, maxTargetRadius = cap, list = {}, count = 0, ended = false, ticking = false,
        units = {}, fractions = {}, disposed = false,
    }, Missiles)
end

---@param request table
---@return string? field The first invalid field, or nil.
local function invalid(request)
    for _, name in ipairs(NUMBERS) do
        if not Check.finite(request[name]) then return name end
    end
    for _, name in ipairs(OPTIONAL) do
        if request[name] ~= nil and not Check.finite(request[name]) then return name end
    end
    if request.radius < 0 then return 'radius' end
    if request.lifetime <= 0 then return 'lifetime' end
    if request.maxRange ~= nil and request.maxRange <= 0 then return 'maxRange' end
    local maxHits = request.maxHits
    if maxHits ~= nil and (math.type(maxHits) == nil or math.floor(maxHits) ~= maxHits or maxHits < 1) then
        return 'maxHits'
    end
    local vz, ax, ay, az = request.vz or 0, request.ax or 0, request.ay or 0, request.az or 0
    if not Check.finite(request.vx * request.vx + request.vy * request.vy + vz * vz) then return 'velocity' end
    if not Check.finite(ax * ax + ay * ay + az * az) then return 'acceleration' end
    for _, name in ipairs({'followGround', 'face'}) do
        if request[name] ~= nil and type(request[name]) ~= 'boolean' then return name end
    end
    if request.followGround and (vz ~= 0 or az ~= 0) then return 'followGround' end
    local model, effect = request.model, request.effect
    if model ~= nil and (type(model) ~= 'string' or model == '') then return 'model' end
    if effect ~= nil and (getmetatable(effect) ~= Effect or effect:isDisposed()) then return 'effect' end
    if model ~= nil and effect ~= nil then return 'model and effect' end
    if request.scale ~= nil and model == nil then return 'scale' end
    for _, name in ipairs(CALLBACKS) do
        if request[name] ~= nil and type(request[name]) ~= 'function' then return name end
    end
    return nil
end

---Launches a missile. It first moves on the next scheduler step.
---@param request MoonwellSystems.MissileRequest
---@return MoonwellSystems.Missile
function Missiles:launch(request)
    local system = Check.receiver(self, Missiles, 'Missiles', 'Missiles.launch')
    if system.disposed then error('[systems] Missiles.launch: the system is disposed', 2) end
    if type(request) ~= 'table' then error('[systems] Missiles.launch: expected a missile request table', 2) end
    local field = invalid(request)
    if field then error('[systems] Missiles.launch: expected a missile request: ' .. field, 2) end
    local x, y, above = request.x, request.y, request.height or 60
    local ground = system.ground
    local z = (ground and height(ground, x, y) or 0) + above
    local vx, vy, vz = request.vx, request.vy, request.vz or 0
    local effect = request.effect
    if request.model then
        local ok, created = pcall(Effect.create, request.model, x, y)
        if not ok then
            -- The wrappers' message without its position, raised at this function's caller.
            local reason = tostring(created):gsub('^.-:%d+: ', '')
            error('[systems] Missiles.launch: ' .. reason, 2)
        end
        effect = created
        if request.scale then effect:setScale(request.scale) end
    end
    local face = request.face ~= false
    local yaw, pitch = 0, 0
    if effect then
        effect:setPosition(x, y, z)
        if face and (vx ~= 0 or vy ~= 0 or vz ~= 0) then
            yaw, pitch = orientation(vx, vy, vz)
            effect:setOrientation(yaw, pitch, 0)
        end
    end
    ---@type MoonwellSystems.Missile
    local missile = setmetatable({
        data = request.data, system = system, active = true, x = x, y = y, z = z, vx = vx, vy = vy, vz = vz,
        ax = request.ax or 0, ay = request.ay or 0, az = request.az or 0, radius = request.radius,
        lifetime = request.lifetime, maxRange = request.maxRange, maxHits = request.maxHits or 1,
        followGround = request.followGround == true, height = above, effect = effect,
        raw = effect and effect:getHandle() or nil, face = face, yaw = yaw, pitch = pitch, filter = request.filter,
        steer = request.steer, onHit = request.onHit, onEnd = request.onEnd, age = 0, travelled = 0, hits = {},
        hitCount = 0,
    }, Missile)
    system.list[#system.list + 1] = missile
    system.count = system.count + 1
    if not system.cancel then
        system.cancel = system.clock:every(system.clock:getStep(), function() tick(system) end)
    end
    return missile
end

---Missiles in flight.
---@return integer
function Missiles:getCount() return Check.receiver(self, Missiles, 'Missiles', 'Missiles.getCount').count end

---Ends every missile with 'disposed', in launch order, and removes the owned handles. Launching afterwards raises.
---Idempotent.
function Missiles:dispose()
    local system = Check.receiver(self, Missiles, 'Missiles', 'Missiles.dispose')
    if system.disposed then return end
    system.disposed = true
    local list = system.list
    for index = 1, #list do finish(list[index], 'disposed') end
    system.list = {}
    stop(system)
    if system.group then DestroyGroup(system.group); system.group = nil end
    if system.ground then Ground.dispose(system.ground) end
end

-- Missile

---The position; z is absolute.
---@return number x
---@return number y
---@return number z
function Missile:getPosition()
    local missile = Check.receiver(self, Missile, 'Missile', 'Missile.getPosition')
    return missile.x, missile.y, missile.z
end

---@return number vx
---@return number vy
---@return number vz
function Missile:getVelocity()
    local missile = Check.receiver(self, Missile, 'Missile', 'Missile.getVelocity')
    return missile.vx, missile.vy, missile.vz
end

---Sets the velocity, for example from `steer`. With followGround, vz must be 0.
---@param vx number
---@param vy number
---@param vz number
function Missile:setVelocity(vx, vy, vz)
    local missile = Check.receiver(self, Missile, 'Missile', 'Missile.setVelocity')
    if not Check.finite(vx) or not Check.finite(vy) or not Check.finite(vz)
        or not Check.finite(vx * vx + vy * vy + vz * vz) then
        error('[systems] Missile.setVelocity: expected a finite velocity', 2)
    end
    if missile.followGround and vz ~= 0 then
        error('[systems] Missile.setVelocity: a followGround missile has no vertical velocity', 2)
    end
    missile.vx, missile.vy, missile.vz = vx, vy, vz
end

---Seconds flown.
---@return number
function Missile:getAge() return Check.receiver(self, Missile, 'Missile', 'Missile.getAge').age end
---Distance flown.
---@return number
function Missile:getTravelled() return Check.receiver(self, Missile, 'Missile', 'Missile.getTravelled').travelled end
---Units hit so far.
---@return integer
function Missile:getHitCount() return Check.receiver(self, Missile, 'Missile', 'Missile.getHitCount').hitCount end
---The missile's Effect, or nil. Do not destroy it: the missile does.
---@return MoonwellWrappers.Effect?
function Missile:getEffect() return Check.receiver(self, Missile, 'Missile', 'Missile.getEffect').effect end
---False once the missile has ended.
---@return boolean
function Missile:isActive() return Check.receiver(self, Missile, 'Missile', 'Missile.isActive').active end

---Ends the missile with 'cancelled'. Idempotent.
function Missile:dispose()
    finish(Check.receiver(self, Missile, 'Missile', 'Missile.dispose'), 'cancelled')
end

return Missiles
