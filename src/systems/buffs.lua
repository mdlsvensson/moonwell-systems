local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Fields = require('systems.internal.fields')
local Ordered = require('systems.internal.ordered')
local Scheduler = require('systems.scheduler')
local Unit = require('wrappers.unit')

---Script buffs on Units: stacking, expiry, periodic ticks and owned effects that are released exactly once. The store
---polls its units and clears buffs from removed and dead ones.
---@class MoonwellSystems.BuffStore
---@field package clock MoonwellSystems.Scheduler
---@field package onError (fun(message: string): ...)?
---@field package units MoonwellSystems.Ordered Unit -> MoonwellSystems.Buff[], in first-buffed order.
---@field package disposed boolean
---@field package stopPoll fun()
---@field package visit fun(unit: MoonwellWrappers.Unit)
local BuffStore = {}
BuffStore.__index = BuffStore

---@alias MoonwellSystems.BuffRemoval
---| 'expired'
---| 'dispelled'
---| 'replaced'
---| 'death'
---| 'removed'
---| 'source-lost'
---| 'disposed'
---| 'error'

---A buff's rules and callbacks. A definition is checked when it is first applied and read as it is from then on: do
---not change it afterwards. A key that is not listed here is left alone, for the map's own fields.
---@class MoonwellSystems.BuffDefinition
---@field id string One instance per (unit, id, source).
---@field kind 'active'|'passive'|'aura'
---@field stacking ('refresh'|'replace'|'stack'|'independent')? Default 'refresh'.
---@field maxStacks integer? Default 1.
---@field duration number? Seconds; nil for a permanent buff.
---@field removeOnDeath boolean? Default true, except passive buffs.
---@field interval number? Seconds between onTick calls.
---@field onApply (fun(buff: MoonwellSystems.Buff): ...)?
---@field onStacks (fun(buff: MoonwellSystems.Buff, previous: integer): ...)?
---@field onTick (fun(buff: MoonwellSystems.Buff): ...)?
---@field onRemove (fun(buff: MoonwellSystems.Buff, reason: MoonwellSystems.BuffRemoval): ...)?

---@class MoonwellSystems.BuffStoreOptions
---@field clock MoonwellSystems.Scheduler Drives expiry, ticks and the poll.
---@field onError (fun(message: string): ...)? Receives callback and release failures; default prints them.
---@field pollInterval number? Seconds between checks for removed and dead units; default 0.25.

---A buff on one unit. `data` is free for the buff's own state.
---@class MoonwellSystems.Buff
---@field data table
---@field package store MoonwellSystems.BuffStore
---@field package unit MoonwellWrappers.Unit
---@field package definition MoonwellSystems.BuffDefinition
---@field package source any
---@field package layers {cancel: fun()?, expires: integer?}[]
---@field package releases (fun(): ...)[]
---@field package sharedCancel fun()?
---@field package sharedExpires integer?
---@field package tickCancel fun()?
---@field package live boolean
local Buff = {}
Buff.__index = Buff

local REASONS = {expired = true, dispelled = true, replaced = true, death = true, removed = true,
    ['source-lost'] = true, disposed = true, error = true}

local OPTIONS = {
    clock = {Fields.class(Scheduler, 'a Scheduler'), required = true},
    onError = {'function'},
    pollInterval = {'positive', default = 0.25},
}

local DEFINITION = {
    id = {'string', required = true},
    kind = {Fields.enum({'active', 'passive', 'aura'}), required = true},
    stacking = {Fields.enum({'refresh', 'replace', 'stack', 'independent'})},
    maxStacks = {Fields.integer(1)},
    duration = {'positive'},
    interval = {'positive'},
    removeOnDeath = {'boolean'},
    onApply = {'function'},
    onStacks = {'function'},
    onTick = {'function'},
    onRemove = {'function'},
}

---Definitions already checked: a definition is read when first applied (README).
local checked = setmetatable({}, {__mode = 'k'})

local function removedOnDeath(definition)
    if definition.removeOnDeath ~= nil then return definition.removeOnDeath end
    return definition.kind ~= 'passive'
end

local function detach(buff)
    local units = buff.store.units
    local list = units:get(buff.unit)
    if not list then return end
    for index = #list, 1, -1 do
        if list[index] == buff then table.remove(list, index) end
    end
    if #list == 0 then units:delete(buff.unit) end
end

---Ends a buff: cancels its timers, runs its releases in reverse, then onRemove. Idempotent.
local function finish(buff, reason)
    if not buff.live then return end
    buff.live = false
    detach(buff)
    if buff.sharedCancel then buff.sharedCancel(); buff.sharedCancel = nil end
    if buff.tickCancel then buff.tickCancel(); buff.tickCancel = nil end
    for _, layer in ipairs(buff.layers) do if layer.cancel then layer.cancel() end end
    buff.layers = {}
    local releases, onError = buff.releases, buff.store.onError
    buff.releases = {}
    for index = #releases, 1, -1 do Callback.call('Buff release', onError, releases[index]) end
    local onRemove = buff.definition.onRemove
    if onRemove then Callback.call('Buff release', onError, onRemove, buff, reason) end
end

---Runs a definition callback; a failure removes the buff with reason 'error'.
local function run(buff, callback, ...)
    if callback and buff.live and not Callback.call('Buff callback', buff.store.onError, callback, buff, ...) then
        finish(buff, 'error')
    end
end

local function addStack(buff)
    if not buff.live then return end
    local definition, clock = buff.definition, buff.store.clock
    local policy, previous = definition.stacking or 'refresh', #buff.layers
    local duration = definition.duration
    if previous == 0 or ((policy == 'stack' or policy == 'independent') and previous < (definition.maxStacks or 1)) then
        local layer = {}
        buff.layers[#buff.layers + 1] = layer
        if policy == 'independent' and duration then
            layer.expires = clock:getTick() + clock:ticks(duration)
            layer.cancel = clock:after(duration, function()
                if not buff.live then return end
                local before = #buff.layers
                for index = #buff.layers, 1, -1 do
                    if buff.layers[index] == layer then table.remove(buff.layers, index) end
                end
                if #buff.layers == 0 then finish(buff, 'expired') else run(buff, definition.onStacks, before) end
            end)
        end
    end
    -- A capped independent application extends nothing.
    if policy ~= 'independent' and duration then
        if buff.sharedCancel then buff.sharedCancel() end
        buff.sharedExpires = clock:getTick() + clock:ticks(duration)
        buff.sharedCancel = clock:after(duration, function() finish(buff, 'expired') end)
    end
    if previous > 0 and previous ~= #buff.layers then run(buff, definition.onStacks, previous) end
end

---Ticking starts before the first stack's expiry timer, so on a shared deadline the tick runs first.
local function startTicking(buff)
    local definition = buff.definition
    if not (definition.interval and definition.onTick) then return end
    buff.tickCancel = buff.store.clock:every(definition.interval, function() run(buff, definition.onTick) end)
end

local function find(store, unit, id, source)
    for _, buff in ipairs(store.units:get(unit) or {}) do
        if buff.definition.id == id and buff.source == source then return buff end
    end
    return nil
end

local function clear(store, unit, reason)
    local list = store.units:get(unit)
    if not list then return end
    for _, buff in ipairs(table.move(list, 1, #list, 1, {})) do
        if reason ~= 'death' or removedOnDeath(buff.definition) then finish(buff, reason) end
    end
end

---@param store MoonwellSystems.BuffStore
---@param unit MoonwellWrappers.Unit
local function check(store, unit)
    if unit:isDisposed() or not unit:exists() then
        clear(store, unit, 'removed')
    elseif not unit:isAlive() then
        clear(store, unit, 'death')
    end
end

---@param options MoonwellSystems.BuffStoreOptions
---@return MoonwellSystems.BuffStore
function BuffStore.new(options)
    local read = Fields.options(options, OPTIONS, 'BuffStore.new')
    local store = setmetatable({clock = read.clock, onError = read.onError, units = Ordered.new(), disposed = false},
        BuffStore)
    store.visit = function(unit) Callback.call('Buff poll', store.onError, check, store, unit) end
    store.stopPoll = read.clock:every(read.pollInterval, function() store.units:each(store.visit) end)
    return store
end

---Applies a buff, or applies it again according to its stacking policy.
---@param unit MoonwellWrappers.Unit
---@param definition MoonwellSystems.BuffDefinition
---@param source any? Who applied it; buffs with the same id and different sources are separate. Default nil.
---@return MoonwellSystems.Buff
function BuffStore:apply(unit, definition, source)
    local store = Check.receiver(self, BuffStore, 'BuffStore', 'BuffStore.apply')
    if store.disposed then error('[systems] BuffStore.apply: the store is disposed', 2) end
    Check.receiver(unit, Unit, 'Unit', 'BuffStore.apply')
    if not checked[definition] then
        Fields.request(definition, DEFINITION, 'BuffStore.apply', 'a buff definition table', 0, true)
        checked[definition] = true
    end
    local existing = find(store, unit, definition.id, source)
    if existing then
        if existing.definition ~= definition then
            error('[systems] BuffStore.apply: use the same definition for a given id and source', 2)
        end
        if (definition.stacking or 'refresh') ~= 'replace' then
            addStack(existing)
            return existing
        end
        finish(existing, 'replaced')
        -- onRemove may have applied a replacement; never create two instances for one key.
        local replacement = find(store, unit, definition.id, source)
        if replacement then return replacement end
        if store.disposed then error('[systems] BuffStore.apply: the store is disposed', 2) end
    end
    ---@type MoonwellSystems.Buff
    local buff = setmetatable({store = store, unit = unit, definition = definition, source = source, layers = {},
        releases = {}, live = true, data = {}}, Buff)
    local list = store.units:get(unit)
    if list then list[#list + 1] = buff else store.units:set(unit, {buff}) end
    startTicking(buff)
    addStack(buff)
    run(buff, definition.onApply)
    return buff
end

---The buff with this id from `source`; with source nil, the first with this id from any source.
---@return MoonwellSystems.Buff?
function BuffStore:get(unit, id, source)
    local store = Check.receiver(self, BuffStore, 'BuffStore', 'BuffStore.get')
    for _, buff in ipairs(store.units:get(unit) or {}) do
        if buff.definition.id == id and (source == nil or buff.source == source) then return buff end
    end
    return nil
end

---@return boolean
function BuffStore:has(unit, id, source)
    Check.receiver(self, BuffStore, 'BuffStore', 'BuffStore.has')
    return self:get(unit, id, source) ~= nil
end

---Stacks of this id summed over every source.
---@return integer
function BuffStore:stacks(unit, id)
    local store = Check.receiver(self, BuffStore, 'BuffStore', 'BuffStore.stacks')
    local total = 0
    for _, buff in ipairs(store.units:get(unit) or {}) do
        if buff.definition.id == id then total = total + #buff.layers end
    end
    return total
end

---The unit's buffs in application order, as a new array.
---@return MoonwellSystems.Buff[]
function BuffStore:list(unit)
    local list = Check.receiver(self, BuffStore, 'BuffStore', 'BuffStore.list').units:get(unit) or {}
    return table.move(list, 1, #list, 1, {})
end

---Removes the unit's buffs. With reason 'death', buffs that survive death are kept.
---@param reason MoonwellSystems.BuffRemoval? Default 'removed'.
function BuffStore:clearUnit(unit, reason)
    local store = Check.receiver(self, BuffStore, 'BuffStore', 'BuffStore.clearUnit')
    if reason == nil then reason = 'removed' end
    if not REASONS[reason] then error('[systems] BuffStore.clearUnit: expected a removal reason', 2) end
    clear(store, unit, reason)
end

---Removes every buff applied by `source`, with reason 'source-lost'.
function BuffStore:clearSource(source)
    local store = Check.receiver(self, BuffStore, 'BuffStore', 'BuffStore.clearSource')
    local matched = {}
    store.units:each(function(_, list)
        for _, buff in ipairs(list) do if buff.source == source then matched[#matched + 1] = buff end end
    end)
    for _, buff in ipairs(matched) do finish(buff, 'source-lost') end
end

---@return MoonwellSystems.Scheduler
function BuffStore:getScheduler()
    return Check.receiver(self, BuffStore, 'BuffStore', 'BuffStore.getScheduler').clock
end

---Stops the poll and removes every buff with reason 'disposed'. Applying afterwards raises. Idempotent.
function BuffStore:dispose()
    local store = Check.receiver(self, BuffStore, 'BuffStore', 'BuffStore.dispose')
    if store.disposed then return end
    store.disposed = true
    store.stopPoll()
    local all = {}
    store.units:each(function(_, list) for _, buff in ipairs(list) do all[#all + 1] = buff end end)
    for _, buff in ipairs(all) do finish(buff, 'disposed') end
end

---@return MoonwellWrappers.Unit
function Buff:getUnit() return Check.receiver(self, Buff, 'Buff', 'Buff.getUnit').unit end
---@return any
function Buff:getSource() return Check.receiver(self, Buff, 'Buff', 'Buff.getSource').source end
---@return string
function Buff:getId() return Check.receiver(self, Buff, 'Buff', 'Buff.getId').definition.id end
---@return MoonwellSystems.BuffDefinition
function Buff:getDefinition() return Check.receiver(self, Buff, 'Buff', 'Buff.getDefinition').definition end
---False once the buff has ended.
---@return boolean
function Buff:isActive() return Check.receiver(self, Buff, 'Buff', 'Buff.isActive').live end
---@return integer
function Buff:getStacks() return #Check.receiver(self, Buff, 'Buff', 'Buff.getStacks').layers end

---Seconds until the buff (or its last independent stack) expires: 0 once ended, nil if permanent.
---@return number?
function Buff:getRemaining()
    local buff = Check.receiver(self, Buff, 'Buff', 'Buff.getRemaining')
    if not buff.live then return 0 end
    local expires = buff.sharedExpires
    for _, layer in ipairs(buff.layers) do
        if layer.expires and (expires == nil or layer.expires > expires) then expires = layer.expires end
    end
    if expires == nil then return nil end
    local clock = buff.store.clock
    return math.max(0, expires - clock:getTick()) * clock:getStep()
end

---Registers the inverse of a change the buff made. Runs at once if the buff has ended.
---@param release fun(): ...
function Buff:own(release)
    local buff = Check.receiver(self, Buff, 'Buff', 'Buff.own')
    Callback.check(release, 'Buff.own')
    if buff.live then
        buff.releases[#buff.releases + 1] = release
    else
        Callback.call('Buff release', buff.store.onError, release)
    end
end

---Ends the buff: timers, releases in reverse, then onRemove. Idempotent.
---@param reason MoonwellSystems.BuffRemoval? Default 'dispelled'.
function Buff:dispose(reason)
    local buff = Check.receiver(self, Buff, 'Buff', 'Buff.dispose')
    if reason == nil then reason = 'dispelled' end
    if not REASONS[reason] then error('[systems] Buff.dispose: expected a removal reason', 2) end
    finish(buff, reason)
end

return BuffStore
