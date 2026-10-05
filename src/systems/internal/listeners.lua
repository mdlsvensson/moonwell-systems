---A prioritised listener list (spec 2026-10-05 refactor §4.3), copied when a listener is added or removed and never
---when it is called: a dispatch walks `current()`, which is never changed afterwards. Internal: no argument checks.
---@class MoonwellSystems.Listeners
---@field package cells MoonwellSystems.ListenerCell[]
---@field package ids {last: integer} Shared by the lists built with the same table.
local Listeners = {}
Listeners.__index = Listeners

---@class MoonwellSystems.ListenerCell
---@field id integer
---@field priority number
---@field callback function? Nil once removed.

---@param ids {last: integer}? An id sequence to share with other lists.
---@return MoonwellSystems.Listeners
function Listeners.new(ids) return setmetatable({cells = {}, ids = ids or {last = 0}}, Listeners) end

---Lower priority runs first; equal priorities keep the order added.
---@param callback function
---@param priority number
---@return fun() remove Idempotent.
function Listeners:add(callback, priority)
    local ids = self.ids
    ids.last = ids.last + 1
    ---@type MoonwellSystems.ListenerCell
    local cell = {id = ids.last, priority = priority, callback = callback}
    local list, copy, placed = self.cells, {}, false
    for index = 1, #list do
        if not placed and list[index].priority > priority then
            copy[#copy + 1] = cell
            placed = true
        end
        copy[#copy + 1] = list[index]
    end
    if not placed then copy[#copy + 1] = cell end
    self.cells = copy
    return function()
        if not cell.callback then return end
        cell.callback = nil
        local kept = {}
        for _, other in ipairs(self.cells) do
            if other ~= cell then kept[#kept + 1] = other end
        end
        self.cells = kept
    end
end

---The array to dispatch over. Skip cells whose callback is nil.
---@return MoonwellSystems.ListenerCell[]
function Listeners:current() return self.cells end

---@return integer
function Listeners:getCount() return #self.cells end

---The id of the newest listener of the shared sequence.
---@return integer
function Listeners:getLastId() return self.ids.last end

---Removes every listener.
function Listeners:clear()
    for _, cell in ipairs(self.cells) do cell.callback = nil end
    self.cells = {}
end

return Listeners
