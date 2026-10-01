---Terrain sampling without argument checks, for the per-tick loops (spec 2026-10-01 release 4 §3 and §5). A state
---table owns the handles, each created on first use. systems.terrain is the checked public version. Raw natives by
---design (Part 1 §3): there is no wrapper for a location, and these run per missile and per knockback every tick.
local Ground = {}

---@class MoonwellSystems.GroundState
---@field itemType integer
---@field location location?
---@field item item? The hidden probe item of isClear.
---@field rect rect? Moved around the point to find other items.
---@field hide (fun(): ...)? The enumeration callback that hides them.
---@field hidden item[] The items hidden for the running check.
---@field count integer
---@field minX number? The world bounds, shrunk by MARGIN; nil until first read.
---@field minY number
---@field maxX number
---@field maxY number

local WAND = 2003790951 -- 'wolg', a standard item: no object data is needed
local MARGIN = 64       -- SetUnitX outside the world bounds can crash the game: stay this far inside
local NEAR = 32         -- other items this close would displace the probe item
local TOLERANCE = 100   -- the probe item landing within 10 units (squared) counts as "stayed"

---@param itemType integer?
---@return MoonwellSystems.GroundState
function Ground.new(itemType)
    return {itemType = itemType or WAND, hidden = {}, count = 0, minY = 0, maxX = 0, maxY = 0}
end

---The ground's absolute height.
---@param state MoonwellSystems.GroundState
---@param x number
---@param y number
---@return number
function Ground.height(state, x, y)
    local location = state.location
    if location then
        MoveLocation(location, x, y)
    else
        location = Location(x, y)
        state.location = location
    end
    return GetLocationZ(location)
end

---@param state MoonwellSystems.GroundState
---@param x number
---@param y number
---@return boolean
function Ground.inBounds(state, x, y)
    local minX = state.minX
    if not minX then
        local world = GetWorldBounds()
        minX = GetRectMinX(world) + MARGIN
        state.minX, state.minY = minX, GetRectMinY(world) + MARGIN
        state.maxX, state.maxY = GetRectMaxX(world) - MARGIN, GetRectMaxY(world) - MARGIN
        RemoveRect(world)
    end
    return x >= minX and x <= state.maxX and y >= state.minY and y <= state.maxY
end

---In bounds and walkable terrain. It does not see trees or buildings (measured on 3.0.0.24268).
---@param state MoonwellSystems.GroundState
---@param x number
---@param y number
---@return boolean
function Ground.isWalkable(state, x, y)
    -- Warcraft's name is inverted: IsTerrainPathable returns true when the point is NOT pathable.
    return Ground.inBounds(state, x, y) and not IsTerrainPathable(x, y, PATHING_TYPE_WALKABILITY)
end

---isWalkable, and no tree, building or other pathing blocker: an item placed on a blocked point lands elsewhere.
---@param state MoonwellSystems.GroundState
---@param x number
---@param y number
---@return boolean
function Ground.isClear(state, x, y)
    if not Ground.isWalkable(state, x, y) then return false end
    local item, rect, hidden = state.item, state.rect, state.hidden
    if not item or not rect then
        item = CreateItem(state.itemType, x, y)
        rect = Rect(0, 0, 0, 0)
        state.item, state.rect = item, rect
        local probe = item
        state.hide = function()
            local found = GetEnumItem()
            if found ~= probe and IsItemVisible(found) then
                state.count = state.count + 1
                hidden[state.count] = found
                SetItemVisible(found, false)
            end
        end
    end
    -- Other items would displace the probe item as a tree does: hide the visible ones nearby for the check.
    SetRect(rect, x - NEAR, y - NEAR, x + NEAR, y + NEAR)
    state.count = 0
    -- Warcraft accepts a null filter; the generated JASS signature cannot express that.
    ---@diagnostic disable-next-line: param-type-mismatch
    EnumItemsInRect(rect, nil, state.hide)
    SetItemVisible(item, true)
    SetItemPosition(item, x, y)
    local dx, dy = GetItemX(item) - x, GetItemY(item) - y
    SetItemVisible(item, false)
    for index = 1, state.count do
        SetItemVisible(hidden[index], true)
        hidden[index] = nil
    end
    return dx * dx + dy * dy <= TOLERANCE
end

---Removes the owned handles. Idempotent; a later call creates them again.
---@param state MoonwellSystems.GroundState
function Ground.dispose(state)
    if state.location then RemoveLocation(state.location); state.location = nil end
    if state.item then RemoveItem(state.item); state.item = nil end
    if state.rect then RemoveRect(state.rect); state.rect = nil end
    state.hide = nil
end

return Ground
