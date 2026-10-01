---Local save files through the Preload natives (spec 2026-10-01 release 5 §6.1). A file is JASS that the game runs
---with Preloader; each of its lines hands one chunk to Lua through the tooltip, or the extended tooltip, of a borrowed
---ability. Raw natives by design (Part 1 §3). Everything here is local to the machine that calls it, and creates no
---handle (measured on 3.0.0.24268). No argument checks: systems.savefile is the checked public module.
local Files = {}

---Characters per line. With its JASS around it, a line's Preload argument is at most 248 characters; Preload keeps
---259, and a cut line can crash the game.
local CHUNK = 190
local MAGIC = 'MWS1'
---The first carrier holds this while the file runs; still there afterwards, no file ran.
local MARKER = 'MWS?'
---The header is the magic, a dot, the code's length (at most 4 digits) and a dot.
local HEADER = #MAGIC + 6

---Carriers are numbered from 0: the tooltip, then the extended tooltip, of each ability in turn.
---@param abilities integer[]
---@param carrier integer
---@return string?
local function get(abilities, carrier)
    local ability = abilities[carrier // 2 + 1]
    if carrier % 2 == 0 then return BlzGetAbilityTooltip(ability, 0) end
    return BlzGetAbilityExtendedTooltip(ability, 0)
end

---@param abilities integer[]
---@param carrier integer
---@param text string
local function set(abilities, carrier, text)
    local ability = abilities[carrier // 2 + 1]
    if carrier % 2 == 0 then
        BlzSetAbilityTooltip(ability, text, 0)
    else
        BlzSetAbilityExtendedTooltip(ability, text, 0)
    end
end

---The longest code that fits the carriers of `abilities`.
---@param abilities integer[]
---@return integer
function Files.capacity(abilities) return #abilities * 2 * CHUNK - HEADER end

---The first ability whose tooltip or extended tooltip does not keep a text, or nil when all do. Every text is
---restored.
---@param abilities integer[]
---@return integer? ability
function Files.verify(abilities)
    for carrier = 0, #abilities * 2 - 1 do
        local original = get(abilities, carrier)
        set(abilities, carrier, MARKER)
        local kept = get(abilities, carrier) == MARKER
        if original then set(abilities, carrier, original) end
        if not kept then return abilities[carrier // 2 + 1] end
    end
    return nil
end

---Writes `code` to the file at `path`, replacing it. `code` holds only the codec's 64 symbols.
---@param path string
---@param abilities integer[]
---@param code string
function Files.write(path, abilities, code)
    local text = MAGIC .. '.' .. #code .. '.' .. code
    -- PreloadGenStart does not drop lines buffered before it: clear first.
    PreloadGenClear()
    PreloadGenStart()
    local carrier = 0
    for at = 1, #text, CHUNK do
        local native = carrier % 2 == 0 and 'BlzSetAbilityTooltip' or 'BlzSetAbilityExtendedTooltip'
        -- The argument closes the generated `call Preload( "` line, adds one of its own and comments out the rest.
        Preload('")\ncall ' .. native .. '(' .. string.format('%d', abilities[carrier // 2 + 1]) .. ', "'
            .. text:sub(at, at + CHUNK - 1) .. '", 0)\n//')
        carrier = carrier + 1
    end
    PreloadGenEnd(path)
    PreloadGenClear()
end

---The code in the carriers after the file ran, or nil for anything `write` does not produce.
---@param abilities integer[]
---@param first string? The first carrier's text.
---@return string?
local function parse(abilities, first)
    if type(first) ~= 'string' then return nil end
    local digits = first:match('^' .. MAGIC .. '%.([1-9]%d?%d?%d?)%.')
    if not digits then return nil end
    local length = math.tointeger(tonumber(digits)) --[[@as integer]]
    local header = #MAGIC + 2 + #digits
    local total = header + length
    if length > Files.capacity(abilities) then return nil end
    local parts = {first}
    for carrier = 1, (total - 1) // CHUNK do
        -- A carrier without a text adds nothing, and the length below then fails.
        parts[#parts + 1] = get(abilities, carrier)
    end
    local text = table.concat(parts)
    if #text ~= total then return nil end
    local code = text:sub(header + 1)
    if not code:find('^[A-Za-z0-9_-]+$') then return nil end
    return code
end

---Runs the file at `path` and returns the code it holds. Every carrier's text is restored before it returns.
---@param path string
---@param abilities integer[]
---@return string? code
---@return ('missing'|'damaged')? reason
function Files.read(path, abilities)
    local count = #abilities * 2
    local originals = {}
    for carrier = 0, count - 1 do originals[carrier] = get(abilities, carrier) end
    set(abilities, 0, MARKER)
    Preloader(path)
    local first = get(abilities, 0)
    local code, reason
    if first == MARKER then
        reason = 'missing'
    else
        code = parse(abilities, first)
        if not code then reason = 'damaged' end
    end
    for carrier = 0, count - 1 do
        if originals[carrier] then set(abilities, carrier, originals[carrier]) end
    end
    return code, reason
end

return Files
