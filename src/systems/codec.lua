local Check = require('systems.internal.check')

---Save codes: data packed by a versioned schema into 64 symbols, with a keyed check value and migrations (spec
---2026-10-01 release 5 §4). Pure: it calls no native, so a code is the same on every machine.
---@class MoonwellSystems.Codec
---@field package version integer
---@field package secret string
---@field package schemas table<integer, MoonwellSystems.CodecCompiledSchema>
---@field package maxLength integer
local Codec = {}
Codec.__index = Codec

---@class MoonwellSystems.CodecField
---@field key string? The data key; required in a schema's fields, absent in a list's `of`.
---@field kind 'integer'|'boolean'|'string'|'list'
---@field min integer? integer: the smallest value.
---@field max integer? integer: the largest value; `max - min` is at most 2147483647.
---@field maxLength integer? string: the most bytes; list: the most values. 0 to 4095.
---@field of MoonwellSystems.CodecField? list: the kind of every value: integer, boolean or string.

---@class MoonwellSystems.CodecSchema
---@field version integer From 1 to the codec's current version.
---@field fields MoonwellSystems.CodecField[] In encoding order; at most 64.
---@field migrate (fun(data: table): table)? Returns the data of the next version.

---@class MoonwellSystems.CodecOptions
---@field version integer The current version, 1 to 9999; `encode` writes this one.
---@field secret string Mixed into every check value. Keep it to the map.
---@field schemas MoonwellSystems.CodecSchema[] One per supported version, the current one included.

---@class MoonwellSystems.CodecCompiledField
---@field key string?
---@field kind string
---@field min integer
---@field max integer
---@field width integer Bits of an integer's offset, or of a string's or list's length.
---@field maxLength integer
---@field of MoonwellSystems.CodecCompiledField?

---@class MoonwellSystems.CodecCompiledSchema
---@field fields MoonwellSystems.CodecCompiledField[]
---@field keys table<string, true>
---@field migrate (fun(data: table): table)?

local ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
local MAX_INT = 2147483647
local MAX_VERSION = 9999
local MAX_FIELDS = 64
local MAX_COUNT = 4095          -- the longest string or list
local MAX_SYMBOLS = 8192        -- the longest code
local LAYOUT = 1
local HEADER_BITS = 20          -- the layout number (6) and the version (14)
local CHECK_SYMBOLS = 5         -- 30 bits of check value
local MAX_BITS = (MAX_SYMBOLS - CHECK_SYMBOLS) * 6

---@type table<integer, integer>
local VALUES = {}
for index = 1, #ALPHABET do VALUES[ALPHABET:byte(index)] = index - 1 end

---The whole number `value` holds, or nil. math.tointeger alone would also convert strings on Lua 5.4.
---@param value unknown
---@return integer?
local function whole(value)
    if type(value) ~= 'number' then return nil end
    return math.tointeger(value)
end

---How many bits a value from 0 to `span` needs.
---@param span integer
---@return integer
local function widthOf(span)
    local width = 0
    while span > 0 do
        width = width + 1
        span = span >> 1
    end
    return width
end

-- Compiling a schema

---@param field unknown
---@param keyed boolean Whether the field is one of a schema's (with a key) or a list's `of`.
---@return MoonwellSystems.CodecCompiledField? compiled
---@return string? problem
local function compileField(field, keyed)
    if type(field) ~= 'table' then return nil, 'expected a field table' end
    local kind = field.kind
    local compiled = {key = field.key, kind = kind, min = 0, max = 0, width = 0, maxLength = 0}
    if kind == 'integer' then
        local min, max = whole(field.min), whole(field.max)
        if not min or not max or min < -MAX_INT or max > MAX_INT or min > max then
            return nil, 'expected min and max: whole numbers within ' .. -MAX_INT .. ' to ' .. MAX_INT
        end
        -- max - min without leaving the 32-bit range: with min below zero, MAX_INT + min cannot overflow.
        if min < 0 and max > MAX_INT + min then return nil, 'max - min is over ' .. MAX_INT end
        compiled.min, compiled.max, compiled.width = min, max, widthOf(max - min)
    elseif kind == 'string' or kind == 'list' then
        local maxLength = whole(field.maxLength)
        if not maxLength or maxLength < 0 or maxLength > MAX_COUNT then
            return nil, 'expected maxLength: a whole number from 0 to ' .. MAX_COUNT
        end
        compiled.maxLength, compiled.width = maxLength, widthOf(maxLength)
        if kind == 'list' then
            if not keyed then return nil, 'a list cannot hold lists' end
            local of, problem = compileField(field.of, false)
            if not of then return nil, 'of: ' .. tostring(problem) end
            compiled.of = of
        end
    elseif kind ~= 'boolean' then
        return nil, 'expected kind: "integer", "boolean", "string" or "list"'
    end
    return compiled
end

---The most bits a field's value takes: at most 134 million, for a full list of full strings.
---@param field MoonwellSystems.CodecCompiledField
---@return integer
local function worstBits(field)
    if field.kind == 'integer' then return field.width end
    if field.kind == 'boolean' then return 1 end
    if field.kind == 'string' then return field.width + 8 * field.maxLength end
    return field.width + field.maxLength * worstBits(field.of)
end

---@param schema unknown
---@param current integer
---@return MoonwellSystems.CodecCompiledSchema? compiled
---@return string|integer detail The problem, or the longest code in symbols.
local function compileSchema(schema, current)
    if type(schema) ~= 'table' then return nil, 'expected a schema table' end
    local version = whole(schema.version)
    if not version or version < 1 or version > current then
        return nil, 'expected a schema version from 1 to ' .. current
    end
    local label = 'schema ' .. version
    if schema.migrate ~= nil and type(schema.migrate) ~= 'function' then
        return nil, label .. ': expected migrate to be a function'
    end
    local fields = schema.fields
    if type(fields) ~= 'table' or #fields > MAX_FIELDS then
        return nil, label .. ': expected a list of at most ' .. MAX_FIELDS .. ' fields'
    end
    local compiled = {fields = {}, keys = {}, migrate = schema.migrate}
    local bits = HEADER_BITS
    for index = 1, #fields do
        local field, problem = compileField(fields[index], true)
        local key = type(fields[index]) == 'table' and fields[index].key or nil
        local shown = type(key) == 'string' and key ~= '' and '"' .. key .. '"' or tostring(index)
        local name = label .. ', field ' .. shown
        if not field then return nil, name .. ': ' .. tostring(problem) end
        if type(key) ~= 'string' or key == '' then return nil, name .. ': expected a key: a non-empty string' end
        if compiled.keys[key] then return nil, name .. ': the key is used twice' end
        compiled.keys[key] = true
        compiled.fields[index] = field
        bits = bits + worstBits(field)
        -- Checked field by field, so the sum stays far inside the 32-bit range.
        if bits > MAX_BITS then
            return nil, label .. ': its longest code would pass ' .. MAX_SYMBOLS .. ' symbols'
        end
    end
    return compiled, (bits + 5) // 6 + CHECK_SYMBOLS
end

-- Values

---The value as the field stores it, or a problem.
---@param field MoonwellSystems.CodecCompiledField
---@param value unknown
---@return any normal
---@return string? problem
local function normal(field, value)
    local kind = field.kind
    if kind == 'integer' then
        local number = whole(value)
        if not number or number < field.min or number > field.max then
            return nil, 'expected a whole number from ' .. field.min .. ' to ' .. field.max
        end
        return number
    elseif kind == 'boolean' then
        if type(value) ~= 'boolean' then return nil, 'expected true or false' end
        return value
    elseif kind == 'string' then
        if type(value) ~= 'string' or #value > field.maxLength then
            return nil, 'expected a string of at most ' .. field.maxLength .. ' bytes'
        end
        return value
    end
    local problem = 'expected a list of at most ' .. field.maxLength .. ' values'
    if type(value) ~= 'table' then return nil, problem end
    local count = #value
    local entries = 0
    for _ in pairs(value) do entries = entries + 1 end
    if entries ~= count or count > field.maxLength then return nil, problem end
    local list = {}
    for index = 1, count do
        local item, why = normal(field.of, value[index])
        if why then return nil, 'value ' .. index .. ': ' .. why end
        list[index] = item
    end
    return list
end

---A copy of `data` as the schema stores it, or a problem that names the field.
---@param schema MoonwellSystems.CodecCompiledSchema
---@param data unknown
---@return table? copy
---@return string? problem
local function fit(schema, data)
    if type(data) ~= 'table' then return nil, 'expected a data table' end
    local unknown = {}
    for key in pairs(data) do
        if not schema.keys[key] then unknown[#unknown + 1] = tostring(key) end
    end
    if #unknown > 0 then
        table.sort(unknown)
        return nil, 'unknown field "' .. unknown[1] .. '"'
    end
    local copy = {}
    for _, field in ipairs(schema.fields) do
        local value, problem = normal(field, data[field.key])
        if problem then return nil, 'field "' .. field.key .. '": ' .. problem end
        copy[field.key] = value
    end
    return copy
end

-- Bits. At most 16 are written or read at once, so no intermediate value leaves the 32-bit range. The writer's
-- mask changes nothing while that holds; it makes a 64-bit Lua fail as the game would if it ever did not.

---@class MoonwellSystems.CodecWriter
---@field symbols string[]
---@field pending integer Bits not yet written as a symbol.
---@field count integer How many bits `pending` holds; under 6 between calls.

---@param writer MoonwellSystems.CodecWriter
---@param value integer From 0 to 2^width - 1.
---@param width integer At most 31.
local function put(writer, value, width)
    if width > 16 then
        put(writer, value >> 16, width - 16)
        value, width = value & 0xFFFF, 16
    end
    local pending, count = ((writer.pending << width) | value) & 0xFFFFFFFF, writer.count + width
    local symbols = writer.symbols
    while count >= 6 do
        count = count - 6
        local index = (pending >> count) & 63
        symbols[#symbols + 1] = ALPHABET:sub(index + 1, index + 1)
    end
    writer.pending, writer.count = pending & ((1 << count) - 1), count
end

---@param writer MoonwellSystems.CodecWriter
---@param field MoonwellSystems.CodecCompiledField
---@param value any
local function write(writer, field, value)
    local kind = field.kind
    if kind == 'integer' then
        put(writer, value - field.min, field.width)
    elseif kind == 'boolean' then
        put(writer, value and 1 or 0, 1)
    elseif kind == 'string' then
        put(writer, #value, field.width)
        for index = 1, #value do put(writer, value:byte(index), 8) end
    else
        put(writer, #value, field.width)
        for index = 1, #value do write(writer, field.of, value[index]) end
    end
end

---@class MoonwellSystems.CodecReader
---@field text string
---@field at integer The next symbol to read.
---@field pending integer
---@field count integer

---@param reader MoonwellSystems.CodecReader
---@param width integer At most 31.
---@return integer? value Nil when the symbols run out.
local function take(reader, width)
    if width > 16 then
        local high = take(reader, width - 16)
        local low = take(reader, 16)
        if not high or not low then return nil end
        return (high << 16) | low
    end
    local pending, count = reader.pending, reader.count
    while count < width do
        local symbol = VALUES[reader.text:byte(reader.at)]
        if not symbol then return nil end
        reader.at = reader.at + 1
        pending, count = (pending << 6) | symbol, count + 6
    end
    count = count - width
    reader.pending, reader.count = pending & ((1 << count) - 1), count
    return (pending >> count) & ((1 << width) - 1)
end

---@param reader MoonwellSystems.CodecReader
---@param field MoonwellSystems.CodecCompiledField
---@return any value Nil when the bits do not fit the field.
local function read(reader, field)
    local kind = field.kind
    if kind == 'integer' then
        local offset = take(reader, field.width)
        -- field.max - field.min cannot overflow: compileField checked it.
        if not offset or offset > field.max - field.min then return nil end
        return field.min + offset
    elseif kind == 'boolean' then
        local bit = take(reader, 1)
        if not bit then return nil end
        return bit == 1
    end
    local count = take(reader, field.width)
    if not count or count > field.maxLength then return nil end
    local values = {}
    if kind == 'string' then
        for index = 1, count do
            local byte = take(reader, 8)
            if not byte then return nil end
            values[index] = string.char(byte)
        end
        return table.concat(values)
    end
    for index = 1, count do
        local value = read(reader, field.of)
        if value == nil then return nil end
        values[index] = value
    end
    return values
end

-- The check value

---FNV-1a over `text`. The multiplication is meant to wrap at 32 bits; the mask makes a 64-bit Lua agree with the
---game's 32-bit one (measured in game, spec §4.2).
---@param hash integer
---@param text string
---@return integer
local function feed(hash, text)
    for index = 1, #text do hash = ((hash ~ text:byte(index)) * 16777619) & 0xFFFFFFFF end
    -- A zero byte ends every part, so "ab" + "c" and "a" + "bc" differ.
    return (hash * 16777619) & 0xFFFFFFFF
end

---30 bits that mix the secret, the binding and the body.
---@param secret string
---@param binding string
---@param body string
---@return integer
local function checkValue(secret, binding, body)
    local hash = feed(feed(feed(0x811c9dc5, secret), binding), body)
    for index = 1, #secret do hash = ((hash ~ secret:byte(index)) * 16777619) & 0xFFFFFFFF end
    -- The murmur3 finalizer: every input bit reaches every output bit.
    hash = hash ~ (hash >> 16)
    hash = (hash * 0x85ebca6b) & 0xFFFFFFFF
    hash = hash ~ (hash >> 13)
    hash = (hash * 0xc2b2ae35) & 0xFFFFFFFF
    hash = hash ~ (hash >> 16)
    return hash & 0x3FFFFFFF
end

---@param value integer 30 bits.
---@return string
local function checkSymbols(value)
    local writer = {symbols = {}, pending = 0, count = 0}
    put(writer, value, 30)
    return table.concat(writer.symbols)
end

-- Codec

---Checks every schema. Raises at the caller for a wrong option.
---@param options MoonwellSystems.CodecOptions
---@return MoonwellSystems.Codec
function Codec.new(options)
    if type(options) ~= 'table' then error('[systems] Codec.new: expected an options table', 2) end
    local version = whole(options.version)
    if not version or version < 1 or version > MAX_VERSION then
        error('[systems] Codec.new: expected a version from 1 to ' .. MAX_VERSION, 2)
    end
    local secret = options.secret
    if type(secret) ~= 'string' or secret == '' then
        error('[systems] Codec.new: expected a secret: a non-empty string', 2)
    end
    local schemas = options.schemas
    if type(schemas) ~= 'table' then error('[systems] Codec.new: expected a list of schemas', 2) end
    local compiled, maxLength = {}, 0
    for index = 1, #schemas do
        local schema, detail = compileSchema(schemas[index], version)
        if not schema then error('[systems] Codec.new: ' .. detail, 2) end
        local number = whole(schemas[index].version) --[[@as integer]]
        if compiled[number] then error('[systems] Codec.new: schema ' .. number .. ' is given twice', 2) end
        compiled[number] = schema
        -- The longest code of any version: an older code may be longer than a current one.
        local symbols = detail --[[@as integer]]
        if symbols > maxLength then maxLength = symbols end
    end
    if not compiled[version] then
        error('[systems] Codec.new: no schema for the current version ' .. version, 2)
    end
    return setmetatable({version = version, secret = secret, schemas = compiled, maxLength = maxLength}, Codec)
end

---The code for `data` under the current schema. Raises at the caller when the data does not fit, naming the field.
---@param data table One value per field of the current schema, and no other key.
---@param binding string? Mixed into the check value, typically the player's name; `decode` needs the same.
---@return string code
function Codec:encode(data, binding)
    local codec = Check.receiver(self, Codec, 'Codec', 'Codec.encode')
    if binding == nil then binding = '' end
    if type(binding) ~= 'string' then error('[systems] Codec.encode: expected a binding string', 2) end
    local schema = codec.schemas[codec.version]
    local copy, problem = fit(schema, data)
    if not copy then error('[systems] Codec.encode: ' .. tostring(problem), 2) end
    local writer = {symbols = {}, pending = 0, count = 0}
    put(writer, LAYOUT, 6)
    put(writer, codec.version, 14)
    for _, field in ipairs(schema.fields) do write(writer, field, copy[field.key]) end
    -- Zero bits fill the last symbol.
    if writer.count > 0 then put(writer, 0, 6 - writer.count) end
    local body = table.concat(writer.symbols)
    return body .. checkSymbols(checkValue(codec.secret, binding, body))
end

---The data of a code, migrated to the current version. It never raises for a bad code: codes come from files and
---from other machines.
---@param code string
---@param binding string? The binding the code was encoded with.
---@return table? data
---@return ('format'|'checksum'|'version'|'schema'|'migration')? reason
---@return string? detail The message of a `migration` failure.
function Codec:decode(code, binding)
    local codec = Check.receiver(self, Codec, 'Codec', 'Codec.decode')
    if binding == nil then binding = '' end
    if type(binding) ~= 'string' then error('[systems] Codec.decode: expected a binding string', 2) end
    if type(code) ~= 'string' or #code < 4 + CHECK_SYMBOLS or #code > MAX_SYMBOLS
        or not code:find('^[A-Za-z0-9_-]+$') then
        return nil, 'format'
    end
    local body = code:sub(1, -CHECK_SYMBOLS - 1)
    if checkSymbols(checkValue(codec.secret, binding, body)) ~= code:sub(-CHECK_SYMBOLS) then
        return nil, 'checksum'
    end
    local reader = {text = body, at = 1, pending = 0, count = 0}
    if take(reader, 6) ~= LAYOUT then return nil, 'format' end
    local version = take(reader, 14)
    local schema = codec.schemas[version]
    if not schema then return nil, 'version' end
    local data = {}
    for _, field in ipairs(schema.fields) do
        local value = read(reader, field)
        if value == nil then return nil, 'schema' end
        data[field.key] = value
    end
    -- Nothing may be left but the zero bits that filled the last symbol.
    if reader.at <= #body or reader.pending ~= 0 then return nil, 'schema' end
    while version < codec.version do
        local migrate = schema.migrate
        if not migrate then return nil, 'migration', 'schema ' .. version .. ' has no migrate function' end
        local ok, migrated = pcall(migrate, data)
        if not ok then return nil, 'migration', tostring(migrated) end
        version = version + 1
        schema = codec.schemas[version]
        if not schema then return nil, 'migration', 'no schema for version ' .. version end
        local copy, problem = fit(schema, migrated)
        if not copy then return nil, 'migration', 'version ' .. version .. ': ' .. tostring(problem) end
        data = copy
    end
    return data
end

---The current version: the one `encode` writes.
---@return integer
function Codec:getVersion() return Check.receiver(self, Codec, 'Codec', 'Codec.getVersion').version end

---The longest code any of its schemas can produce, in symbols: the longest it writes or reads.
---@return integer
function Codec:getMaxLength() return Check.receiver(self, Codec, 'Codec', 'Codec.getMaxLength').maxLength end

return Codec
