local Check = require('systems.internal.check')

---Declarative checks for options and request tables (spec 2026-10-05 refactor §4.2). A spec maps each key to
---`{kind, default = value?, required = true?}`. Errors point at the public function's caller; `depth` counts helper
---frames in between. Keys are checked in sorted order, so every machine reports the same first error.
local Fields = {}

---@alias MoonwellSystems.FieldKind {[1]: fun(value: unknown): boolean, [2]: string}
---@alias MoonwellSystems.FieldSpec table<string, table>

local function isBoolean(value) return type(value) == 'boolean' end
local function isFunction(value) return type(value) == 'function' end
local function isString(value) return type(value) == 'string' and value ~= '' end
local function anything() return true end

---@type table<string, MoonwellSystems.FieldKind>
local KINDS = {
    finite = {Check.finite, 'a finite number'},
    positive = {Check.positive, 'a finite positive number'},
    nonNegative = {Check.nonNegative, 'a finite non-negative number'},
    boolean = {isBoolean, 'true or false'},
    ['function'] = {isFunction, 'a function'},
    string = {isString, 'a non-empty string'},
    identifier = {Check.identifier, '1 to 32 letters, digits, - or _'},
    any = {anything, 'a value'},
}

---A whole number (an integral float counts), optionally bounded.
---@param min integer?
---@param max integer?
---@return MoonwellSystems.FieldKind
function Fields.integer(min, max)
    local description = 'a whole number'
    if min and max then
        description = description .. ' from ' .. min .. ' to ' .. max
    elseif min then
        description = description .. ' of at least ' .. min
    end
    return {function(value)
        return Check.integer(value) and (min == nil or value >= min) and (max == nil or value <= max)
    end, description}
end

---One of the given strings.
---@param values string[]
---@return MoonwellSystems.FieldKind
function Fields.enum(values)
    local set, shown = {}, {}
    for index, value in ipairs(values) do
        set[value] = true
        shown[index] = "'" .. value .. "'"
    end
    return {function(value) return set[value] == true end, 'one of ' .. table.concat(shown, ', ')}
end

---An instance of `class` (its metatable).
---@param class table
---@param description string For example 'a Scheduler'.
---@return MoonwellSystems.FieldKind
function Fields.class(class, description)
    return {function(value) return getmetatable(value) == class end, description}
end

---Any rule as a predicate.
---@param predicate fun(value: unknown): boolean
---@param description string
---@return MoonwellSystems.FieldKind
function Fields.test(predicate, description) return {predicate, description} end

---Sorted key names, once per spec table.
local orders = setmetatable({}, {__mode = 'k'})
---@param spec MoonwellSystems.FieldSpec
---@return string[]
local function namesOf(spec)
    local names = orders[spec]
    if names == nil then
        names = {}
        for name in pairs(spec) do names[#names + 1] = name end
        table.sort(names)
        orders[spec] = names
    end
    return names
end

---The first key of `value`, in sorted order as text, that `keys` does not define; nil when there is none.
---@param value table
---@param keys table
---@return string?
function Fields.unknown(value, keys)
    local first
    for key in pairs(value) do
        if keys[key] == nil then
            local shown = tostring(key)
            if first == nil or shown < first then first = shown end
        end
    end
    return first
end

---@param value table
---@param spec MoonwellSystems.FieldSpec
---@param operation string
---@param open boolean
---@param level integer The level of the public function's caller, counted from this function.
---@return table
local function read(value, spec, operation, open, level)
    if not open then
        local key = Fields.unknown(value, spec)
        if key then error('[systems] ' .. operation .. ": unknown key '" .. key .. "'", level) end
    end
    local result = {}
    for _, name in ipairs(namesOf(spec)) do
        local entry = spec[name]
        local kind = entry[1]
        if type(kind) == 'string' then kind = KINDS[kind] end
        local given = value[name]
        if given == nil then given = entry.default end
        if (given == nil and entry.required) or (given ~= nil and not kind[1](given)) then
            error('[systems] ' .. operation .. ": '" .. name .. "' expected " .. kind[2], level)
        end
        result[name] = given
    end
    return result
end

---Reads an options table: nil reads as {}. A table with a metatable is refused, so an old positional call
---(`X.new(clock)`) gets "expected an options table".
---@param value unknown
---@param spec MoonwellSystems.FieldSpec
---@param operation string
---@param depth integer?
---@return table<string, any>
function Fields.options(value, spec, operation, depth)
    depth = depth or 0
    if value == nil then value = {} end
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        error('[systems] ' .. operation .. ': expected an options table', 3 + depth)
    end
    local result = read(value, spec, operation, false, 4 + depth)
    return result
end

---Reads a request or definition table; nil is refused. With `open`, unknown keys and a metatable are allowed.
---@param value unknown
---@param spec MoonwellSystems.FieldSpec
---@param operation string
---@param what string What the table is, after "expected ", for example 'a missile request table'.
---@param depth integer?
---@param open boolean?
---@return table<string, any>
function Fields.request(value, spec, operation, what, depth, open)
    depth = depth or 0
    if type(value) ~= 'table' or (not open and getmetatable(value) ~= nil) then
        error('[systems] ' .. operation .. ': expected ' .. what, 3 + depth)
    end
    local result = read(value, spec, operation, open == true, 4 + depth)
    return result
end

return Fields
