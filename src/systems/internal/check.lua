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

---A finite number with no fraction, of either subtype: the game may hand floats that hold whole numbers. Strings are
---refused (math.tointeger converts them on Lua 5.4).
---@param value unknown
---@return boolean
function Check.integer(value) return Check.finite(value) and math.floor(value --[[@as number]]) == value end

---@param value unknown
---@return boolean
function Check.positive(value) return Check.finite(value) and value > 0 end

---@param value unknown
---@return boolean
function Check.nonNegative(value) return Check.finite(value) and value >= 0 end

---1 to 32 letters, digits, `-` or `_`: sync prefixes, save folders and slots.
---@param value unknown
---@return boolean
function Check.identifier(value)
    return type(value) == 'string' and #value >= 1 and #value <= 32 and value:find('^[A-Za-z0-9_-]+$') ~= nil
end

---A wrappers Unit (its class passed in, so this module requires nothing) that is not disposed.
---@param value unknown
---@param Unit table
---@return boolean
function Check.liveUnit(value, Unit) return getmetatable(value) == Unit and not value:isDisposed() end

return Check

