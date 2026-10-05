local Ordered = require('systems.internal.ordered')

local function collect(map)
    local seen = {}
    map:each(function(key, value) seen[#seen + 1] = tostring(key) .. '=' .. tostring(value) end)
    return table.concat(seen, ',')
end

test('keeps insertion order; set on an existing key keeps its place', function()
    local map = Ordered.new()
    map:set('b', 1); map:set('a', 2); map:set('c', 3); map:set('b', 4)
    eq(collect(map), 'b=4,a=2,c=3'); eq(map:getSize(), 3)
    eq(map:get('a'), 2); eq(map:has('z'), false); eq(map:get('z'), nil)
    eq(table.concat(map:keys(), ','), 'b,a,c')
end)

test('delete, and deleting during each skips the deleted entry', function()
    local map = Ordered.new()
    for _, key in ipairs({'a', 'b', 'c', 'd'}) do map:set(key, true) end
    eq(map:delete('b'), true); eq(map:delete('b'), false)
    local seen = {}
    map:each(function(key) seen[#seen + 1] = key; if key == 'a' then map:delete('c') end end)
    eq(table.concat(seen, ','), 'a,d'); eq(map:getSize(), 2); eq(table.concat(map:keys(), ','), 'a,d')
end)

test('entries added during each wait for the next; a re-added key goes last', function()
    local map = Ordered.new()
    map:set('a', 1); map:set('b', 2)
    local seen = {}
    map:each(function(key)
        seen[#seen + 1] = key
        if key == 'a' then map:set('z', 9); map:delete('a'); map:set('a', 5) end
    end)
    eq(table.concat(seen, ','), 'a,b'); eq(table.concat(map:keys(), ','), 'b,z,a')
end)

test('nested each works, and an error inside each leaves the map usable and compacting', function()
    local map = Ordered.new()
    map:set('a', 1); map:set('b', 2)
    local seen = {}
    map:each(function(outer) map:each(function(inner) seen[#seen + 1] = outer .. inner end) end)
    eq(table.concat(seen, ','), 'aa,ab,ba,bb')
    eq(pcall(function() map:each(function() error('stop') end) end), false)
    for index = 1, 100 do map:set(index, index) end
    for index = 1, 100 do map:delete(index) end
    eq(map:getSize(), 2); eq(table.concat(map:keys(), ','), 'a,b')
    assert(#map.order <= 4, 'expected compaction, order has ' .. #map.order)
end)

test('tables are keys by identity', function()
    local first, second = {}, {}
    local map = Ordered.new()
    map:set(first, 'one'); map:set(second, 'two')
    eq(map:get(first), 'one'); eq(map:keys()[2], second)
end)

test('each still restores the map after an error and allows a nested each', function()
    local map = Ordered.new()
    map:set('a', 1); map:set('b', 2); map:set('c', 3)
    local ok = pcall(function() map:each(function(key) if key == 'b' then error('stop') end end) end)
    eq(ok, false)
    map:delete('a'); map:delete('b')
    local seen = {}
    map:each(function(key) map:each(function(inner) seen[#seen + 1] = key .. inner end) end)
    eq(table.concat(seen, ','), 'cc')
    eq(#map:keys(), 1)
end)

