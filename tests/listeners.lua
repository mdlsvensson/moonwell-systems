local Listeners = require('systems.internal.listeners')

local function names(cells)
    local out = {}
    for _, cell in ipairs(cells) do if cell.callback then out[#out + 1] = cell.callback() end end
    return table.concat(out, ',')
end
local function named(name) return function() return name end end

test('lower priority first; equal priorities in the order added', function()
    local list = Listeners.new()
    list:add(named('five'), 5); list:add(named('low'), -1); list:add(named('a'), 0); list:add(named('b'), 0)
    eq(names(list:current()), 'low,a,b,five'); eq(list:getCount(), 4)
end)

test('add and remove replace the array; an array already handed out never changes', function()
    local list = Listeners.new()
    local removeA = list:add(named('a'), 0)
    local before = list:current()
    list:add(named('b'), 0)
    eq(#before, 1); eq(#list:current(), 2)
    removeA()
    eq(before[1].callback, nil) -- skipped at once by a dispatch over the old array
    eq(names(list:current()), 'b'); removeA(); eq(list:getCount(), 1)
end)

test('ids rise across the list, and lists can share a sequence', function()
    local ids = {last = 0}
    local one, two = Listeners.new(ids), Listeners.new(ids)
    one:add(named('a'), 0); two:add(named('b'), 0); one:add(named('c'), 0)
    eq(one:current()[2].id, 3); eq(two:current()[1].id, 2); eq(one:getLastId(), 3); eq(two:getLastId(), 3)
end)

test('clear drops every listener and clears their callbacks', function()
    local list = Listeners.new()
    list:add(named('a'), 0)
    local cells = list:current()
    list:clear()
    eq(list:getCount(), 0); eq(cells[1].callback, nil)
end)
