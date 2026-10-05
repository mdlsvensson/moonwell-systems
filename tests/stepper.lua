local Stepper = require('systems.internal.stepper')
local Scheduler = require('systems.scheduler')

-- A pool of work: step() takes one item per step; idle() when none is left.
local function pool(clock, items)
    local steps = {}
    local stepper
    stepper = Stepper.new(clock, function(dt)
        steps[#steps + 1] = dt
        table.remove(items, 1)
    end, function() return #items == 0 end)
    return stepper, steps
end

test('wake schedules one task; it steps with the clock step and stops when idle', function()
    local clock = Scheduler.new(0.5)
    local items = {1, 2}
    local stepper, steps = pool(clock, items)
    stepper:wake(); stepper:wake()
    eq(clock:getPending(), 1)
    clock:advance(); eq(#steps, 1); eq(steps[1], 0.5); eq(clock:getPending(), 1)
    clock:advance(); eq(#steps, 2); eq(clock:getPending(), 0)
    clock:advance(); eq(#steps, 2)
end)

test('settle stops an idle stepper outside a step, and waits during one', function()
    local clock = Scheduler.new(1)
    local items = {1}
    local stepper
    local during
    stepper = Stepper.new(clock, function()
        items = {}
        during = stepper:isStepping()
        stepper:settle() -- inside the step: must not cancel yet
    end, function() return #items == 0 end)
    stepper:wake(); clock:advance()
    eq(during, true); eq(stepper:isStepping(), false); eq(clock:getPending(), 0)
    items = {1}; stepper:wake(); eq(clock:getPending(), 1)
    items = {}; stepper:settle(); eq(clock:getPending(), 0)
end)

test('a step that raises leaves the stepper ready to wake again', function()
    local clock = Scheduler.new(1, function() end)
    local raising = true
    local count = 0
    local stepper = Stepper.new(clock, function()
        count = count + 1
        if raising then error('step broke') end
    end, function() return false end)
    stepper:wake(); clock:advance()
    eq(count, 1); eq(stepper:isStepping(), false); eq(clock:getPending(), 0)
    raising = false
    stepper:wake(); clock:advance(); eq(count, 2); eq(clock:getPending(), 1)
    stepper:dispose(); eq(clock:getPending(), 0); stepper:dispose()
end)
