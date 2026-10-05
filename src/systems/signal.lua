local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Fields = require('systems.internal.fields')
local Listeners = require('systems.internal.listeners')

---An event with prioritized listeners. Lower priority runs first; equal priorities keep subscription order. Each
---listener runs behind the callback boundary.
---@class MoonwellSystems.Signal
---@field package listeners MoonwellSystems.Listeners
---@field package onError (fun(message: string): ...)?
---@field package disposed boolean
local Signal = {}
Signal.__index = Signal

---@class MoonwellSystems.SignalOptions
---@field onError (fun(message: string): ...)? Receives listener failures; default prints them.

local OPTIONS = {onError = {'function'}}

---@param options MoonwellSystems.SignalOptions?
---@return MoonwellSystems.Signal
function Signal.new(options)
    local read = Fields.options(options, OPTIONS, 'Signal.new')
    return setmetatable({listeners = Listeners.new(), onError = read.onError, disposed = false}, Signal)
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
    local unsubscribe = signal.listeners:add(callback, priority)
    return unsubscribe
end

---Calls every listener with the arguments. Listeners added during the call wait for the next one; removed ones are
---skipped at once.
---@param ... any
function Signal:emit(...)
    local signal = Check.receiver(self, Signal, 'Signal', 'Signal.emit')
    local cells = signal.listeners:current()
    for index = 1, #cells do
        local callback = cells[index].callback
        if callback then Callback.call('Signal listener', signal.onError, callback, ...) end
    end
end

---@return integer
function Signal:getCount() return Check.receiver(self, Signal, 'Signal', 'Signal.getCount').listeners:getCount() end

---Removes every listener. Subscribing afterwards raises; emitting does nothing. Idempotent.
function Signal:dispose()
    local signal = Check.receiver(self, Signal, 'Signal', 'Signal.dispose')
    if signal.disposed then return end
    signal.disposed = true
    signal.listeners:clear()
end

return Signal
