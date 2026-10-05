local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Fields = require('systems.internal.fields')
local Ordered = require('systems.internal.ordered')
local BuffStore = require('systems.buffs')

---Keeps an aura buff on the Units a query returns. Each emitter (source) owns its instances, so two auras with the
---same definition never remove each other's buffs. The query decides range, team and visibility, and should return
---Units in the engine's enumeration order (for example group:getUnits()), which is the same on every machine.
---@class MoonwellSystems.Aura
---@field package store MoonwellSystems.BuffStore
---@field package definition MoonwellSystems.BuffDefinition
---@field package source any
---@field package query fun(): MoonwellWrappers.Unit[]
---@field package interval number
---@field package onError (fun(message: string): ...)?
---@field package members MoonwellSystems.Ordered Unit -> MoonwellSystems.Buff
---@field package stop fun()?
---@field package disposed boolean
local Aura = {}
Aura.__index = Aura

---@class MoonwellSystems.AuraOptions
---@field store MoonwellSystems.BuffStore
---@field definition MoonwellSystems.BuffDefinition kind 'aura'.
---@field source any The emitter.
---@field query fun(): MoonwellWrappers.Unit[]
---@field interval number? Seconds between updates once started. Default 0.5.
---@field onError (fun(message: string): ...)? Receives query and apply failures; default prints them.

local function auraDefinition(value) return type(value) == 'table' and value.kind == 'aura' end

local OPTIONS = {
    store = {Fields.class(BuffStore, 'a BuffStore'), required = true},
    definition = {Fields.test(auraDefinition, 'an aura buff definition'), required = true},
    source = {'any'},
    query = {'function', required = true},
    interval = {'positive', default = 0.5},
    onError = {'function'},
}

---@param options MoonwellSystems.AuraOptions
---@return MoonwellSystems.Aura
function Aura.new(options)
    local read = Fields.options(options, OPTIONS, 'Aura.new')
    return setmetatable({store = read.store, definition = read.definition, source = read.source, query = read.query,
        interval = read.interval, onError = read.onError, members = Ordered.new(), disposed = false}, Aura)
end

---Reconciles once: removes the buff from Units the query no longer returns and applies it to new ones.
function Aura:update()
    local aura = Check.receiver(self, Aura, 'Aura', 'Aura.update')
    if aura.disposed then return end
    local wanted
    if not Callback.call('Aura query', aura.onError, function() wanted = aura.query() end) then return end
    if type(wanted) ~= 'table' then
        Callback.call('Aura query', aura.onError, error, 'the query must return an array of Units', 0)
        return
    end
    local present = {}
    for _, unit in ipairs(wanted) do present[unit] = true end
    aura.members:each(function(unit, buff)
        if not present[unit] then
            aura.members:delete(unit)
            buff:dispose('source-lost')
        end
    end)
    for _, unit in ipairs(wanted) do
        if aura.disposed then break end
        local current = aura.members:get(unit)
        if not (current and current:isActive()) then
            local applied
            if Callback.call('Aura apply', aura.onError, function()
                applied = aura.store:apply(unit, aura.definition, aura.source)
            end) then
                if aura.disposed then applied:dispose('source-lost') else aura.members:set(unit, applied) end
            end
        end
    end
end

---Updates now and then every `interval` seconds on the store's scheduler. Starting again restarts the timer.
---@return MoonwellSystems.Aura
function Aura:start()
    local aura = Check.receiver(self, Aura, 'Aura', 'Aura.start')
    if aura.disposed then error('[systems] Aura.start: the aura is disposed', 2) end
    if aura.stop then aura.stop() end
    aura:update()
    aura.stop = aura.store:getScheduler():every(aura.interval, function() aura:update() end)
    return aura
end

---Stops the timer and removes every buff this aura applied ('source-lost'). Idempotent.
function Aura:dispose()
    local aura = Check.receiver(self, Aura, 'Aura', 'Aura.dispose')
    if aura.disposed then return end
    aura.disposed = true
    if aura.stop then aura.stop(); aura.stop = nil end
    local members = aura.members
    aura.members = Ordered.new()
    members:each(function(_, buff) buff:dispose('source-lost') end)
end

return Aura
