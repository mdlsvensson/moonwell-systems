bj_MAX_PLAYERS, bj_MAX_PLAYER_SLOTS = 24, 28
MAP_CONTROL_USER, MAP_CONTROL_COMPUTER = {}, {}
PLAYER_SLOT_STATE_PLAYING, PLAYER_SLOT_STATE_EMPTY = {}, {}
-- The game: player slots, which of them this machine is, the sync messages it sent, and the message being delivered.
local slots, here, sent, accepts, message, actions = {}, nil, {}, true, {}, {}
for index = 0, 27 do slots[index] = {controller = MAP_CONTROL_USER, state = PLAYER_SLOT_STATE_PLAYING} end
native('Player', function(index) return slots[index] end)
native('GetLocalPlayer', function() return here end)
native('GetPlayerController', function(player) return player.controller end)
native('GetPlayerSlotState', function(player) return player.state end)
native('CreateTrigger', function() return {prefixes = {}, enabled = true} end)
native('BlzTriggerRegisterPlayerSyncEvent', function(trigger, _, prefix)
    trigger.prefixes[#trigger.prefixes + 1] = prefix
    return {}
end)
native('TriggerAddAction', function(trigger, callback)
    actions[#actions + 1] = {trigger = trigger, callback = callback}
    return {}
end)
native('EnableTrigger', function(trigger) trigger.enabled = true end)
native('DisableTrigger', function(trigger) trigger.enabled = false end)
native('BlzSendSyncData', function(prefix, data)
    if accepts then sent[#sent + 1] = {prefix = prefix, data = data} end
    return accepts
end)
native('GetTriggerPlayer', function() return message.player end)
native('BlzGetTriggerSyncData', function() return message.data end)
local Sync = require('systems.sync')
local Scheduler = require('systems.scheduler')
local Players = require('wrappers.player')
eq(totalCalls(), 0)

-- A message arrives on this machine: the action of every enabled trigger registered for the prefix runs.
local function deliver(data, from, prefix)
    message = {player = from, data = data}
    for _, action in ipairs(actions) do
        if action.trigger.enabled and action.trigger.prefixes[1] == (prefix or 'mwsync') then action.callback() end
    end
end
-- Everything this machine sent arrives, as from the local player.
local function flush(order)
    local packets = sent
    sent = {}
    for position = 1, #packets do
        local packet = packets[order and order[position] or position]
        deliver(packet.data, here, packet.prefix)
    end
end
-- Every test starts with setup(): this machine is player `me`, with a clock of one-second steps and a started system.
local function setup(me, options)
    for index = 0, 27 do slots[index].controller, slots[index].state = MAP_CONTROL_USER, PLAYER_SLOT_STATE_PLAYING end
    here, sent, accepts = slots[me or 0], {}, true
    local clock = Scheduler.new({step = 1})
    local merged = {clock = clock}
    for key, value in pairs(options or {}) do merged[key] = value end
    local system = Sync.new(merged)
    system:start()
    resetCalls()
    return system, clock, Players.fromIndex(0), Players.fromIndex(1)
end
-- A receive callback that records its calls as "text/reason".
local function recorder(log)
    return function(text, reason) log[#log + 1] = tostring(text) .. '/' .. tostring(reason) end
end
local function never() error('read ran on a machine that was not asked') end

test('the asked player\'s own machine reads, sends, and receives with everyone', function()
    local system, clock, me = setup(0)
    local log, reads = {}, 0
    system:ask(me, function() reads = reads + 1; return 'hello' end, recorder(log))
    eq(reads, 1); eq(#log, 0) -- read ran at once; receive never runs inside ask
    eq(#sent, 1); eq(sent[1].prefix, 'mwsync'); eq(sent[1].data, '1.1.1.hello')
    flush()
    eq(table.concat(log, ' '), 'hello/nil')
    eq(clock:getPending(), 0) -- the timeout is cancelled
    for _ = 1, 20 do clock:advance() end
    eq(#log, 1); eq(#PRINTED, 0)
    system:dispose()
end)

test('another machine does not read, and receives the same answer', function()
    local system, clock, asked = setup(1)
    local log = {}
    system:ask(asked, never, recorder(log))
    eq(#sent, 0); eq(#log, 0)
    deliver('1.1.1.hello', slots[0])
    eq(table.concat(log, ' '), 'hello/nil'); eq(clock:getPending(), 0)
    system:dispose()
end)

test('a long text travels in pieces of 220 bytes, which may arrive in any order', function()
    local system, _, me = setup(0)
    local bytes = {}
    for byte = 32, 126 do bytes[#bytes + 1] = string.char(byte) end
    for byte = 128, 255 do bytes[#bytes + 1] = string.char(byte) end
    local text = table.concat(bytes) .. string.rep('x', 277) -- 500 bytes: every byte a text may hold
    local got
    system:ask(me, function() return text end, function(answer, reason) got = {answer, reason} end)
    eq(#sent, 3)
    eq(sent[1].data, '1.1.3.' .. text:sub(1, 220)); eq(sent[2].data, '1.2.3.' .. text:sub(221, 440))
    eq(sent[3].data, '1.3.3.' .. text:sub(441))
    for _, packet in ipairs(sent) do assert(#packet.data <= 255) end
    local first, second, third = sent[1], sent[2], sent[3]
    sent = {}
    deliver(third.data, here); deliver(first.data, here)
    eq(got, nil)
    deliver(second.data, here)
    eq(got[1], text); eq(got[2], nil)
    -- A text of exactly one piece, and of one byte more.
    local sizes = {}
    system:ask(me, function() return string.rep('a', 220) end, function() end)
    sizes[1] = #sent
    system:ask(me, function() return string.rep('a', 221) end, function() end)
    sizes[2] = #sent - sizes[1]
    eq(sizes[1], 1); eq(sizes[2], 2); eq(sent[3].data, '3.2.2.a')
    system:dispose()
end)

test('no value, an empty text and a failing read each have an answer', function()
    local system, _, me = setup(0, {maxLength = 10})
    local log = {}
    local function ask(read)
        system:ask(me, read, recorder(log))
        local packet = sent[#sent].data
        flush()
        return packet
    end
    eq(ask(function() return nil end), '1.0.0.N'); eq(log[1], 'nil/none')
    eq(ask(function() return '' end), '2.0.0.S'); eq(log[2], '/nil')
    eq(#PRINTED, 0)
    eq(ask(function() error('disk on fire') end), '3.0.0.E'); eq(log[3], 'nil/error')
    assert(PRINTED[1]:find('^%[systems%] Sync read failed: .*disk on fire$'), PRINTED[1])
    -- What cannot be sent: another type, a text over maxLength, a byte below 32.
    for index, value in ipairs({5, {}, string.rep('x', 11), 'a\nb', 'a\0b', '\31'}) do
        eq(ask(function() return value end), (3 + index) .. '.0.0.E'); eq(log[3 + index], 'nil/error')
        eq(PRINTED[1 + index],
            '[systems] Sync read failed: expected a string of at most 10 bytes, none below 32')
    end
    eq(ask(function() return string.rep('x', 10) end), '10.1.1.xxxxxxxxxx'); eq(log[10], 'xxxxxxxxxx/nil')
    eq(ask(function() return ' ~\127\255' end), '11.1.1. ~\127\255')
    system:dispose()
end)

test('a slot without a human is absent, on the next step', function()
    for _, change in ipairs({{'controller', MAP_CONTROL_COMPUTER}, {'state', PLAYER_SLOT_STATE_EMPTY}}) do
        local system, clock, me = setup(0)
        slots[0][change[1]] = change[2]
        local log = {}
        system:ask(me, never, recorder(log))
        eq(#log, 0); eq(#sent, 0)
        clock:advance()
        eq(table.concat(log, ' '), 'nil/absent'); eq(clock:getPending(), 0)
        deliver('1.1.1.late', slots[0])
        eq(#log, 1)
        system:dispose()
    end
end)

test('a request without an answer times out, and a late answer is ignored', function()
    local system, clock, asked = setup(1, {timeout = 3})
    local log = {}
    system:ask(asked, never, recorder(log))
    clock:advance(); clock:advance()
    eq(#log, 0)
    deliver('1.1.2.half', slots[0])
    clock:advance()
    eq(table.concat(log, ' '), 'nil/timeout'); eq(clock:getPending(), 0)
    deliver('1.2.2.rest', slots[0]); deliver('1.0.0.N', slots[0])
    eq(#log, 1); eq(#PRINTED, 0)
    -- The default is ten seconds.
    system:dispose()
    system, clock, asked = setup(1)
    system:ask(asked, never, recorder(log))
    for _ = 1, 9 do clock:advance() end
    eq(#log, 1)
    clock:advance()
    eq(log[2], 'nil/timeout')
    system:dispose()
end)

test('only the asked player\'s packets for an open request are taken', function()
    local system, _, asked = setup(1)
    local log = {}
    system:ask(asked, never, recorder(log))
    deliver('1.1.1.forged', slots[1])   -- another player
    deliver('1.0.0.E', slots[2])
    deliver('2.1.1.early', slots[0])    -- a request nobody asked
    deliver('0.1.1.zero', slots[0])
    deliver('01.1.1.padded', slots[0])  -- not a number as this library writes it
    deliver('1234567890.1.1.x', slots[0])
    deliver('hello', slots[0]); deliver('', slots[0]); deliver('1.1.1', slots[0]); deliver('a.1.1.x', slots[0])
    deliver('1.1.1.other prefix', slots[0], 'other')
    eq(#log, 0); eq(#PRINTED, 0)
    deliver('1.1.1.real', slots[0])
    eq(table.concat(log, ' '), 'real/nil')
    deliver('1.1.1.again', slots[0])    -- the request is closed
    eq(#log, 1); eq(#PRINTED, 0)
    system:dispose()
end)

test('a malformed packet from the asked player ends the request with error, once', function()
    local function malformed(packets, options)
        local system, clock, asked = setup(1, options)
        local log = {}
        system:ask(asked, never, recorder(log))
        for index, packet in ipairs(packets) do
            eq(#log, 0, index)
            deliver(packet, slots[0])
        end
        eq(table.concat(log, ' '), 'nil/error')
        eq(PRINTED[1], '[systems] Sync packet failed: a malformed packet for request 1'); eq(#PRINTED, 1)
        eq(clock:getPending(), 0)
        system:dispose()
    end
    malformed({'1.0.0.X'}); malformed({'1.0.0.'}); malformed({'1.0.0.NE'})
    malformed({'1.0.1.x'}); malformed({'1.1.0.x'})
    malformed({'1.2.1.x'})                              -- a piece beyond the count
    malformed({'1.01.1.x'}); malformed({'1.1.01.x'})    -- padded numbers
    malformed({'1.1.2.a', '1.2.3.b'})                   -- the count changed
    malformed({'1.1.2.a', '1.1.2.a'})                   -- a piece twice
    malformed({'1.1.1.'})                               -- an empty piece
    malformed({'1.1.1.' .. string.rep('x', 221)})       -- a piece over 220 bytes
    malformed({'1.1.2.' .. string.rep('x', 220), '1.2.2.' .. string.rep('x', 81)}, {maxLength = 300})
    malformed({'1.1.3.x'}, {maxLength = 440})           -- more pieces than maxLength needs
    malformed({'1.1.1000.x'})
    -- The largest text maxLength allows arrives.
    local system, _, asked = setup(1, {maxLength = 300})
    local log = {}
    system:ask(asked, never, recorder(log))
    deliver('1.1.2.' .. string.rep('x', 220), slots[0]); deliver('1.2.2.' .. string.rep('x', 80), slots[0])
    eq(log[1], string.rep('x', 300) .. '/nil'); eq(#PRINTED, 0)
    system:dispose()
end)

test('requests are numbered in the order asked and answered apart', function()
    local system, _, me, other = setup(0)
    local log = {}
    system:ask(me, function() return 'first' end, recorder(log))
    system:ask(other, never, recorder(log))
    system:ask(me, function() return 'third' end, recorder(log))
    eq(sent[1].data, '1.1.1.first'); eq(sent[2].data, '3.1.1.third')
    flush({2, 1})
    deliver('2.1.1.second', slots[1])
    eq(table.concat(log, ' '), 'third/nil first/nil second/nil')
    -- A callback may ask again.
    local nested = {}
    system:ask(me, function() return 'outer' end, function(text)
        nested[#nested + 1] = text
        system:ask(me, function() return 'inner' end, function(inner) nested[#nested + 1] = inner end)
    end)
    flush(); flush()
    eq(table.concat(nested, ' '), 'outer inner')
    system:dispose()
end)

test('dispose ends the open requests in order, stops listening, and is idempotent', function()
    local system, clock, me, other = setup(0)
    local log = {}
    local function tag(name) return function(text, reason) log[#log + 1] = name .. ':' .. tostring(reason) end end
    system:ask(other, never, tag('a'))
    system:ask(me, function() return 'answered' end, tag('b'))
    system:ask(other, never, tag('c'))
    flush()
    eq(table.concat(log, ' '), 'b:nil')
    system:dispose(); system:dispose()
    eq(table.concat(log, ' '), 'b:nil a:disposed c:disposed')
    eq(clock:getPending(), 0); eq(callCount('DisableTrigger'), 1)
    deliver('1.1.1.late', slots[1])
    eq(#log, 3); eq(#PRINTED, 0)
    failsAt(function() system:ask(me, never, never) end, '[systems] Sync.ask: the system is disposed')
    failsAt(function() system:start() end, '[systems] Sync.start: the system is disposed')
    -- A system that never started disposes too.
    Sync.new({clock = clock}):dispose()
end)

test('failures are printed, or go to onError, and nothing is rethrown', function()
    local system, clock, me = setup(0)
    system:ask(me, function() return 'x' end, function() error('receive broke') end)
    flush()
    assert(PRINTED[1]:find('^%[systems%] Sync receive failed: .*receive broke$'), PRINTED[1])
    eq(clock:getPending(), 0)
    system:dispose()
    local reported = {}
    system, clock, me = setup(0, {onError = function(text) reported[#reported + 1] = text end, timeout = 2})
    system:ask(me, function() error('read broke') end, function() error('receive broke') end)
    flush()
    eq(#reported, 2); eq(#PRINTED, 0)
    assert(reported[1]:find('read broke$')); assert(reported[2]:find('receive broke$'))
    -- A message the game refuses is reported; the request then times out.
    accepts = false
    local log = {}
    system:ask(me, function() return 'lost' end, recorder(log))
    eq(reported[3], 'the game refused a sync message'); eq(#sent, 0)
    clock:advance(); clock:advance()
    eq(table.concat(log, ' '), 'nil/timeout')
    system:dispose()
end)

test('new, start and ask check their arguments at the caller', function()
    local clock = Scheduler.new({step = 1})
    failsAt(function() Sync.new(clock) end, '[systems] Sync.new: expected an options table')
    failsAt(function() Sync.new(5) end, '[systems] Sync.new: expected an options table')
    failsAt(function() Sync.new({}) end, "[systems] Sync.new: 'clock' expected a Scheduler")
    for _, prefix in ipairs({'', 5, 'two words', 'dot.ted', string.rep('p', 33)}) do
        failsAt(function() Sync.new({clock = clock, prefix = prefix}) end,
            "[systems] Sync.new: 'prefix' expected 1 to 32 letters, digits, - or _")
    end
    for _, timeout in ipairs({0, -1, 'soon', math.huge}) do
        failsAt(function() Sync.new({clock = clock, timeout = timeout}) end,
            "[systems] Sync.new: 'timeout' expected a finite positive number")
    end
    for _, maxLength in ipairs({0, 65536, 1.5, '8'}) do
        failsAt(function() Sync.new({clock = clock, maxLength = maxLength}) end,
            "[systems] Sync.new: 'maxLength' expected a whole number from 1 to 65535")
    end
    failsAt(function() Sync.new({clock = clock, onError = 5}) end, "[systems] Sync.new: 'onError' expected a function")
    failsAt(function() Sync.new({clock = clock, timeOut = 1}) end, "[systems] Sync.new: unknown key 'timeOut'")
    here = slots[0]
    local system = Sync.new({clock = clock, prefix = string.rep('p', 32), maxLength = 65535, timeout = 0.5})
    local me = Players.fromIndex(0)
    failsAt(function() system:ask(me, never, never) end, '[systems] Sync.ask: call start() first')
    system:start(); system:start()
    eq(callCount('CreateTrigger'), 1)
    failsAt(function() system.ask({}, me, never, never) end, '[systems] Sync.ask: expected Sync')
    failsAt(function() system:ask(slots[0], never, never) end, '[systems] Sync.ask: expected Player')
    failsAt(function() system:ask(me, 'read', never) end, '[systems] Sync.ask: expected a callback function')
    failsAt(function() system:ask(me, never, nil) end, '[systems] Sync.ask: expected a callback function')
    failsAt(function() system.start({}) end, '[systems] Sync.start: expected Sync')
    failsAt(function() system.dispose({}) end, '[systems] Sync.dispose: expected Sync')
    eq(clock:getPending(), 0) -- a refused ask opens no request
    system:dispose()
    eq(callCount('DisableTrigger'), 1) -- two starts made one listener, and it is gone
end)

test('dispose ends only the open requests, in asking order', function()
    local system, clock, _, other = setup(0)
    slots[2].controller = MAP_CONTROL_COMPUTER
    local absent = Players.fromIndex(2)
    local ends = {}
    -- three requests to an absent player end on the next tick; then two open ones to a human player
    for index = 1, 3 do
        system:ask(absent, never, function() ends[#ends + 1] = 'a' .. index end)
    end
    clock:advance()
    system:ask(other, never, function(_, why) ends[#ends + 1] = 'h1:' .. why end)
    system:ask(other, never, function(_, why) ends[#ends + 1] = 'h2:' .. why end)
    system:dispose()
    eq(table.concat(ends, ','), 'a1,a2,a3,h1:disposed,h2:disposed')
end)
