local Codec = require('systems.codec')
eq(totalCalls(), 0)

local SECRET = 'k3-vale-of-ash'
local MAX = 2147483647
-- A codec of one version with these fields.
local function codec(fields, secret) return Codec.new({version = 1, secret = secret or SECRET, schemas = {
    {version = 1, fields = fields}}}) end
local function int(key, min, max) return {key = key, kind = 'integer', min = min, max = max} end
-- Deep equality of two values made of tables, strings, numbers and booleans.
local function same(actual, expected, path)
    path = path or 'data'
    if type(expected) ~= 'table' then
        if actual ~= expected or math.type(actual) ~= math.type(expected) then
            error(path .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
        end
        return
    end
    assert(type(actual) == 'table', path .. ': expected a table')
    for key, value in pairs(expected) do same(actual[key], value, path .. '.' .. tostring(key)) end
    for key in pairs(actual) do assert(expected[key] ~= nil, path .. ': unexpected key ' .. tostring(key)) end
end

local HERO = {int('gold', 0, 1000000), {key = 'hero', kind = 'string', maxLength = 16},
    {key = 'hardMode', kind = 'boolean'},
    {key = 'items', kind = 'list', maxLength = 6, of = {kind = 'integer', min = 0, max = MAX}}}
local EDGES = {int('low', -MAX, 0), int('high', 0, MAX), int('fixed', 7, 7),
    {key = 'flags', kind = 'list', maxLength = 5, of = {kind = 'boolean'}},
    {key = 'names', kind = 'list', maxLength = 3, of = {kind = 'string', maxLength = 4}}}

test('a code round-trips every kind of value', function()
    local saves = codec(HERO)
    local data = {gold = 500, hero = 'Hpal', hardMode = true, items = {1227894832, 1227894833, MAX}}
    local code = saves:encode(data, 'WorldEdit')
    same(saves:decode(code, 'WorldEdit'), data)
    assert(code:find('^[A-Za-z0-9_-]+$'), code)
    -- Empty strings and lists, false, and every byte in a string.
    local bytes = {}
    for byte = 0, 255 do bytes[#bytes + 1] = string.char(byte) end
    local wide = codec({{key = 'text', kind = 'string', maxLength = 256},
        {key = 'none', kind = 'string', maxLength = 0},
        {key = 'off', kind = 'boolean'}, {key = 'empty', kind = 'list', maxLength = 4, of = {kind = 'boolean'}},
        {key = 'words', kind = 'list', maxLength = 2, of = {kind = 'string', maxLength = 3}}})
    data = {text = table.concat(bytes), none = '', off = false, empty = {}, words = {'', 'abc'}}
    same(wide:decode(wide:encode(data)), data)
    -- The data given is not kept or changed, and a whole float is stored as its integer.
    local given = {gold = 3.0, hero = '', hardMode = false, items = {2.0}}
    local decoded = saves:decode(saves:encode(given))
    same(decoded, {gold = 3, hero = '', hardMode = false, items = {2}})
    eq(math.type(given.gold), 'float'); eq(math.type(given.items[1]), 'float')
end)

test('integers round-trip at the exact edges of their ranges', function()
    for _, range in ipairs({{-MAX, 0}, {0, MAX}, {-MAX, -MAX}, {7, 7}, {-5, 5}, {-1073741824, 1073741823},
        {MAX - 1, MAX}, {65535, 65536 + 65535}}) do
        local min, max = range[1], range[2]
        local saves = codec({int('value', min, max)})
        local problem = 'expected a whole number from ' .. min .. ' to ' .. max
        for _, value in ipairs({min, max, min + (max - min) // 2}) do
            eq(saves:decode(saves:encode({value = value})).value, value)
        end
        if min > -MAX then
            failsAt(function() saves:encode({value = min - 1}) end, problem)
        end
        if max < MAX then
            failsAt(function() saves:encode({value = max + 1}) end, problem)
        end
    end
end)

test('values take the bits their range needs, in 64 symbols', function()
    -- 20 header bits and 20 for the gold: 40 bits are 7 symbols, and 5 more for the check value.
    local gold = codec({int('gold', 0, 1000000)})
    eq(#gold:encode({gold = 1000000}), 12); eq(gold:getMaxLength(), 12)
    eq(gold:encode({gold = 0}):sub(1, 3), 'BAA') -- layout 1, then the version in 14 bits
    -- A fixed value takes no bits; a boolean one; a range of 2 to 3 one.
    eq(codec({int('fixed', 7, 7)}):getMaxLength(), 4 + 5)
    eq(codec({{key = 'on', kind = 'boolean'}, int('small', 2, 3), {key = 'off', kind = 'boolean'},
        int('more', 0, 1)}):getMaxLength(), 4 + 5)
    eq(codec({{key = 'on', kind = 'boolean'}, int('small', 2, 3), {key = 'off', kind = 'boolean'},
        int('more', 0, 1), int('last', 0, 1)}):getMaxLength(), 5 + 5)
    -- The spec's example: ten numbers and a 16-byte name.
    local fields = {{key = 'name', kind = 'string', maxLength = 16}}
    for index = 1, 10 do fields[#fields + 1] = int('n' .. index, 0, 1000000) end
    local ten = codec(fields)
    local data = {name = 'SixteenBytesLong'}
    for index = 1, 10 do data['n' .. index] = 1000000 end
    eq(ten:getMaxLength(), 64); eq(#ten:encode(data), 64)
    data.name = ''
    eq(#ten:encode(data), 43) -- a shorter string makes a shorter code
    -- A list's longest code counts every value.
    eq(codec(HERO):getMaxLength(), 66)
    -- The longest code counts every version: an older code may be longer than a current one.
    eq(Codec.new({version = 2, secret = SECRET, schemas = {{version = 2, fields = {}},
        {version = 1, fields = {int('gold', 0, 1000000)}, migrate = function() return {} end}}}):getMaxLength(), 12)
    eq(codec({}):getVersion(), 1)
end)

test('fixed codes: the same in every Lua, and as an independent implementation of the layout gives', function()
    eq(codec(HERO):encode({gold = 500, hero = 'Hpal', hardMode = true, items = {1227894832, 1227894833, MAX}},
        'WorldEdit'), 'BAAQAfQiQ4MLZckwMDCSYGBj_____8WQGq')
    local edges = Codec.new({version = 2, secret = SECRET, schemas = {{version = 2, fields = EDGES}}})
    local code = edges:encode({low = -MAX, high = MAX, fixed = 7, flags = {true, false, true},
        names = {'', 'ab', '\0\255\128\n'}})
    eq(code, 'BAAgAAAAH____93CYWKAH_ABQ-Isnq')
    same(edges:decode(code), {low = -MAX, high = MAX, fixed = 7, flags = {true, false, true},
        names = {'', 'ab', '\0\255\128\n'}})
    local empty = Codec.new({version = 9999, secret = 'x', schemas = {{version = 9999, fields = {}}}})
    eq(empty:encode({}, 'Player \xc3\x85ke'), 'BnDwdyUOJ')
end)

test('encode raises at the caller for data that does not fit, and names the field', function()
    local saves = codec(HERO)
    local function with(key, value)
        local data = {gold = 1, hero = 'a', hardMode = false, items = {}}
        data[key] = value
        return function() saves:encode(data) end
    end
    failsAt(with('gold', nil), '[systems] Codec.encode: field "gold": expected a whole number from 0 to 1000000')
    failsAt(with('gold', 1.5), 'field "gold": expected a whole number')
    failsAt(with('gold', '5'), 'field "gold": expected a whole number')
    failsAt(with('gold', 0 / 0), 'field "gold": expected a whole number')
    failsAt(with('gold', math.huge), 'field "gold": expected a whole number')
    failsAt(with('gold', 1000001), 'field "gold": expected a whole number')
    failsAt(with('gold', -1), 'field "gold": expected a whole number')
    failsAt(with('hero', 5), 'field "hero": expected a string of at most 16 bytes')
    failsAt(with('hero', string.rep('x', 17)), 'field "hero": expected a string of at most 16 bytes')
    failsAt(with('hardMode', 1), 'field "hardMode": expected true or false')
    failsAt(with('items', 'none'), 'field "items": expected a list of at most 6 values')
    failsAt(with('items', {1, 2, 3, 4, 5, 6, 7}), 'field "items": expected a list of at most 6 values')
    failsAt(with('items', {1, nil, 3}), 'field "items": expected a list of at most 6 values')
    failsAt(with('items', {1, count = 1}), 'field "items": expected a list of at most 6 values')
    failsAt(with('items', {1, -1}), 'field "items": value 2: expected a whole number from 0 to 2147483647')
    -- A key the schema does not have: the first in sorted order.
    failsAt(with('glod', 5), '[systems] Codec.encode: unknown field "glod"')
    local stray = {gold = 1, hero = 'a', hardMode = false, items = {}, [3] = 4}
    for index = 1, 40 do stray['key' .. index] = index end
    failsAt(function() saves:encode(stray) end, 'unknown field "3"')
    failsAt(function() saves:encode('gold') end, '[systems] Codec.encode: expected a data table')
    failsAt(function() saves:encode({gold = 1, hero = 'a', hardMode = false, items = {}}, 5) end,
        '[systems] Codec.encode: expected a binding string')
    -- The first field in schema order is reported.
    failsAt(function() saves:encode({}) end, 'field "gold"')
end)

test('decode reports a bad code without raising', function()
    local saves = codec(HERO)
    local data = {gold = 500, hero = 'Hpal', hardMode = true, items = {7}}
    local code = saves:encode(data, 'WorldEdit')
    local function reason(text, binding, decoder)
        local decoded, why, detail = (decoder or saves):decode(text, binding or 'WorldEdit')
        eq(decoded, nil); eq(detail, nil)
        return why
    end
    eq(reason(nil), 'format'); eq(reason(42), 'format'); eq(reason({}), 'format')
    eq(reason(''), 'format'); eq(reason('BAAQAAAA'), 'format') -- 8 symbols: one short of the shortest code
    eq(reason(code .. '!'), 'format'); eq(reason(code:sub(1, 3) .. ' ' .. code:sub(5)), 'format')
    eq(reason(code .. '\n'), 'format'); eq(reason(string.rep('A', 8193)), 'format')
    -- A valid check value, but a layout number this library does not know.
    eq(reason('AAAQgVggv', ''), 'format')
    -- Any changed symbol, another binding and another secret fail the check.
    for index = 1, #code do
        local symbol = code:sub(index, index) == 'A' and 'B' or 'A'
        eq(reason(code:sub(1, index - 1) .. symbol .. code:sub(index + 1)), 'checksum')
    end
    eq(reason(code, 'worldedit'), 'checksum'); eq(reason(code, ''), 'checksum')
    eq(reason(code, 'WorldEdit', codec(HERO, SECRET .. '!')), 'checksum')
    eq(reason(code:sub(1, -2)), 'checksum'); eq(reason(code .. 'A'), 'checksum')
    eq(reason(string.rep('A', 8192)), 'checksum')
    -- The binding and the body are told apart: "ab" + "c" is not "a" + "bc".
    local plain = codec({})
    assert(plain:encode({}, 'ab') ~= plain:encode({}, 'a'))
    assert(codec({}, 'ab'):encode({}, 'c') ~= codec({}, 'a'):encode({}, 'bc'))
    eq(plain:encode({}), plain:encode({}, ''))
    failsAt(function() saves:decode(code, 5) end, '[systems] Codec.decode: expected a binding string')
    same(saves:decode(code, 'WorldEdit'), data)
end)

test('a version without a schema is reported', function()
    local two = Codec.new({version = 2, secret = SECRET, schemas = {{version = 2, fields = {}}}})
    local newer = two:encode({})
    local decoded, why = codec({}):decode(newer)
    eq(decoded, nil); eq(why, 'version') -- a newer code than the codec knows
    local three = Codec.new({version = 3, secret = SECRET, schemas = {{version = 3, fields = {}},
        {version = 1, fields = {}, migrate = function(data) return data end}}})
    decoded, why = three:decode(newer)
    eq(decoded, nil); eq(why, 'version') -- an older one whose schema is gone
end)

test('bits that do not fit the schema are reported', function()
    local function why(writer, data, reader)
        local decoded, reason = codec(reader):decode(codec(writer):encode(data))
        eq(decoded, nil)
        return reason
    end
    eq(why({int('a', 0, 10)}, {a = 10}, {int('a', 0, 10), {key = 'b', kind = 'boolean'}}), 'schema') -- bits missing
    eq(why({int('a', 0, 10)}, {a = 10}, {}), 'schema') -- bits left over in the last symbol
    eq(why({int('a', 0, 1000000)}, {a = 0}, {}), 'schema') -- a symbol left over
    eq(why({int('a', 0, 15)}, {a = 15}, {int('a', 0, 10)}), 'schema') -- out of the range
    eq(why({{key = 's', kind = 'string', maxLength = 15}}, {s = string.rep('x', 12)},
        {{key = 's', kind = 'string', maxLength = 10}}), 'schema') -- longer than the string may be
    eq(why({{key = 's', kind = 'string', maxLength = 15}}, {s = string.rep('x', 12)},
        {{key = 's', kind = 'list', maxLength = 10, of = {kind = 'boolean'}}}), 'schema')
    eq(why({{key = 'l', kind = 'list', maxLength = 3, of = {kind = 'integer', min = 0, max = 15}}}, {l = {1, 15}},
        {{key = 'l', kind = 'list', maxLength = 3, of = {kind = 'integer', min = 0, max = 10}}}), 'schema')
    eq(why({{key = 'l', kind = 'list', maxLength = 3, of = {kind = 'boolean'}}}, {l = {true, true, true}},
        {{key = 'l', kind = 'list', maxLength = 3, of = {kind = 'string', maxLength = 200}}}), 'schema')
    -- The same bits under another schema of the same shape decode: only the version tells schemas apart.
    same(codec({int('b', 0, 15)}):decode(codec({int('a', 0, 15)}):encode({a = 9})), {b = 9})
end)

test('older codes migrate one version at a time', function()
    local one = codec({int('gold', 0, 100)})
    local old = one:encode({gold = 40}, 'Ann')
    local calls = {}
    local function schemas(overrides)
        local list = {
            {version = 1, fields = {int('gold', 0, 100)}, migrate = function(data)
                calls[#calls + 1] = 'one'
                return {gold = data.gold, gems = 2.0}
            end},
            {version = 2, fields = {int('gold', 0, 100), int('gems', 0, 9)}, migrate = function(data)
                calls[#calls + 1] = 'two'
                return {coins = data.gold * 10 + data.gems}
            end},
            {version = 3, fields = {int('coins', 0, 100000)}},
        }
        for version, override in pairs(overrides or {}) do
            for key, value in pairs(override) do list[version][key] = value ~= 'none' and value or nil end
        end
        return list
    end
    local three = Codec.new({version = 3, secret = SECRET, schemas = schemas()})
    local data = three:decode(old, 'Ann')
    same(data, {coins = 402}); eq(table.concat(calls, ','), 'one,two')
    same(three:decode(three:encode({coins = 5})), {coins = 5}) -- a current code is not migrated
    eq(#calls, 2)
    eq(three:getVersion(), 3)
    local function failure(overrides, version)
        local decoded, why, detail = Codec.new({version = version or 3, secret = SECRET,
            schemas = schemas(overrides)}):decode(old, 'Ann')
        eq(decoded, nil); eq(why, 'migration')
        return detail
    end
    eq(failure({[1] = {migrate = 'none'}}), 'schema 1 has no migrate function')
    assert(failure({[2] = {migrate = function() error('boom') end}}):find('boom$'))
    eq(failure({[1] = {migrate = function() return {gold = 1} end}}),
        'version 2: field "gems": expected a whole number from 0 to 9')
    eq(failure({[1] = {migrate = function() return 'gold' end}}), 'version 2: expected a data table')
    eq(failure({[1] = {migrate = function() return {gold = 1, gems = 1, extra = true} end}}),
        'version 2: unknown field "extra"')
    -- A schema missing between the code's version and the current one.
    local decoded, why, detail = Codec.new({version = 3, secret = SECRET, schemas = {schemas()[1], schemas()[3]}})
        :decode(old, 'Ann')
    eq(decoded, nil); eq(why, 'migration'); eq(detail, 'no schema for version 2')
end)

test('new checks its options at the caller', function()
    local function with(overrides)
        local options = {version = 1, secret = SECRET, schemas = {{version = 1, fields = {}}}}
        for key, value in pairs(overrides) do options[key] = value ~= 'none' and value or nil end
        return function() Codec.new(options) end
    end
    local function field(given) return with({schemas = {{version = 1, fields = {given}}}}) end
    failsAt(function() Codec.new() end, '[systems] Codec.new: expected an options table')
    for _, version in ipairs({'none', 0, 10000, 1.5, '1'}) do
        failsAt(with({version = version}), '[systems] Codec.new: expected a version from 1 to 9999')
    end
    for _, secret in ipairs({'none', '', 5}) do
        failsAt(with({secret = secret}), '[systems] Codec.new: expected a secret: a non-empty string')
    end
    failsAt(with({schemas = 'none'}), '[systems] Codec.new: expected a list of schemas')
    failsAt(with({schemas = {}}), '[systems] Codec.new: no schema for the current version 1')
    failsAt(with({schemas = {'one'}}), '[systems] Codec.new: expected a schema table')
    for _, version in ipairs({'none', 0, 2, 1.5}) do
        failsAt(with({schemas = {{version = version, fields = {}}}}), 'expected a schema version from 1 to 1')
    end
    failsAt(with({schemas = {{version = 1, fields = {}}, {version = 1, fields = {}}}}), 'schema 1 is given twice')
    failsAt(with({schemas = {{version = 1, fields = {}, migrate = true}}}),
        'schema 1: expected migrate to be a function')
    failsAt(with({schemas = {{version = 1}}}), 'schema 1: expected a list of at most 64 fields')
    local many = {}
    for index = 1, 65 do many[index] = {key = 'k' .. index, kind = 'boolean'} end
    failsAt(with({schemas = {{version = 1, fields = many}}}), 'schema 1: expected a list of at most 64 fields')
    many[65] = nil
    Codec.new({version = 1, secret = SECRET, schemas = {{version = 1, fields = many}}})
    failsAt(field('gold'), 'schema 1, field 1: expected a field table')
    failsAt(field({kind = 'boolean'}), 'schema 1, field 1: expected a key: a non-empty string')
    failsAt(field({key = '', kind = 'boolean'}), 'schema 1, field 1: expected a key: a non-empty string')
    failsAt(field({key = 5, kind = 'boolean'}), 'schema 1, field 1: expected a key: a non-empty string')
    failsAt(with({schemas = {{version = 1, fields = {{key = 'a', kind = 'boolean'}, {key = 'a', kind = 'boolean'}}}}}),
        'schema 1, field "a": the key is used twice')
    failsAt(field({key = 'a', kind = 'number'}),
        'schema 1, field "a": expected kind: "integer", "boolean", "string" or "list"')
    for _, range in ipairs({{nil, 5}, {0, nil}, {0.5, 5}, {5, 4}, {-MAX - 1, 0}, {0, MAX + 1}, {'0', 5}}) do
        failsAt(field({key = 'a', kind = 'integer', min = range[1], max = range[2]}),
            'schema 1, field "a": expected min and max: whole numbers within -2147483647 to 2147483647')
    end
    failsAt(field(int('a', -1, MAX)), 'schema 1, field "a": max - min is over 2147483647')
    failsAt(field(int('a', -MAX, 1)), 'schema 1, field "a": max - min is over 2147483647')
    for _, kind in ipairs({'string', 'list'}) do
        for _, maxLength in ipairs({'none', -1, 4096, 1.5}) do
            failsAt(field({key = 'a', kind = kind, maxLength = maxLength ~= 'none' and maxLength or nil,
                of = {kind = 'boolean'}}), 'schema 1, field "a": expected maxLength: a whole number from 0 to 4095')
        end
    end
    failsAt(field({key = 'a', kind = 'list', maxLength = 2}), 'schema 1, field "a": of: expected a field table')
    failsAt(field({key = 'a', kind = 'list', maxLength = 2,
        of = {kind = 'list', maxLength = 2, of = {kind = 'boolean'}}}),
        'schema 1, field "a": of: a list cannot hold lists')
    failsAt(field({key = 'a', kind = 'list', maxLength = 2, of = {kind = 'integer', min = 3, max = 2}}),
        'schema 1, field "a": of: expected min and max')
    -- The longest code is limited, for every schema.
    local long = {key = 'a', kind = 'string', maxLength = 4095}
    eq(Codec.new({version = 1, secret = SECRET, schemas = {{version = 1, fields = {long}}}}):getMaxLength(), 5471)
    failsAt(with({schemas = {{version = 1, fields = {long, {key = 'b', kind = 'string', maxLength = 2040}}}}}),
        'schema 1: its longest code would pass 8192 symbols')
    eq(Codec.new({version = 1, secret = SECRET, schemas = {{version = 1, fields = {long,
        {key = 'b', kind = 'string', maxLength = 2037}}}}}):getMaxLength(), 8189)
    failsAt(with({version = 2, schemas = {{version = 2, fields = {}}, {version = 1, fields = {
        {key = 'a', kind = 'list', maxLength = 4095, of = {kind = 'string', maxLength = 4095}}}}}}),
        'schema 1: its longest code would pass 8192 symbols')
end)

test('a codec keeps its own copy of the schemas, and its methods check their receiver', function()
    local fields = {int('gold', 0, 100)}
    local schema = {version = 1, fields = fields}
    local saves = Codec.new({version = 1, secret = SECRET, schemas = {schema}})
    local code = saves:encode({gold = 5})
    fields[1].max = 1; fields[1].key = 'other'; fields[2] = int('more', 0, 1); schema.version = 9
    eq(saves:encode({gold = 5}), code); eq(saves:decode(code).gold, 5)
    failsAt(function() saves.encode({}, {}) end, '[systems] Codec.encode: expected Codec')
    failsAt(function() saves.decode({}, code) end, '[systems] Codec.decode: expected Codec')
    failsAt(function() saves.getVersion({}) end, '[systems] Codec.getVersion: expected Codec')
    failsAt(function() saves.getMaxLength({}) end, '[systems] Codec.getMaxLength: expected Codec')
end)

test('unknown keys are refused in options, schemas and fields', function()
    local field = {key = 'gold', kind = 'integer', min = 0, max = 100}
    failsAt(function() Codec.new({version = 1, secret = 's', schemas = {{version = 1, fields = {field}}}, salt = 1}) end,
        "Codec.new: unknown key 'salt'")
    failsAt(function() Codec.new({version = 1, secret = 's', schemas = {{version = 1, fields = {field}, migrat = 1}}}) end,
        "Codec.new: schema 1: unknown key 'migrat'")
    failsAt(function() Codec.new({version = 1, secret = 's', schemas = {{version = 1, fields = {
        {key = 'name', kind = 'string', maxLenght = 4, maxLength = 4}}}}}) end,
        "Codec.new: schema 1, field \"name\": unknown key 'maxLenght'")
    failsAt(function() Codec.new({version = 1, secret = 's', schemas = {{version = 1, fields = {
        {key = 'ids', kind = 'list', maxLength = 2, of = {kind = 'integer', min = 0, max = 1, step = 1}}}}}}) end,
        "Codec.new: schema 1, field \"ids\": of: unknown key 'step'")
end)
