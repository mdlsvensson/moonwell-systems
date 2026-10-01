---The callback boundary (spec 2026-09-30 moonwell-systems §4.3): a copy of the wrappers' one, so no library reaches
---into another's internals. Nothing is rethrown: an error rethrown inside a timer or trigger callback is silent in
---game.
local Callback = {}

---@param value unknown
---@param operation string
---@param depth integer? Helper frames between the public function and this call.
function Callback.check(value, operation, depth)
    if type(value) ~= 'function' then
        error('[systems] ' .. operation .. ': expected a callback function', 3 + (depth or 0))
    end
end

---Accepts nil or a function.
---@param value unknown
---@param operation string
---@param depth integer?
function Callback.optional(value, operation, depth)
    if value ~= nil and type(value) ~= 'function' then
        error('[systems] ' .. operation .. ': expected a callback function', 3 + (depth or 0))
    end
end

---@param message unknown
---@return string
local function text(message)
    local printable, result = pcall(tostring, message)
    return printable and result or '<unprintable error>'
end

---Reports a failure: to `onError(message)`, itself behind the boundary, or printed as
---`[systems] <label> failed: <message>`.
---@param label string
---@param onError (fun(message: string): ...)?
---@param message unknown
function Callback.report(label, onError, message)
    local reported = text(message)
    if onError then
        local handled, failure = pcall(onError, reported)
        if handled then return end
        print('[systems] ' .. label .. ' error handler failed: ' .. text(failure))
    end
    print('[systems] ' .. label .. ' failed: ' .. reported)
end

---Runs `fn(...)` behind the boundary and reports a failure (see report).
---@param label string
---@param onError (fun(message: string): ...)?
---@param fn function
---@param ... any
---@return boolean succeeded
function Callback.call(label, onError, fn, ...)
    local ok, message = pcall(fn, ...)
    if ok then return true end
    Callback.report(label, onError, message)
    return false
end

return Callback
