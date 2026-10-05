PATHING_TYPE_WALKABILITY = {}
-- The world: a ground function, unwalkable terrain, obstacles the terrain check misses, and items on the ground.
local ground = function() return 0 end
local unwalkable = function() return false end
local obstacle = function() return false end
local items, enumerated = {}, nil

native('Location', function(x, y) return {x = x, y = y} end)
native('MoveLocation', function(location, x, y) location.x, location.y = x, y end)
native('GetLocationZ', function(location) return ground(location.x, location.y) end)
native('RemoveLocation', function() end)
native('GetWorldBounds', function() return {minX = -1000, minY = -500, maxX = 1000, maxY = 500} end)
native('GetRectMinX', function(rect) return rect.minX end)
native('GetRectMinY', function(rect) return rect.minY end)
native('GetRectMaxX', function(rect) return rect.maxX end)
native('GetRectMaxY', function(rect) return rect.maxY end)
native('Rect', function(minX, minY, maxX, maxY) return {minX = minX, minY = minY, maxX = maxX, maxY = maxY} end)
native('SetRect', function(rect, minX, minY, maxX, maxY)
    rect.minX, rect.minY, rect.maxX, rect.maxY = minX, minY, maxX, maxY
end)
native('RemoveRect', function() end)
native('IsTerrainPathable', function(x, y) return unwalkable(x, y) end)
native('CreateItem', function(itemType, x, y)
    local item = {itemType = itemType, x = x, y = y, visible = true}
    items[#items + 1] = item
    return item
end)
-- Placing an item shows it; an obstacle, or another visible item on the spot, displaces it.
native('SetItemPosition', function(item, x, y)
    item.visible = true
    local displaced = obstacle(x, y)
    for _, other in ipairs(items) do
        if other ~= item and other.visible and math.abs(other.x - x) < 16 and math.abs(other.y - y) < 16 then
            displaced = true
        end
    end
    item.x, item.y = displaced and x + 80 or x, y
end)
native('GetItemX', function(item) return item.x end)
native('GetItemY', function(item) return item.y end)
native('SetItemVisible', function(item, flag) item.visible = flag end)
native('IsItemVisible', function(item) return item.visible end)
native('EnumItemsInRect', function(rect, _, callback)
    for _, item in ipairs(items) do
        if item.x >= rect.minX and item.x <= rect.maxX and item.y >= rect.minY and item.y <= rect.maxY then
            enumerated = item
            callback()
        end
    end
end)
native('GetEnumItem', function() return enumerated end)
native('RemoveItem', function(item) item.removed = true end)
local Terrain = require('systems.terrain')
eq(totalCalls(), 0)

local function reset()
    ground, unwalkable, obstacle = function() return 0 end, function() return false end, function() return false end
    items = {}
    resetCalls()
end

test('nothing is created until first use; height reads the ground through one location', function()
    reset()
    local terrain = Terrain.new()
    eq(totalCalls(), 0)
    ground = function(x, y) return x + y end
    eq(terrain:height(3, 4), 7); eq(terrain:height(10, 20), 30)
    eq(callCount('Location'), 1); eq(callCount('MoveLocation'), 1)
end)

test('inBounds keeps 64 units from the world edge; isWalkable adds the terrain', function()
    reset()
    local terrain = Terrain.new()
    eq(terrain:inBounds(936, 0), true); eq(terrain:inBounds(937, 0), false)
    eq(terrain:inBounds(-936, -436), true); eq(terrain:inBounds(0, -437), false); eq(terrain:inBounds(0, 437), false)
    eq(callCount('GetWorldBounds'), 1); eq(callCount('RemoveRect'), 1)
    unwalkable = function(x) return x > 100 end
    eq(terrain:isWalkable(100, 0), true); eq(terrain:isWalkable(101, 0), false)
    resetCalls()
    eq(terrain:isWalkable(2000, 0), false)
    eq(callCount('IsTerrainPathable'), 0) -- out of bounds: the terrain is not asked
    eq(callCount('GetWorldBounds'), 0)    -- the bounds were read once
end)

test('isClear sees obstacles the terrain check misses, with one hidden item', function()
    reset()
    local terrain = Terrain.new()
    obstacle = function(x) return x >= 40 and x <= 60 end
    eq(terrain:isWalkable(50, 0), true)
    eq(terrain:isClear(50, 0), false); eq(terrain:isClear(0, 0), true); eq(terrain:isClear(61, 0), true)
    eq(callCount('CreateItem'), 1); eq(callCount('Rect'), 1)
    eq(items[1].itemType, 2003790951); eq(items[1].visible, false)
    unwalkable = function() return true end
    resetCalls()
    eq(terrain:isClear(0, 0), false)
    eq(callCount('SetItemPosition'), 0) -- unwalkable terrain: no item is placed
    reset()
    Terrain.new({itemType = 1885889889}):isClear(0, 0)
    eq(items[1].itemType, 1885889889)
end)

test('isClear hides the visible items nearby for the check and shows them again', function()
    reset()
    local lying = CreateItem(1, 5, 5)
    local stowed = CreateItem(1, -5, 5)
    stowed.visible = false
    local far = CreateItem(1, 500, 0)
    local terrain = Terrain.new()
    resetCalls()
    eq(terrain:isClear(0, 0), true)
    eq(lying.visible, true); eq(stowed.visible, false); eq(far.visible, true)
    eq(callCount('SetItemVisible'), 4) -- hide the lying item, show and hide the probe, show the lying item again
    local probe = items[4]
    eq(probe.x, 0); eq(probe.y, 0); eq(probe.visible, false)
    -- Without the hiding, the lying item would displace the probe.
    eq(SetItemPosition(probe, 0, 0), nil); eq(probe.x, 80)
end)

test('dispose removes the handles once; queries then raise', function()
    reset()
    local terrain = Terrain.new()
    terrain:height(0, 0); terrain:isClear(0, 0)
    resetCalls()
    terrain:dispose(); terrain:dispose()
    eq(callCount('RemoveLocation'), 1); eq(callCount('RemoveItem'), 1); eq(callCount('RemoveRect'), 1)
    failsAt(function() terrain:height(0, 0) end, 'Terrain.height: the terrain is disposed')
    failsAt(function() terrain:isClear(0, 0) end, 'Terrain.isClear: the terrain is disposed')
    local unused = Terrain.new()
    resetCalls()
    unused:dispose()
    eq(totalCalls(), 0)
end)

test('arguments are checked at the caller', function()
    reset()
    failsAt(function() Terrain.new(5) end, 'Terrain.new: expected an options table')
    failsAt(function() Terrain.new({itemType = 'wolg'}) end, "Terrain.new: 'itemType' expected a whole number")
    failsAt(function() Terrain.new({itemType = 1.5}) end, "Terrain.new: 'itemType' expected a whole number")
    failsAt(function() Terrain.new({itemType = math.huge}) end, "Terrain.new: 'itemType' expected a whole number")
    failsAt(function() Terrain.new({item = 1}) end, "Terrain.new: unknown key 'item'")
    local terrain = Terrain.new()
    failsAt(function() terrain:height('1', 2) end, 'Terrain.height: expected finite coordinates')
    failsAt(function() terrain:isWalkable(1, 0 / 0) end, 'Terrain.isWalkable: expected finite coordinates')
    failsAt(function() terrain:isClear(math.huge, 0) end, 'Terrain.isClear: expected finite coordinates')
    failsAt(function() terrain:inBounds(nil, 0) end, 'Terrain.inBounds: expected finite coordinates')
    failsAt(function() Terrain.height({}, 1, 1) end, 'Terrain.height: expected Terrain')
    failsAt(function() Terrain.dispose({}) end, 'Terrain.dispose: expected Terrain')
    eq(totalCalls(), 0)
end)
