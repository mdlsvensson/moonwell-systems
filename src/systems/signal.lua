local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')

---An event with prioritized listeners. Lower priority runs first; equal priorities keep subscription order. Each
---listener runs behind the callback boundary.
---@class MoonwellSystems.Signal
---@field package listeners MoonwellSystems.SignalListener[]
---@field package onError fun(message: string)?
---@field package disposed boolean
local Signal = {}
Signal.__index = Signal

---@class MoonwellSystems.SignalListener
---@field priority number
---@field callback function? Nil once unsubscribed.

---@param onError fun(message: string)? Receives listener failures; default prints them.
---@return MoonwellSystems.Signal
function Signal.new(onError)
    Callback.optional(onError, 'Signal.new')
    return setmetatable({listeners = {}, onError = onError, disposed = false}, Signal)
end

---Adds a listener. Lower `priority` runs first; equal priorities keep subscription order.
---@param callback fun(...: any): any
---@param priority number? Default 0.
---@return fun() unsubscribe Idempotent.
function Signal:subscribe(callback, priority)
    local signal = Check.receiver(self, Signal, 'Signal', 'Signal.subscribe')
    if signal.disposed then error('[systems] Signal.subscribe: the signal is disposed', 2) end
    Callback.check(callback, 'Signal.subscribe')
    if priority == nil then priority = 0 end
    if not Check.finite(priority) then error('[systems] Signal.subscribe: expected a finite priority', 2) end
    ---@type MoonwellSystems.SignalListener
    local listener = {priority = priority, callback = callback}
    local list = signal.listeners
    local position = #list + 1
    for index = 1, #list do
        if list[index].priority > priority then position = index; break end
    end
    table.insert(list, position, listener)
    return function()
        listener.callback = nil
        local current = signal.listeners
        for index = 1, #current do
            if current[index] == listener then table.remove(current, index); return end
        end
    end
end

---Calls every listener with the arguments. Listeners added during the call wait for the next one; removed ones are
---skipped at once.
---@param ... any
function Signal:emit(...)
    local signal = Check.receiver(self, Signal, 'Signal', 'Signal.emit')
    local list = signal.listeners
    local snapshot = table.move(list, 1, #list, 1, {})
    for index = 1, #snapshot do
        local callback = snapshot[index].callback
        if callback then Callback.call('Signal listener', signal.onError, callback, ...) end
    end
end

---@return integer
function Signal:getCount() return #Check.receiver(self, Signal, 'Signal', 'Signal.getCount').listeners end

---Removes every listener. Subscribing afterwards raises; emitting does nothing. Idempotent.
function Signal:dispose()
    local signal = Check.receiver(self, Signal, 'Signal', 'Signal.dispose')
    signal.disposed = true
    for _, listener in ipairs(signal.listeners) do listener.callback = nil end
    signal.listeners = {}
end

return Signal
