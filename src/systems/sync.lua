local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')
local Scheduler = require('systems.scheduler')
local Player = require('wrappers.player')
local Messages = require('wrappers.sync')

---Asks one player's machine for a local value and hands the answer to every machine at the same moment (spec
---2026-10-01 release 5 §5): the safe way to share a save file's code, a local clock or anything else that only one
---machine knows. `ask` is called on every machine, like any other game code; only `read` runs on one.
---@class MoonwellSystems.Sync
---@field package clock MoonwellSystems.Scheduler
---@field package prefix string
---@field package timeout number
---@field package maxLength integer
---@field package onError (fun(message: string): ...)?
---@field package requests table<integer, MoonwellSystems.SyncRequest> Open requests by number; never iterated.
---@field package nextRequest integer
---@field package listener MoonwellWrappers.SyncListener? Nil until start().
---@field package disposed boolean
local Sync = {}
Sync.__index = Sync

---@class MoonwellSystems.SyncRequest
---@field id integer
---@field player MoonwellWrappers.Player
---@field receive fun(text: string?, reason: string?): ...
---@field cancel (fun())? Cancels the scheduler task that ends the request.
---@field pieces string[]
---@field count integer The number of pieces, once the first arrived; 0 before.
---@field received integer
---@field length integer

---@class MoonwellSystems.SyncOptions
---@field prefix string? The sync prefix; 1 to 32 letters, digits, `-` or `_`. Default `"mwsync"`.
---@field timeout number? Scheduler seconds a request waits for its answer. Default 10.
---@field maxLength integer? The longest text an answer may be, in bytes; at most 65535. Default 8192.
---@field onError (fun(message: string): ...)?

---Bytes of text per packet. With its header a packet stays under the 255 bytes a sync message keeps.
local PIECE = 220
local MAX_LENGTH = 65535

---Ends an open request: forgets it, cancels its timeout and runs `receive` behind the boundary.
---@param system MoonwellSystems.Sync
---@param request MoonwellSystems.SyncRequest
---@param text string?
---@param reason string?
local function finish(system, request, text, reason)
    system.requests[request.id] = nil
    local cancel = request.cancel
    request.cancel = nil
    if cancel then cancel() end
    Callback.call('Sync receive', system.onError, request.receive, text, reason)
end

---Sends one packet from this machine. A refused send is reported; the request then ends by its timeout.
---@param system MoonwellSystems.Sync
---@param packet string
local function send(system, packet)
    if not Messages.send(system.prefix, packet) then
        Callback.report('Sync send', system.onError, 'the game refused a sync message')
    end
end

---Runs `read` on this machine and sends what it returned: the text in pieces, or one packet that says why there is
---none.
---@param system MoonwellSystems.Sync
---@param request MoonwellSystems.SyncRequest
---@param read fun(): string?
local function answer(system, request, read)
    local id = request.id
    local ok, text = pcall(read)
    if not ok then
        Callback.report('Sync read', system.onError, text)
        send(system, id .. '.0.0.E')
    elseif text == nil then
        send(system, id .. '.0.0.N')
    elseif type(text) ~= 'string' or #text > system.maxLength or text:find('[\0-\31]') then
        Callback.report('Sync read', system.onError,
            'expected a string of at most ' .. system.maxLength .. ' bytes, none below 32')
        send(system, id .. '.0.0.E')
    elseif text == '' then
        send(system, id .. '.0.0.S')
    else
        local count = (#text + PIECE - 1) // PIECE
        for index = 1, count do
            local piece = text:sub((index - 1) * PIECE + 1, index * PIECE)
            send(system, id .. '.' .. index .. '.' .. count .. '.' .. piece)
        end
    end
end

---A packet's number: canonical decimal digits (no leading zero) up to `max`, or nil.
---@param digits string
---@param max integer
---@return integer?
local function number(digits, max)
    if #digits > 9 or (#digits > 1 and digits:sub(1, 1) == '0') then return nil end
    local value = math.tointeger(tonumber(digits))
    if not value or value > max then return nil end
    return value
end

---One packet arrived, on every machine alike.
---@param system MoonwellSystems.Sync
---@param sender MoonwellWrappers.Player The player the engine reports, never one named in the data.
---@param data string
local function arrived(system, sender, data)
    local idText, indexText, countText, payload = data:match('^(%d+)%.(%d+)%.(%d+)%.(.*)$')
    if not idText then return end
    local id = number(idText, 999999999)
    local request = id and system.requests[id]
    -- Only the asked player's packets for an open request are taken.
    if not request or sender ~= request.player then return end
    local index, count = number(indexText, 999), number(countText, 999)
    if count == 0 and index == 0 then
        if payload == 'N' then return finish(system, request, nil, 'none') end
        if payload == 'E' then return finish(system, request, nil, 'error') end
        if payload == 'S' then return finish(system, request, '', nil) end
    elseif index and count and index >= 1 and index <= count and count <= (system.maxLength + PIECE - 1) // PIECE
        and (request.count == 0 or request.count == count) and not request.pieces[index]
        and #payload >= 1 and #payload <= PIECE and request.length + #payload <= system.maxLength then
        request.count = count
        request.pieces[index] = payload
        request.received = request.received + 1
        request.length = request.length + #payload
        if request.received == count then finish(system, request, table.concat(request.pieces, '', 1, count), nil) end
        return
    end
    Callback.report('Sync packet', system.onError, 'a malformed packet for request ' .. request.id)
    finish(system, request, nil, 'error')
end

---@param value unknown
---@return boolean
local function identifier(value)
    return type(value) == 'string' and #value >= 1 and #value <= 32 and value:find('^[A-Za-z0-9_-]+$') ~= nil
end

---@param clock MoonwellSystems.Scheduler Times the requests out; it must run on every machine alike.
---@param options MoonwellSystems.SyncOptions?
---@return MoonwellSystems.Sync
function Sync.new(clock, options)
    Check.receiver(clock, Scheduler, 'Scheduler', 'Sync.new')
    if options == nil then options = {} end
    if type(options) ~= 'table' then error('[systems] Sync.new: expected an options table', 2) end
    local prefix, timeout, maxLength = options.prefix, options.timeout, options.maxLength
    if prefix == nil then prefix = 'mwsync' end
    if not identifier(prefix) then
        error('[systems] Sync.new: expected a prefix of 1 to 32 letters, digits, - or _', 2)
    end
    if timeout == nil then timeout = 10 end
    if not Check.finite(timeout) or timeout <= 0 then error('[systems] Sync.new: expected a positive timeout', 2) end
    if maxLength == nil then maxLength = 8192 end
    if type(maxLength) ~= 'number' or not math.tointeger(maxLength) or maxLength < 1 or maxLength > MAX_LENGTH then
        error('[systems] Sync.new: expected maxLength: a whole number from 1 to ' .. MAX_LENGTH, 2)
    end
    Callback.optional(options.onError, 'Sync.new')
    return setmetatable({
        clock = clock, prefix = prefix, timeout = timeout, maxLength = math.tointeger(maxLength),
        onError = options.onError, requests = {}, nextRequest = 1, disposed = false,
    }, Sync)
end

---Starts listening for answers. Call it once, on every machine, before the first `ask`. Idempotent.
function Sync:start()
    local system = Check.receiver(self, Sync, 'Sync', 'Sync.start')
    if system.disposed then error('[systems] Sync.start: the system is disposed', 2) end
    if system.listener then return end
    system.listener = Messages.on(system.prefix, function(sender, data) arrived(system, sender, data) end)
end

---Asks `player`'s machine for a text. Call it on every machine, in the same order, like any other game code.
---`receive` runs later, never inside this call, and on every machine at the same moment.
---@param player MoonwellWrappers.Player
---@param read fun(): string? Runs on `player`'s machine only, at once. Returns the text (no byte below 32), or nil.
---@param receive fun(text: string?, reason: ('none'|'error'|'absent'|'timeout'|'disposed')?): ...
function Sync:ask(player, read, receive)
    local system = Check.receiver(self, Sync, 'Sync', 'Sync.ask')
    if system.disposed then error('[systems] Sync.ask: the system is disposed', 2) end
    if not system.listener then error('[systems] Sync.ask: call start() first', 2) end
    if getmetatable(player) ~= Player then error('[systems] Sync.ask: expected Player', 2) end
    Callback.check(read, 'Sync.ask')
    Callback.check(receive, 'Sync.ask')
    ---@type MoonwellSystems.SyncRequest
    local request = {id = system.nextRequest, player = player, receive = receive, pieces = {}, count = 0,
        received = 0, length = 0}
    system.nextRequest = request.id + 1
    system.requests[request.id] = request
    -- Both are the same on every machine: whether a human plays in the slot.
    if player:getController() ~= MAP_CONTROL_USER or player:getSlotState() ~= PLAYER_SLOT_STATE_PLAYING then
        request.cancel = system.clock:after(0, function()
            request.cancel = nil
            finish(system, request, nil, 'absent')
        end)
        return
    end
    request.cancel = system.clock:after(system.timeout, function()
        request.cancel = nil
        finish(system, request, nil, 'timeout')
    end)
    if player:isLocal() then answer(system, request, read) end
end

---Ends every open request with 'disposed', in the order they were asked, and stops listening. `ask` and `start`
---raise afterwards. Idempotent.
function Sync:dispose()
    local system = Check.receiver(self, Sync, 'Sync', 'Sync.dispose')
    if system.disposed then return end
    system.disposed = true
    if system.listener then Messages.off(system.listener); system.listener = nil end
    for id = 1, system.nextRequest - 1 do
        local request = system.requests[id]
        if request then finish(system, request, nil, 'disposed') end
    end
end

return Sync
