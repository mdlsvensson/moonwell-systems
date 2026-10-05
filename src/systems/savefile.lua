local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Fields = require('systems.internal.fields')
local Files = require('systems.internal.preload')
local Codec = require('systems.codec')
local Scheduler = require('systems.scheduler')
local Sync = require('systems.sync')
local Player = require('wrappers.player')

---A player's saved data, in a local file on that player's machine (spec 2026-10-01 release 5 §6). `save` and `load`
---are called on every machine, like any other game code: the steps that run on one machine only are inside, and a
---load's callback runs on every machine at the same moment.
---@class MoonwellSystems.Savefile
---@field package codec MoonwellSystems.Codec
---@field package folder string
---@field package abilities integer[] Their tooltips carry a file's text while it is read.
---@field package onError (fun(message: string): ...)?
---@field package sync MoonwellSystems.Sync
---@field package started boolean
---@field package disposed boolean
local Savefile = {}
Savefile.__index = Savefile

---@class MoonwellSystems.SavefileOptions
---@field clock MoonwellSystems.Scheduler Times loads out; it must run on every machine alike.
---@field codec MoonwellSystems.Codec
---@field folder string The folder under CustomMapData; 1 to 32 letters, digits, `-` or `_`.
---@field prefix string? The sync prefix. Default `"mwsave"`.
---@field timeout number? Scheduler seconds a load waits for the player's machine. Default 10.
---@field abilities integer[]? Ability ids whose tooltips carry the file; default 24 standard unit abilities.
---@field onError (fun(message: string): ...)?

---Standard unit abilities whose tooltip and extended tooltip keep text (measured on 3.0.0.24268).
local DEFAULT = {'Amls', 'Aroc', 'Amic', 'Amil', 'Aclf', 'Acmg', 'Adef', 'Adis', 'Afbt', 'Afbk', 'Aflk', 'Agyb', 'Agyv',
    'Ahea', 'Ainf', 'Aivs', 'Amdf', 'Aply', 'Asth', 'Aslo', 'Asps', 'Afsh', 'Absk', 'Ablo'}
---What the player's machine answers for a file that does not hold what `save` writes. Not one of a code's symbols.
local DAMAGED = '!'

---The ability id of a four-letter code, as the game's FourCC gives it. Pure, so nothing is called at import.
---@param code string
---@return integer
local function id(code)
    local a, b, c, d = code:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

---@param ability integer
---@return string
local function code(ability)
    return string.char((ability >> 24) & 255, (ability >> 16) & 255, (ability >> 8) & 255, ability & 255)
end

---@param value unknown
---@return boolean
local function abilityList(value)
    if type(value) ~= 'table' or #value < 1 then return false end
    local seen = {}
    for index = 1, #value do
        local ability = value[index]
        if not Check.integer(ability) or ability < 1 or seen[ability] then return false end
        seen[ability] = true
    end
    return true
end

local OPTIONS = {
    clock = {Fields.class(Scheduler, 'a Scheduler'), required = true},
    codec = {Fields.class(Codec, 'a Codec'), required = true},
    folder = {'identifier', required = true},
    prefix = {'identifier', default = 'mwsave'},
    timeout = {'positive', default = 10},
    abilities = {Fields.test(abilityList, 'a list of ability ids, each once')},
    onError = {'function'},
}

---@param options MoonwellSystems.SavefileOptions
---@return MoonwellSystems.Savefile
function Savefile.new(options)
    local read = Fields.options(options, OPTIONS, 'Savefile.new')
    local abilities = {}
    if read.abilities == nil then
        for index, name in ipairs(DEFAULT) do abilities[index] = id(name) end
    else
        for index, ability in ipairs(read.abilities) do abilities[index] = math.tointeger(ability) end
    end
    local codec = read.codec --[[@as MoonwellSystems.Codec]]
    local longest = codec:getMaxLength()
    if longest > Files.capacity(abilities) then
        error('[systems] Savefile.new: the codec\'s longest code is ' .. longest .. ' symbols, but the abilities hold '
            .. Files.capacity(abilities), 2)
    end
    local ok, sync = pcall(Sync.new, {clock = read.clock, prefix = read.prefix, timeout = read.timeout,
        maxLength = longest, onError = read.onError})
    if not ok then error('[systems] Savefile.new: ' .. Callback.reason(sync), 2) end
    return setmetatable({codec = codec, folder = read.folder, abilities = abilities, onError = read.onError,
        sync = sync, started = false, disposed = false}, Savefile)
end

---The receiver of a method that needs a started, live system, and the file path of `slot`; raises at the public
---function's caller.
---@param self unknown
---@param operation string
---@param player unknown
---@param slot unknown
---@return MoonwellSystems.Savefile system
---@return string path
local function ready(self, operation, player, slot)
    local system = Check.receiver(self, Savefile, 'Savefile', operation, 1)
    if system.disposed then error('[systems] ' .. operation .. ': the system is disposed', 3) end
    if not system.started then error('[systems] ' .. operation .. ': call start() first', 3) end
    if getmetatable(player) ~= Player then error('[systems] ' .. operation .. ': expected Player', 3) end
    if not Check.identifier(slot) then
        error('[systems] ' .. operation .. ': expected a slot of 1 to 32 letters, digits, - or _', 3)
    end
    return system, system.folder .. '\\' .. slot .. '.pld'
end

---Checks that every borrowed ability can carry text, and starts listening for loads. Call it once, on every
---machine, before the first `save` or `load`. Idempotent.
function Savefile:start()
    local system = Check.receiver(self, Savefile, 'Savefile', 'Savefile.start')
    if system.disposed then error('[systems] Savefile.start: the system is disposed', 2) end
    if system.started then return end
    local bad = Files.verify(system.abilities)
    if bad then error('[systems] Savefile.start: ability \'' .. code(bad) .. '\' cannot carry text', 2) end
    system.sync:start()
    system.started = true
end

---Saves `data` for `player` under `slot`. Call it on every machine: data that does not fit the codec's schema raises
---on all of them alike, and only the player's own machine writes the file. The code is bound to the player's name.
---@param player MoonwellWrappers.Player
---@param slot string 1 to 32 letters, digits, `-` or `_`.
---@param data table
function Savefile:save(player, slot, data)
    local system, path = ready(self, 'Savefile.save', player, slot)
    local ok, encoded = pcall(system.codec.encode, system.codec, data, player:getName())
    if not ok then error('[systems] Savefile.save: ' .. Callback.reason(encoded), 2) end
    if player:isLocal() then Files.write(path, system.abilities, encoded) end
end

---Loads `player`'s data from `slot`. Call it on every machine: the player's machine reads the file and sends its
---code, and `callback` runs later on every machine at the same moment, with the data or with nil and a reason.
---@param player MoonwellWrappers.Player
---@param slot string
---@param callback fun(data: table?, reason: string?): ... Reasons: `missing`, `damaged`, `format`, `checksum`,
---`version`, `schema`, `migration`, `error`, `absent`, `timeout`, `disposed`.
function Savefile:load(player, slot, callback)
    local system, path = ready(self, 'Savefile.load', player, slot)
    Callback.check(callback, 'Savefile.load')
    local onError = system.onError
    system.sync:ask(player, function()
        local found, why = Files.read(path, system.abilities)
        if why == 'damaged' then return DAMAGED end
        return found
    end, function(text, why)
        local data
        if text == DAMAGED then
            why = 'damaged'
        elseif text then
            local detail
            data, why, detail = system.codec:decode(text, player:getName())
            if detail then Callback.report('Savefile migration', onError, detail) end
        elseif why == 'none' then
            why = 'missing'
        end
        Callback.call('Savefile callback', onError, callback, data, why)
    end)
end

---Ends the open loads with 'disposed' and stops listening. `save`, `load` and `start` raise afterwards. Idempotent.
function Savefile:dispose()
    local system = Check.receiver(self, Savefile, 'Savefile', 'Savefile.dispose')
    if system.disposed then return end
    system.disposed = true
    system.sync:dispose()
end

return Savefile
