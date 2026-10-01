local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
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
---@field package onError (fun(message: string): ...)?
---@field package members MoonwellSystems.Ordered Unit -> MoonwellSystems.Buff
---@field package stop fun()?
---@field package disposed boolean
local Aura = {}
Aura.__index = Aura

---@param store MoonwellSystems.BuffStore
---@param definition MoonwellSystems.BuffDefinition kind 'aura'.
---@param source any The emitter.
---@param query fun(): MoonwellWrappers.Unit[]
---@param onError (fun(message: string): ...)? Receives query and apply failures; default prints them.
---@return MoonwellSystems.Aura
function Aura.new(store, definition, source, query, onError)
    Check.receiver(store, BuffStore, 'BuffStore', 'Aura.new')
    if type(definition) ~= 'table' or definition.kind ~= 'aura' then
        error('[systems] Aura.new: expected an aura buff definition', 2)
    end
    Callback.check(query, 'Aura.new')
    Callback.optional(onError, 'Aura.new')
    return setmetatable({store = store, definition = definition, source = source, query = query, onError = onError,
        members = Ordered.new(), disposed = false}, Aura)
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
            buff:remove('source-lost')
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
                if aura.disposed then applied:remove('source-lost') else aura.members:set(unit, applied) end
            end
        end
    end
end

---Updates now and then every `interval` seconds on the store's scheduler. Starting again restarts the timer.
---@param interval number? Default 0.5.
---@return MoonwellSystems.Aura
function Aura:start(interval)
    local aura = Check.receiver(self, Aura, 'Aura', 'Aura.start')
    if aura.disposed then error('[systems] Aura.start: the aura is disposed', 2) end
    if interval == nil then interval = 0.5 end
    if not (Check.finite(interval) and interval > 0) then
        error('[systems] Aura.start: expected a finite positive interval', 2)
    end
    if aura.stop then aura.stop() end
    aura:update()
    aura.stop = aura.store:getScheduler():every(interval, function() aura:update() end)
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
    members:each(function(_, buff) buff:remove('source-lost') end)
end

return Aura
