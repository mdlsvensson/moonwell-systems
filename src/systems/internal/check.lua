---Argument and receiver checks shared by the systems modules.
local Check = {}

---Returns `value` when its metatable is `class`; raises `expected <name>` at the public function's caller otherwise.
---@generic T
---@param value unknown
---@param class T
---@param name string
---@param operation string
---@param depth integer? Helper frames between the public function and this call.
---@return T
function Check.receiver(value, class, name, operation, depth)
    if getmetatable(value) ~= class then error('[systems] ' .. operation .. ': expected ' .. name, 3 + (depth or 0)) end
    return value
end

---True for a number that is neither NaN nor infinite. (In Warcraft's Lua NaN compares equal to itself, so NaN cannot be
---detected there; this check catches it everywhere else.)
---@param value unknown
---@return boolean
function Check.finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

return Check
