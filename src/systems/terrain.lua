local Check = require('systems.internal.check')
local Fields = require('systems.internal.fields')
local Ground = require('systems.internal.ground')

---Terrain queries: ground height, walkability and the world bounds. A Terrain owns one location, one hidden item and
---one rect, each created on first use; dispose() removes them.
---@class MoonwellSystems.Terrain
---@field package state MoonwellSystems.GroundState? Nil once disposed.
local Terrain = {}
Terrain.__index = Terrain

local OPTIONS = {itemType = {Fields.integer()}}

---@param options {itemType: integer?}? `itemType` is the item isClear places; default 'wolg', a standard item.
---@return MoonwellSystems.Terrain
function Terrain.new(options)
    local read = Fields.options(options, OPTIONS, 'Terrain.new')
    return setmetatable({state = Ground.new(read.itemType)}, Terrain)
end

---The live state of a query's receiver; raises at the public function's caller.
---@param self unknown
---@param operation string
---@param x unknown
---@param y unknown
---@return MoonwellSystems.GroundState
local function query(self, operation, x, y)
    local state = Check.receiver(self, Terrain, 'Terrain', operation, 1).state
    if not state then error('[systems] ' .. operation .. ': the terrain is disposed', 3) end
    if not Check.finite(x) or not Check.finite(y) then
        error('[systems] ' .. operation .. ': expected finite coordinates', 3)
    end
    return state
end

---The ground's absolute height (GetLocationZ). It follows temporary terrain deformations while they last.
---@param x number
---@param y number
---@return number
function Terrain:height(x, y)
    local state = query(self, 'Terrain.height', x, y)
    return Ground.height(state, x, y)
end

---In bounds and walkable terrain. It does not see trees or buildings: use isClear for those.
---@param x number
---@param y number
---@return boolean
function Terrain:isWalkable(x, y)
    local state = query(self, 'Terrain.isWalkable', x, y)
    return Ground.isWalkable(state, x, y)
end

---isWalkable, and no tree, building or other pathing blocker. It places a hidden item on the point and reads where it
---landed; visible items within 32 units are hidden for the check and shown again.
---@param x number
---@param y number
---@return boolean
function Terrain:isClear(x, y)
    local state = query(self, 'Terrain.isClear', x, y)
    return Ground.isClear(state, x, y)
end

---Inside the world bounds, 64 units from their edge. Moving a unit outside the world bounds can crash the game.
---@param x number
---@param y number
---@return boolean
function Terrain:inBounds(x, y)
    local state = query(self, 'Terrain.inBounds', x, y)
    return Ground.inBounds(state, x, y)
end

---Removes the owned handles. Queries afterwards raise. Idempotent.
function Terrain:dispose()
    local terrain = Check.receiver(self, Terrain, 'Terrain', 'Terrain.dispose')
    if not terrain.state then return end
    Ground.dispose(terrain.state)
    terrain.state = nil
end

return Terrain
