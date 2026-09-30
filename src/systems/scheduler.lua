local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Timer = require('wrappers.timer')

---A deterministic fixed-step clock. Delays round up to whole ticks (at least one), and tasks due on the same tick run
---in creation order. Pure: drive it with `advance()`, or with `start()` in a map.
---@class MoonwellSystems.Scheduler
---@field package step number
---@field package onError fun(message: string)?
---@field package heap MoonwellSystems.SchedulerTask[]
---@field package tick integer
---@field package sequence integer
---@field package advancing boolean
---@field package disposed boolean
---@field package timer MoonwellWrappers.Timer?
local Scheduler = {}
Scheduler.__index = Scheduler

---@class MoonwellSystems.SchedulerTask
---@field due integer
---@field order integer Creation sequence; breaks ties between equal deadlines.
---@field interval integer 0 for a one-shot task.
---@field callback function? Nil once cancelled or run.
---@field index integer Position in the heap, or 0 once removed.

---Absorbs single-precision error in seconds / step: 0.07 / 0.01 lands slightly above 7.
local EPSILON = 1e-4

local function earlier(a, b) return a.due < b.due or (a.due == b.due and a.order < b.order) end

---Moves the task at `index` toward the root. Returns whether it moved.
local function up(heap, index)
    local task, moved = heap[index], false
    while index > 1 do
        local parentIndex = index // 2
        local parent = heap[parentIndex]
        if not earlier(task, parent) then break end
        heap[index] = parent; parent.index = index
        index = parentIndex; moved = true
    end
    heap[index] = task; task.index = index
    return moved
end

---Moves the task at `index` toward the leaves.
local function down(heap, index)
    local task, size = heap[index], #heap
    while true do
        local left = index * 2
        if left > size then break end
        local right = left + 1
        local child = (right <= size and earlier(heap[right], heap[left])) and right or left
        if not earlier(heap[child], task) then break end
        heap[index] = heap[child]; heap[index].index = index
        index = child
    end
    heap[index] = task; task.index = index
end

local function sift(heap, index)
    if not up(heap, index) then down(heap, index) end
end

---Idempotent: removing twice, or after the task ran, does nothing.
local function remove(heap, task)
    task.callback = nil
    local index = task.index
    if index == 0 then return end
    task.index = 0
    local last = heap[#heap]
    heap[#heap] = nil
    if last == task then return end
    heap[index] = last; last.index = index
    sift(heap, index)
end

local function validDelay(seconds) return Check.finite(seconds) and seconds >= 0 end
local function toTicks(step, seconds) return math.max(1, math.ceil(seconds / step - EPSILON)) end

---@param stepSeconds number? Seconds per tick; finite and positive. Default 1/32, a 0.03125 s Warcraft timer.
---@param onError fun(message: string)? Receives task failures; default prints them.
---@return MoonwellSystems.Scheduler
function Scheduler.new(stepSeconds, onError)
    if stepSeconds == nil then stepSeconds = 1 / 32 end
    if not Check.finite(stepSeconds) or stepSeconds <= 0 then
        error('[systems] Scheduler.new: expected a finite positive step', 2)
    end
    Callback.optional(onError, 'Scheduler.new')
    return setmetatable({step = stepSeconds, onError = onError, heap = {}, tick = 0, sequence = 0, advancing = false,
        disposed = false}, Scheduler)
end

---@param self unknown
---@param seconds unknown
---@param callback unknown
---@param repeating boolean
---@param operation string
---@return fun()
local function schedule(self, seconds, callback, repeating, operation)
    local scheduler = Check.receiver(self, Scheduler, 'Scheduler', operation, 1)
    if scheduler.disposed then error('[systems] ' .. operation .. ': the scheduler is disposed', 3) end
    if repeating then
        if not Check.finite(seconds) or seconds <= 0 then
            error('[systems] ' .. operation .. ': expected a finite positive interval', 3)
        end
    elseif not validDelay(seconds) then
        error('[systems] ' .. operation .. ': expected a finite non-negative delay', 3)
    end
    Callback.check(callback, operation, 1)
    local ticks = toTicks(scheduler.step, seconds)
    scheduler.sequence = scheduler.sequence + 1
    ---@type MoonwellSystems.SchedulerTask
    local task = {due = scheduler.tick + ticks, order = scheduler.sequence, interval = repeating and ticks or 0,
        callback = callback, index = 0}
    local heap = scheduler.heap
    heap[#heap + 1] = task
    up(heap, #heap)
    return function() remove(scheduler.heap, task) end
end

---Runs `callback` once, `seconds` from now (rounded up to whole ticks, at least one).
---@param seconds number
---@param callback fun()
---@return fun() cancel Idempotent.
function Scheduler:after(seconds, callback) return (schedule(self, seconds, callback, false, 'Scheduler.after')) end

---Runs `callback` every `seconds` (rounded up to whole ticks), starting one interval from now. A repeating task that
---fails is cancelled.
---@param seconds number
---@param callback fun()
---@return fun() cancel Idempotent.
function Scheduler:every(seconds, callback) return (schedule(self, seconds, callback, true, 'Scheduler.every')) end

---Advances one tick and runs every task now due, in (due tick, creation order). Tasks scheduled during the tick are due
---at least one tick later. A failing task is cancelled and reported.
function Scheduler:advance()
    local scheduler = Check.receiver(self, Scheduler, 'Scheduler', 'Scheduler.advance')
    if scheduler.disposed then return end
    if scheduler.advancing then error('[systems] Scheduler.advance: cannot advance during a tick', 2) end
    scheduler.advancing = true
    scheduler.tick = scheduler.tick + 1
    while true do
        local heap = scheduler.heap
        local task = heap[1]
        if not task or task.due > scheduler.tick then break end
        local callback = task.callback
        if task.interval == 0 then
            remove(heap, task)
        else
            task.due = scheduler.tick + task.interval
            sift(heap, 1)
        end
        if not Callback.call('Scheduler task', scheduler.onError, callback) then remove(scheduler.heap, task) end
    end
    scheduler.advancing = false
end

---@return integer
function Scheduler:getTick() return Check.receiver(self, Scheduler, 'Scheduler', 'Scheduler.getTick').tick end
---Simulated seconds so far: getTick() * the step.
---@return number
function Scheduler:getElapsed()
    local scheduler = Check.receiver(self, Scheduler, 'Scheduler', 'Scheduler.getElapsed')
    return scheduler.tick * scheduler.step
end
---Tasks that have not run or been cancelled.
---@return integer
function Scheduler:getPending() return #Check.receiver(self, Scheduler, 'Scheduler', 'Scheduler.getPending').heap end
---@return number
function Scheduler:getStep() return Check.receiver(self, Scheduler, 'Scheduler', 'Scheduler.getStep').step end

---Whole ticks a delay occupies under this scheduler's rounding.
---@param seconds number
---@return integer
function Scheduler:ticks(seconds)
    local scheduler = Check.receiver(self, Scheduler, 'Scheduler', 'Scheduler.ticks')
    if not validDelay(seconds) then error('[systems] Scheduler.ticks: expected a finite non-negative delay', 2) end
    return toTicks(scheduler.step, seconds)
end

---Destroys `timer` if it is still the scheduler's; a stale stop function does nothing.
local function stopTimer(scheduler, timer)
    if scheduler.timer ~= timer then return end
    scheduler.timer = nil
    timer:destroy()
end

---Drives `advance()` from one periodic wrappers Timer with this scheduler's step. Importing the module creates nothing.
---@return fun() stop Destroys the timer; idempotent.
function Scheduler:start()
    local scheduler = Check.receiver(self, Scheduler, 'Scheduler', 'Scheduler.start')
    if scheduler.disposed then error('[systems] Scheduler.start: the scheduler is disposed', 2) end
    if scheduler.timer then error('[systems] Scheduler.start: already started', 2) end
    local timer = Timer.create()
    scheduler.timer = timer
    timer:start(scheduler.step, true, function() scheduler:advance() end)
    return function() stopTimer(scheduler, timer) end
end

---Cancels every task and stops the timer. Scheduling afterwards raises; advancing does nothing. Idempotent.
function Scheduler:dispose()
    local scheduler = Check.receiver(self, Scheduler, 'Scheduler', 'Scheduler.dispose')
    if scheduler.disposed then return end
    scheduler.disposed = true
    for _, task in ipairs(scheduler.heap) do task.callback = nil; task.index = 0 end
    scheduler.heap = {}
    if scheduler.timer then stopTimer(scheduler, scheduler.timer) end
end

return Scheduler
