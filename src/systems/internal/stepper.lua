---Runs a step from a scheduler while anything is active (spec 2026-10-05 refactor §4.4): the shared driver of the
---missile and knockback systems. Internal: no argument checks.
---@class MoonwellSystems.Stepper
---@field package clock MoonwellSystems.Scheduler
---@field package step fun(dt: number)
---@field package idle fun(): boolean
---@field package cancel (fun())? The scheduler task; nil while nothing runs.
---@field package stepping boolean
local Stepper = {}
Stepper.__index = Stepper

---@param clock MoonwellSystems.Scheduler
---@param step fun(dt: number) Advances everything by one clock step.
---@param idle fun(): boolean Whether nothing is active.
---@return MoonwellSystems.Stepper
function Stepper.new(clock, step, idle)
    return setmetatable({clock = clock, step = step, idle = idle, stepping = false}, Stepper)
end

---@param stepper MoonwellSystems.Stepper
local function halt(stepper)
    local cancel = stepper.cancel
    if cancel then
        stepper.cancel = nil
        cancel()
    end
end

---@param stepper MoonwellSystems.Stepper
---@param dt number
local function run(stepper, dt)
    stepper.stepping = true
    local ok, failure = pcall(stepper.step, dt)
    stepper.stepping = false
    if not ok then
        -- The scheduler cancels a failing task: forget it, so the next wake schedules a new one.
        stepper.cancel = nil
        error(failure, 0)
    end
    if stepper.idle() then halt(stepper) end
end

---Schedules the step on every clock tick, unless it already is.
function Stepper:wake()
    if self.cancel then return end
    local dt = self.clock:getStep()
    self.cancel = self.clock:every(dt, function() run(self, dt) end)
end

---Stops the task when nothing is active; during a step, the step's end decides.
function Stepper:settle()
    if not self.stepping and self.idle() then halt(self) end
end

---@return boolean
function Stepper:isStepping() return self.stepping end

---Stops the task. Idempotent.
function Stepper:dispose() halt(self) end

return Stepper
