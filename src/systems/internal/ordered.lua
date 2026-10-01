---An insertion-ordered map for keys that are handles or wrappers (spec Part 1 §4.4): never iterate those with pairs.
---Internal: its errors are programming errors and use plain Lua messages.
---@class MoonwellSystems.Ordered
---@field package order any[] Keys in insertion order; HOLE marks a deleted key until compaction.
---@field package values table<any, any>
---@field package positions table<any, integer>
---@field package count integer
---@field package holes integer
---@field package iterating integer Running each() calls; compaction waits until none runs.
local Ordered = {}
Ordered.__index = Ordered

local HOLE = setmetatable({}, {__tostring = function() return '<deleted>' end})

---@return MoonwellSystems.Ordered
function Ordered.new()
    return setmetatable({order = {}, values = {}, positions = {}, count = 0, holes = 0, iterating = 0}, Ordered)
end

---Drops the holes once they outnumber the live keys, so deleting stays O(1) amortized.
---@param map MoonwellSystems.Ordered
local function compact(map)
    if map.iterating > 0 or map.holes * 2 <= #map.order then return end
    local order = {}
    for _, key in ipairs(map.order) do
        if key ~= HOLE then
            order[#order + 1] = key
            map.positions[key] = #order
        end
    end
    map.order, map.holes = order, 0
end

---A new key goes last; an existing key keeps its place.
---@param key any
---@param value any
function Ordered:set(key, value)
    if key == nil or value == nil then error('Ordered.set: key and value must not be nil', 2) end
    if self.positions[key] == nil then
        self.order[#self.order + 1] = key
        self.positions[key] = #self.order
        self.count = self.count + 1
    end
    self.values[key] = value
end

---@param key any
---@return any
function Ordered:get(key) return self.values[key] end
---@param key any
---@return boolean
function Ordered:has(key) return self.positions[key] ~= nil end
---@return integer
function Ordered:getSize() return self.count end

---@param key any
---@return boolean deleted
function Ordered:delete(key)
    local position = self.positions[key]
    if position == nil then return false end
    self.order[position] = HOLE
    self.positions[key], self.values[key] = nil, nil
    self.count, self.holes = self.count - 1, self.holes + 1
    compact(self)
    return true
end

---The keys in insertion order, as a new array.
---@return any[]
function Ordered:keys()
    local keys = {}
    for _, key in ipairs(self.order) do
        if key ~= HOLE then keys[#keys + 1] = key end
    end
    return keys
end

---Calls fn(key, value) for the entries present at the start that are still present. Entries added during the call wait
---for the next one. An error in fn propagates after the map is restored.
---@param fn fun(key: any, value: any)
function Ordered:each(fn)
    self.iterating = self.iterating + 1
    local order, limit = self.order, #self.order
    local ok, err = pcall(function()
        for index = 1, limit do
            local key = order[index]
            -- The position check also skips a key deleted and added again: its new place is past the limit.
            if key ~= HOLE and self.positions[key] == index then fn(key, self.values[key]) end
        end
    end)
    self.iterating = self.iterating - 1
    compact(self)
    if not ok then error(err, 0) end
end

return Ordered
