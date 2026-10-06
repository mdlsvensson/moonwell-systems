local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Fields = require('systems.internal.fields')
local Ground = require('systems.internal.ground')
local Stepper = require('systems.internal.stepper')
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
---@field package stepper MoonwellSystems.Stepper
---@field package group group? One reused group for every query.
---@field package units unit[] The contacts of the missile being advanced, by fraction.
---@field package fractions number[]
---@field package disposed boolean
local Missiles = {}
Missiles.__index = Missiles

---@alias MoonwellSystems.MissileEnd 'hit-limit'|'expired'|'range'|'ground'|'cancelled'|'disposed'|'error'

---@class MoonwellSystems.MissileOptions
---@field clock MoonwellSystems.Scheduler Drives the missiles; they move once per scheduler step.
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

local OPTIONS = {
    clock = {Fields.class(Scheduler, 'a Scheduler'), required = true},
    onError = {'function'},
    terrain = {'boolean', default = true},
    targetOffset = {'finite', default = 50},
    maxTargetRadius = {'nonNegative', default = 128},
}

local function liveEffect(value) return getmetatable(value) == Effect and not value:isDisposed() end

local LAUNCH = {
    x = {'finite', required = true},
    y = {'finite', required = true},
    height = {'finite', default = 60},
    vx = {'finite', required = true},
    vy = {'finite', required = true},
    vz = {'finite', default = 0},
    ax = {'finite', default = 0},
    ay = {'finite', default = 0},
    az = {'finite', default = 0},
    radius = {'nonNegative', required = true},
    lifetime = {'positive', required = true},
    maxRange = {'positive'},
    maxHits = {Fields.integer(1), default = 1},
    followGround = {'boolean', default = false},
    model = {'string'},
    effect = {Fields.test(liveEffect, 'a live Effect')},
    scale = {'finite'},
    face = {'boolean', default = true},
    filter = {'function'},
    steer = {'function'},
    onHit = {'function'},
    onEnd = {'function'},
    data = {'any'},
}

---The rules that join two keys, after Fields.request. Nil when they hold.
---@param r table
---@return string?
local function joined(r)
    if not Check.finite(r.vx * r.vx + r.vy * r.vy + r.vz * r.vz) then
        return "'vx', 'vy' and 'vz' expected a finite speed"
    end
    if not Check.finite(r.ax * r.ax + r.ay * r.ay + r.az * r.az) then
        return "'ax', 'ay' and 'az' expected a finite acceleration"
    end
    if r.followGround and (r.vz ~= 0 or r.az ~= 0) then return "'followGround' cannot be used with 'vz' or 'az'" end
    if r.model ~= nil and r.effect ~= nil then return "'effect' cannot be given with 'model'" end
    if r.scale ~= nil and r.model == nil then return "'scale' needs 'model'" end
    return nil
end

-- Ending

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
    system.stepper:settle()
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

---One step: advances the missiles that were in flight when it began, in launch order.
---@param system MoonwellSystems.Missiles
---@param dt number
local function tick(system, dt)
    local list = system.list
    for index = 1, #list do
        local missile = list[index]
        if missile.active then advance(system, missile, dt) end
    end
    if system.ended then
        local kept = {}
        for _, missile in ipairs(system.list) do
            if missile.active then kept[#kept + 1] = missile end
        end
        system.list, system.ended = kept, false
    end
end

-- Missiles

---@param options MoonwellSystems.MissileOptions
---@return MoonwellSystems.Missiles
function Missiles.new(options)
    local read = Fields.options(options, OPTIONS, 'Missiles.new')
    ---@type MoonwellSystems.Missiles
    local system = setmetatable({
        clock = read.clock, onError = read.onError, ground = read.terrain and Ground.new() or nil,
        targetOffset = read.targetOffset, maxTargetRadius = read.maxTargetRadius, list = {}, count = 0,
        ended = false, units = {}, fractions = {}, disposed = false,
    }, Missiles)
    system.stepper = Stepper.new(read.clock, function(dt) tick(system, dt) end,
        function() return system.count == 0 end)
    return system
end

---Launches a missile. It first moves on the next scheduler step.
---@param request MoonwellSystems.MissileRequest
---@return MoonwellSystems.Missile
function Missiles:launch(request)
    local system = Check.receiver(self, Missiles, 'Missiles', 'Missiles.launch')
    if system.disposed then error('[systems] Missiles.launch: the system is disposed', 2) end
    local r = Fields.request(request, LAUNCH, 'Missiles.launch', 'a missile request table')
    local problem = joined(r)
    if problem then error('[systems] Missiles.launch: ' .. problem, 2) end
    local x, y, above = r.x, r.y, r.height
    local ground = system.ground
    local z = (ground and height(ground, x, y) or 0) + above
    local vx, vy, vz = r.vx, r.vy, r.vz
    local effect = r.effect
    if r.model then
        local ok, created = pcall(Effect.create, r.model, x, y)
        if not ok then
            error('[systems] Missiles.launch: ' .. Callback.reason(created), 2)
        end
        effect = created
        if r.scale then effect:setScale(r.scale) end
    end
    local face = r.face
    local yaw, pitch = 0, 0
    if effect then
        effect:setPosition(x, y, z)
        if face and (vx ~= 0 or vy ~= 0 or vz ~= 0) then
            yaw, pitch = orientation(vx, vy, vz)
            -- The wrapper takes degrees; `show` calls the native, which takes these radians.
            effect:setOrientation(math.deg(yaw), math.deg(pitch), 0)
        end
    end
    ---@type MoonwellSystems.Missile
    local missile = setmetatable({
        data = r.data, system = system, active = true, x = x, y = y, z = z, vx = vx, vy = vy, vz = vz,
        ax = r.ax, ay = r.ay, az = r.az, radius = r.radius,
        lifetime = r.lifetime, maxRange = r.maxRange, maxHits = r.maxHits,
        followGround = r.followGround, height = above, effect = effect,
        raw = effect and effect:getHandle() or nil, face = face, yaw = yaw, pitch = pitch, filter = r.filter,
        steer = r.steer, onHit = r.onHit, onEnd = r.onEnd, age = 0, travelled = 0, hits = {},
        hitCount = 0,
    }, Missile)
    system.list[#system.list + 1] = missile
    system.count = system.count + 1
    system.stepper:wake()
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
    system.stepper:dispose()
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
