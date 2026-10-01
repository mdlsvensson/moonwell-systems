-- The game, as far as save files go: tooltips per ability, the lines buffered for a file, and the files written.
-- Preloader runs a file's lines as the game does: each must be one whole tooltip call, or the game could not run it.
local texts, files, buffer, dead = {}, {}, {}, {}
local function field(name, key)
    native('BlzGetAbility' .. name, function(ability, level)
        eq(level, 0)
        return texts[key .. ability]
    end)
    native('BlzSetAbility' .. name, function(ability, text, level)
        eq(level, 0); eq(type(text), 'string')
        if not dead[key .. ability] then texts[key .. ability] = text end
    end)
end
field('Tooltip', 't'); field('ExtendedTooltip', 'e')
native('PreloadGenClear', function() buffer = {} end)
native('PreloadGenStart', function() end)
-- Preload keeps 259 characters (measured in game).
native('Preload', function(text) buffer[#buffer + 1] = text:sub(1, 259) end)
native('PreloadGenEnd', function(path) files[path] = buffer end)
native('Preloader', function(path)
    for _, line in ipairs(files[path] or {}) do
        local name, ability, text = line:match('^"%)\ncall (BlzSetAbility%a+)%((%d+), "([^"]*)", 0%)\n//$')
        assert(name, 'a line the game cannot run: ' .. line)
        _G[name](math.tointeger(tonumber(ability)), text, 0)
    end
end)
local Files = require('systems.internal.preload')
eq(totalCalls(), 0)

local A, B, C = 1097690227, 1097035619, 1097689443
-- Every test starts with setup(): no files, and a tooltip and an extended tooltip of its own for each ability.
local function setup()
    texts, files, buffer, dead = {}, {}, {}, {}
    for _, ability in ipairs({A, B, C}) do
        texts['t' .. ability], texts['e' .. ability] = 'tip ' .. ability, 'more ' .. ability
    end
    resetCalls()
end
local function code(length)
    local symbols = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
    local parts = {}
    for index = 1, length do
        local at = (index * 13) % 64 + 1
        parts[index] = symbols:sub(at, at)
    end
    return table.concat(parts)
end
local function restored()
    for _, ability in ipairs({A, B, C}) do
        eq(texts['t' .. ability], 'tip ' .. ability); eq(texts['e' .. ability], 'more ' .. ability)
    end
end
-- A file whose lines set the carriers of {A, B, C} to `chunks`, in order.
local function plant(path, chunks)
    local lines = {}
    for index, chunk in ipairs(chunks) do
        local ability = ({A, B, C})[(index - 1) // 2 + 1]
        local name = index % 2 == 1 and 'BlzSetAbilityTooltip' or 'BlzSetAbilityExtendedTooltip'
        lines[index] = '")\ncall ' .. name .. '(' .. ability .. ', "' .. chunk .. '", 0)\n//'
    end
    files[path] = lines
end

test('a code is written one chunk per ability field, and read back', function()
    setup()
    local saved = code(500)
    Files.write('Vale\\slot1.pld', {A, B}, saved)
    local lines = files['Vale\\slot1.pld']
    eq(#lines, 3) -- "MWS1.500." and 500 symbols are 509 characters
    eq(lines[1], '")\ncall BlzSetAbilityTooltip(' .. A .. ', "MWS1.500.' .. saved:sub(1, 181) .. '", 0)\n//')
    eq(lines[2], '")\ncall BlzSetAbilityExtendedTooltip(' .. A .. ', "' .. saved:sub(182, 371) .. '", 0)\n//')
    eq(lines[3], '")\ncall BlzSetAbilityTooltip(' .. B .. ', "' .. saved:sub(372) .. '", 0)\n//')
    for _, line in ipairs(lines) do assert(#line <= 248, #line) end
    -- The buffer is cleared before and after, so nothing else reaches the file or the next one.
    eq(callCount('PreloadGenClear'), 2); eq(callCount('PreloadGenStart'), 1); eq(callCount('PreloadGenEnd'), 1)
    restored() -- writing touches no tooltip
    resetCalls()
    local read, reason = Files.read('Vale\\slot1.pld', {A, B})
    eq(read, saved); eq(reason, nil)
    expectCall('Preloader', 'Vale\\slot1.pld')
    restored()
    -- A second write replaces the file.
    Files.write('Vale\\slot1.pld', {A, B}, 'short')
    eq(Files.read('Vale\\slot1.pld', {A, B}), 'short')
    eq(#files['Vale\\slot1.pld'], 1)
end)

test('the longest code fills every carrier, and a line stays within what Preload keeps', function()
    setup()
    eq(Files.capacity({A}), 370); eq(Files.capacity({A, B}), 750)
    local abilities = {}
    for index = 1, 24 do abilities[index] = A + index end
    eq(Files.capacity(abilities), 9110)
    local saved = code(750)
    Files.write('Vale\\full.pld', {A, B}, saved)
    eq(#files['Vale\\full.pld'], 4)
    eq(Files.read('Vale\\full.pld', {A, B}), saved)
    -- A text that ends exactly at a chunk's end takes no chunk more: "MWS1.371." and 371 symbols are 380 characters.
    Files.write('Vale\\even.pld', {A, B}, code(371))
    eq(#files['Vale\\even.pld'], 2)
    eq(Files.read('Vale\\even.pld', {A, B}), code(371))
    -- A full chunk in the extended tooltip of the largest ability id makes the longest line.
    Files.write('Vale\\wide.pld', {2147483647, A}, code(500))
    eq(#files['Vale\\wide.pld'][2], 248)
    restored()
end)

test('a missing file reads as missing, and restores the first carrier', function()
    setup()
    local read, reason = Files.read('Vale\\none.pld', {A, B})
    eq(read, nil); eq(reason, 'missing')
    restored()
end)

test('a file that does not hold what its header says reads as damaged, and every carrier is restored', function()
    local function damaged(chunks)
        setup()
        plant('Vale\\bad.pld', chunks)
        local read, reason = Files.read('Vale\\bad.pld', {A, B, C})
        eq(read, nil); eq(reason, 'damaged')
        restored()
    end
    damaged({'MWS2.5.abcde'})                       -- another format
    damaged({'abcde'})                              -- no header
    damaged({'MWS1.abcde'})                         -- no length
    damaged({'MWS1.0.'})                            -- an empty code
    damaged({'MWS1.05.abcde'})                      -- a length with a leading zero
    damaged({'MWS1.12345.abcde'})                   -- a length of five digits
    damaged({'MWS1.9999.' .. code(180)})            -- more than the carriers hold
    damaged({'MWS1.5.abcd'})                        -- shorter than its length says
    damaged({'MWS1.5.abcdef'})                      -- longer
    damaged({'MWS1.5.ab!de'})                       -- a character outside the alphabet
    damaged({'MWS1.5.ab de'})
    damaged({'MWS1.300.' .. code(181)})             -- the second chunk never arrived: the tooltip is still there
    damaged({'MWS1.300.' .. code(181), code(100)})  -- or arrived short
    damaged({'MWS1.300.' .. code(180), code(119)})  -- or the first chunk is short
    -- What write produces, planted by hand, is not damaged.
    setup()
    plant('Vale\\good.pld', {'MWS1.300.' .. code(181), code(119)})
    eq(Files.read('Vale\\good.pld', {A, B, C}), code(181) .. code(119))
    plant('Vale\\edge.pld', {'MWS1.1.x'})
    eq(Files.read('Vale\\edge.pld', {A, B, C}), 'x')
    -- A stale chunk beyond the code's length is ignored.
    plant('Vale\\stale.pld', {'MWS1.5.abcde', 'left over'})
    eq(Files.read('Vale\\stale.pld', {A, B, C}), 'abcde')
    restored()
end)

test('an ability without a tooltip is damaged, not an error', function()
    setup()
    texts['t' .. A] = nil
    dead['t' .. A] = true
    local read, reason = Files.read('Vale\\none.pld', {A})
    eq(read, nil); eq(reason, 'damaged')
    eq(texts['t' .. A], nil); eq(texts['e' .. A], 'more ' .. A)
end)

test('verify finds the first ability that cannot carry text, and restores every text', function()
    setup()
    eq(Files.verify({A, B, C}), nil)
    restored()
    dead['t' .. B] = true
    eq(Files.verify({A, B, C}), B)
    restored()
    setup()
    dead['e' .. C] = true; dead['t' .. B] = true
    eq(Files.verify({A, C, B}), C) -- the first in the list's order, by its extended tooltip alone
    restored()
    setup()
    texts['t' .. A], texts['e' .. A] = nil, nil
    dead['t' .. A], dead['e' .. A] = true, true
    eq(Files.verify({A}), A) -- an ability the game does not have
    eq(Files.verify({}), nil)
end)
