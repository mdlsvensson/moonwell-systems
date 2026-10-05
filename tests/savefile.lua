bj_MAX_PLAYERS, bj_MAX_PLAYER_SLOTS = 24, 28
MAP_CONTROL_USER, MAP_CONTROL_COMPUTER = {}, {}
PLAYER_SLOT_STATE_PLAYING = {}
-- The game: player slots, which of them this machine is, sync messages, tooltips and this machine's files.
local slots, here, sent, message, actions = {}, nil, {}, {}, {}
local texts, files, buffer, dead = {}, {}, {}, {}
for index = 0, 27 do
    slots[index] = {controller = MAP_CONTROL_USER, state = PLAYER_SLOT_STATE_PLAYING, name = 'Player ' .. index}
end
native('Player', function(index) return slots[index] end)
native('GetLocalPlayer', function() return here end)
native('GetPlayerController', function(player) return player.controller end)
native('GetPlayerSlotState', function(player) return player.state end)
native('GetPlayerName', function(player) return player.name end)
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
    sent[#sent + 1] = {prefix = prefix, data = data}
    return true
end)
native('GetTriggerPlayer', function() return message.player end)
native('BlzGetTriggerSyncData', function() return message.data end)
-- Every ability has a tooltip and an extended tooltip of its own, unless it is in `dead`.
local function field(name, key)
    native('BlzGetAbility' .. name, function(ability)
        if dead[ability] then return nil end
        return texts[key .. ability] or key .. ' of ' .. ability
    end)
    native('BlzSetAbility' .. name, function(ability, text)
        if not dead[ability] then texts[key .. ability] = text end
    end)
end
field('Tooltip', 't'); field('ExtendedTooltip', 'e')
native('PreloadGenClear', function() buffer = {} end)
native('PreloadGenStart', function() end)
native('Preload', function(text) buffer[#buffer + 1] = text:sub(1, 259) end)
native('PreloadGenEnd', function(path) files[path] = buffer end)
native('Preloader', function(path)
    for _, line in ipairs(files[path] or {}) do
        local name, ability, text = line:match('^"%)\ncall (BlzSetAbility%a+)%((%d+), "([^"]*)", 0%)\n//$')
        assert(name, 'a line the game cannot run: ' .. line)
        _G[name](math.tointeger(tonumber(ability)), text, 0)
    end
end)
local Savefile = require('systems.savefile')
local Codec = require('systems.codec')
local Scheduler = require('systems.scheduler')
local Players = require('wrappers.player')
eq(totalCalls(), 0)

local AMLS = 1097690227
local function codec(version, extra)
    local schemas = {{version = 1, fields = {{key = 'gold', kind = 'integer', min = 0, max = 100},
        {key = 'items', kind = 'list', maxLength = 3, of = {kind = 'integer', min = 0, max = 2147483647}}},
        migrate = extra}}
    if version == 2 then
        schemas[2] = {version = 2, fields = {{key = 'coins', kind = 'integer', min = 0, max = 1000}}}
    end
    return Codec.new({version = version or 1, secret = 'k3-vale-of-ash', schemas = schemas})
end
-- A message arrives on this machine, and everything this machine sent arrives as from the local player.
local function deliver(data, from, prefix)
    message = {player = from, data = data}
    for _, action in ipairs(actions) do
        if action.trigger.enabled and action.trigger.prefixes[1] == (prefix or 'mwsave') then action.callback() end
    end
end
local function flush()
    local packets = sent
    sent = {}
    for _, packet in ipairs(packets) do deliver(packet.data, here, packet.prefix) end
    return packets
end
-- Every test starts with setup(): this machine is player `me`; its files are kept unless `fresh`. Returns a started
-- system, its clock, and players 0 and 1.
local function setup(me, options, fresh)
    for index = 0, 27 do
        slots[index].controller, slots[index].state = MAP_CONTROL_USER, PLAYER_SLOT_STATE_PLAYING
        slots[index].name = 'Player ' .. index
    end
    here, sent, texts, dead = slots[me or 0], {}, {}, {}
    if fresh ~= false then files = {} end
    local clock = Scheduler.new({step = 1})
    local merged = {clock = clock, codec = codec(), folder = 'Vale'}
    for key, value in pairs(options or {}) do merged[key] = value end
    local saves = Savefile.new(merged)
    saves:start()
    resetCalls()
    return saves, clock, Players.fromIndex(0), Players.fromIndex(1)
end
local function loaded(log)
    return function(data, reason)
        log[#log + 1] = data and ('gold ' .. tostring(data.gold) .. ' items ' .. table.concat(data.items, ','))
            or reason
    end
end
-- A file as save writes it, holding `code`.
local function plant(path, code)
    files[path] = {'")\ncall BlzSetAbilityTooltip(' .. AMLS .. ', "MWS1.' .. #code .. '.' .. code .. '", 0)\n//'}
end
-- Every tooltip reads as it did at first (the stub stores the ones that were ever set).
local function untouched()
    for key, text in pairs(texts) do
        if text ~= key:sub(1, 1) .. ' of ' .. key:sub(2) then error('a tooltip was left changed: ' .. key) end
    end
end
local function fourCC(code) return (string.unpack('>I4', code)) end

test('save writes on the player\'s own machine, and load gives the data to every machine', function()
    local saves, clock, me = setup(0)
    saves:save(me, 'slot1', {gold = 40, items = {7, 8}})
    local lines = files['Vale\\slot1.pld']
    eq(#lines, 1)
    assert(lines[1]:find('^"%)\ncall BlzSetAbilityTooltip%(' .. AMLS .. ', "MWS1%.%d+%.[%w_-]+", 0%)\n//$'), lines[1])
    eq(#sent, 0)
    local log = {}
    saves:load(me, 'slot1', loaded(log))
    eq(#log, 0); eq(callCount('Preloader'), 1); expectCall('Preloader', 'Vale\\slot1.pld')
    local packets = flush()
    eq(table.concat(log, ' | '), 'gold 40 items 7,8'); eq(clock:getPending(), 0); eq(#PRINTED, 0)
    eq(packets[1].prefix, 'mwsave')
    untouched()
    saves:dispose()
    -- Another machine: nothing is written or read there, and the same packets give the same data.
    saves, clock, me = setup(1)
    saves:save(me, 'slot1', {gold = 40, items = {7, 8}})
    eq(next(files), nil); eq(callCount('PreloadGenStart'), 0)
    saves:load(me, 'slot1', loaded(log))
    eq(callCount('Preloader'), 0); eq(#sent, 0)
    for _, packet in ipairs(packets) do deliver(packet.data, slots[0]) end
    eq(log[2], 'gold 40 items 7,8'); eq(clock:getPending(), 0)
    untouched()
    saves:dispose()
end)

test('slots are files of their own, and a second save replaces the first', function()
    local saves, _, me = setup(0)
    saves:save(me, 'a', {gold = 1, items = {}})
    saves:save(me, 'b-2_X', {gold = 2, items = {}})
    saves:save(me, 'a', {gold = 3, items = {9}})
    assert(files['Vale\\a.pld'] and files['Vale\\b-2_X.pld'])
    local log = {}
    saves:load(me, 'b-2_X', loaded(log)); saves:load(me, 'a', loaded(log))
    flush()
    eq(table.concat(log, ' | '), 'gold 2 items  | gold 3 items 9')
    saves:dispose()
end)

test('a load says why there is no data', function()
    local function why(prepare, options, me, keep)
        local saves, clock, player = setup(me or 0, options, not keep)
        local log = {}
        local finish = prepare and prepare(saves, player, clock)
        saves:load(player, 'slot1', loaded(log))
        flush()
        if finish then finish() end
        saves:dispose()
        eq(#log, 1)
        untouched()
        return log[1]
    end
    eq(why(), 'missing')
    eq(why(function() plant('Vale\\slot1.pld', 'not!a!code') end), 'damaged')
    eq(why(function() files['Vale\\slot1.pld'] = {'")\ncall BlzSetAbilityTooltip(' .. AMLS .. ', "junk", 0)\n//'} end),
        'damaged')
    eq(why(function() plant('Vale\\slot1.pld', 'abc') end), 'format')
    -- A code made for another name, and one with a symbol changed.
    eq(why(function(saves, player)
        saves:save(player, 'slot1', {gold = 5, items = {}})
        slots[0].name = 'Somebody else'
    end), 'checksum')
    local good = codec():encode({gold = 5, items = {}}, 'Player 0')
    eq(why(function() plant('Vale\\slot1.pld', good) end), 'gold 5 items ')
    eq(why(function() plant('Vale\\slot1.pld', (good:sub(1, 1) == 'B' and 'C' or 'B') .. good:sub(2)) end), 'checksum')
    -- The codec's other reasons pass through.
    local two = codec(2):encode({coins = 5}, 'Player 0')
    eq(why(function() plant('Vale\\slot1.pld', two) end), 'version')
    local other = Codec.new({version = 1, secret = 'k3-vale-of-ash', schemas = {{version = 1, fields = {}}}})
    eq(why(function() plant('Vale\\slot1.pld', other:encode({}, 'Player 0')) end), 'schema')
    -- No human in the slot; no answer; a system disposed first.
    eq(why(function(_, _, clock)
        slots[0].controller = MAP_CONTROL_COMPUTER
        return function() clock:advance() end
    end), 'absent')
    eq(why(function(_, _, clock)
        return function() for _ = 1, 3 do clock:advance() end end
    end, {timeout = 3}, 1), 'timeout')
    eq(why(nil, nil, 1), 'disposed')
    eq(#PRINTED, 0)
    -- An answer longer than any code of the codec (26 symbols here) is refused before it is decoded.
    local saves, _, asked = setup(1)
    local log = {}
    saves:load(asked, 'slot1', loaded(log))
    deliver('1.1.1.' .. string.rep('A', 27), slots[0])
    eq(log[1], 'error'); eq(PRINTED[1], '[systems] Sync packet failed: a malformed packet for request 1')
    saves:load(asked, 'slot1', loaded(log))
    deliver('2.1.1.' .. string.rep('A', 26), slots[0])
    eq(log[2], 'checksum')
    saves:dispose()
end)

test('an older file is migrated; a failing migration is reported', function()
    local saves, _, me = setup(0)
    saves:save(me, 'slot1', {gold = 40, items = {1, 2}})
    saves:dispose()
    saves, _, me = setup(0, {codec = codec(2, function(data) return {coins = data.gold * 10 + #data.items} end)}, false)
    local got
    saves:load(me, 'slot1', function(data, reason) got = {data, reason} end)
    flush()
    eq(got[1].coins, 402); eq(got[2], nil); eq(#PRINTED, 0)
    saves:dispose()
    saves, _, me = setup(0, {codec = codec(2, function() error('no idea') end)}, false)
    saves:load(me, 'slot1', function(data, reason) got = {data, reason} end)
    flush()
    eq(got[1], nil); eq(got[2], 'migration')
    assert(PRINTED[1]:find('^%[systems%] Savefile migration failed: .*no idea$'), PRINTED[1]); eq(#PRINTED, 1)
    saves:dispose()
end)

test('save raises on every machine alike for data that does not fit', function()
    for me = 0, 1 do
        local saves, _, player = setup(me)
        failsAt(function() saves:save(player, 'slot1', {gold = 101, items = {}}) end,
            '[systems] Savefile.save: field "gold": expected a whole number from 0 to 100')
        failsAt(function() saves:save(player, 'slot1', {gold = 1, items = {}, extra = 1}) end,
            '[systems] Savefile.save: unknown field "extra"')
        failsAt(function() saves:save(player, 'slot1') end, '[systems] Savefile.save: expected a data table')
        eq(next(files), nil)
        saves:dispose()
    end
end)

test('the default abilities hold the longest code a codec may have', function()
    local big = Codec.new({version = 1, secret = 's', schemas = {{version = 1, fields = {
        {key = 'a', kind = 'string', maxLength = 4095}, {key = 'b', kind = 'string', maxLength = 2037}}}}})
    eq(big:getMaxLength(), 8189)
    local saves, _, me = setup(0, {codec = big})
    local data = {a = string.rep('\255', 4095), b = string.rep('z', 2037)}
    saves:save(me, 'big', data)
    local lines = files['Vale\\big.pld']
    eq(#lines, 44) -- "MWS1.8189." and 8189 symbols in chunks of 190
    for _, line in ipairs(lines) do assert(#line <= 248) end
    eq(lines[1]:match('%((%d+),'), tostring(AMLS)); eq(lines[2]:match('%((%d+),'), tostring(AMLS))
    eq(lines[44]:match('%((%d+),'), tostring(fourCC('Afsh'))) -- the 22nd of the default abilities
    local got
    saves:load(me, 'big', function(loaded) got = loaded end)
    eq(#sent, 38) -- 8189 bytes in packets of 220
    flush()
    eq(got.a, data.a); eq(got.b, data.b)
    saves:dispose()
end)

test('start checks every borrowed ability, and save and load need it', function()
    local clock = Scheduler.new({step = 1})
    here, texts, dead = slots[0], {}, {}
    local me = Players.fromIndex(0)
    -- A prefix of its own: the wrappers keep one trigger per prefix, and other tests made the default one.
    local saves = Savefile.new({clock = clock, codec = codec(), folder = 'Vale', prefix = 'starts'})
    failsAt(function() saves:save(me, 'slot1', {gold = 1, items = {}}) end,
        '[systems] Savefile.save: call start() first')
    failsAt(function() saves:load(me, 'slot1', print) end, '[systems] Savefile.load: call start() first')
    dead[fourCC('Aclf')] = true
    failsAt(function() saves:start() end, "[systems] Savefile.start: ability 'Aclf' cannot carry text")
    failsAt(function() saves:load(me, 'slot1', print) end, '[systems] Savefile.load: call start() first')
    eq(callCount('CreateTrigger'), 0); untouched()
    dead = {}
    saves:start()
    eq(callCount('CreateTrigger'), 1); untouched()
    resetCalls()
    saves:start()
    eq(totalCalls(), 0) -- a second start does nothing
    -- A map's own list replaces the default.
    local own = Savefile.new({clock = clock, codec = codec(), folder = 'Vale', abilities = {5, 6.0},
        prefix = 'own'})
    own:start()
    own:save(me, 'slot1', {gold = 1, items = {}})
    eq(files['Vale\\slot1.pld'][1]:match('%((%d+),'), '5')
    own:dispose(); saves:dispose()
end)

test('a failing callback is reported, and onError receives it', function()
    local saves, _, me = setup(0)
    saves:load(me, 'slot1', function() error('callback broke') end)
    flush()
    assert(PRINTED[1]:find('^%[systems%] Savefile callback failed: .*callback broke$'), PRINTED[1]); eq(#PRINTED, 1)
    saves:dispose()
    local reported = {}
    saves, _, me = setup(0, {onError = function(text) reported[#reported + 1] = text end})
    saves:load(me, 'slot1', function() error('callback broke') end)
    flush()
    eq(#reported, 1); eq(#PRINTED, 0)
    saves:dispose()
end)

test('dispose ends open loads, is idempotent, and later calls raise', function()
    local saves, clock, me, other = setup(0)
    local log = {}
    saves:load(other, 'slot1', loaded(log))
    saves:dispose(); saves:dispose()
    eq(table.concat(log, ' '), 'disposed'); eq(clock:getPending(), 0); eq(callCount('DisableTrigger'), 1)
    failsAt(function() saves:save(me, 'slot1', {gold = 1, items = {}}) end,
        '[systems] Savefile.save: the system is disposed')
    failsAt(function() saves:load(me, 'slot1', print) end, '[systems] Savefile.load: the system is disposed')
    failsAt(function() saves:start() end, '[systems] Savefile.start: the system is disposed')
end)

test('new, save and load check their arguments at the caller', function()
    local clock = Scheduler.new({step = 1})
    local function with(overrides)
        local options = {clock = clock, codec = codec(), folder = 'Vale'}
        for key, value in pairs(overrides) do options[key] = value ~= 'none' and value or nil end
        return function() Savefile.new(options) end
    end
    failsAt(function() Savefile.new({codec = codec(), folder = 'Vale'}) end,
        "[systems] Savefile.new: 'clock' expected a Scheduler")
    failsAt(function() Savefile.new(clock) end, '[systems] Savefile.new: expected an options table')
    failsAt(with({codec = 'none'}), "[systems] Savefile.new: 'codec' expected a Codec")
    failsAt(with({codec = {}}), "[systems] Savefile.new: 'codec' expected a Codec")
    for _, folder in ipairs({'none', '', 'two words', 'a\\b', 'a.b', string.rep('f', 33), 5}) do
        failsAt(with({folder = folder}), "[systems] Savefile.new: 'folder' expected 1 to 32 letters, digits, - or _")
    end
    for _, abilities in ipairs({5, {}, {'Amls'}, {1.5}, {0}, {7, 7}, {7, -1}, {7, 2^63}, {2^63, 7}}) do
        failsAt(with({abilities = abilities}),
            "[systems] Savefile.new: 'abilities' expected a list of ability ids, each once")
    end
    local big = Codec.new({version = 1, secret = 's', schemas = {{version = 1, fields = {
        {key = 'a', kind = 'string', maxLength = 300}}}}})
    failsAt(with({codec = big, abilities = {7}}),
        "[systems] Savefile.new: the codec's longest code is 410 symbols, but the abilities hold 370")
    Savefile.new({clock = clock, codec = big, folder = 'Vale', abilities = {7, 8}})
    -- An older schema's longer code counts too: a file from that version must still be readable.
    local shrunk = Codec.new({version = 2, secret = 's', schemas = {{version = 2, fields = {}},
        {version = 1, fields = {{key = 'a', kind = 'string', maxLength = 300}}, migrate = function() return {} end}}})
    failsAt(with({codec = shrunk, abilities = {7}}), 'longest code is 410 symbols')
    failsAt(with({prefix = 'two words'}),
        "[systems] Savefile.new: 'prefix' expected 1 to 32 letters, digits, - or _")
    failsAt(with({timeout = 0}), "[systems] Savefile.new: 'timeout' expected a finite positive number")
    failsAt(with({onError = 5}), "[systems] Savefile.new: 'onError' expected a function")
    failsAt(with({slot = 'a'}), "[systems] Savefile.new: unknown key 'slot'")
    local saves, _, me = setup(0)
    for _, slot in ipairs({'', 'two words', 'a\\b', '..', string.rep('s', 33), 5}) do
        failsAt(function() saves:save(me, slot, {gold = 1, items = {}}) end,
            '[systems] Savefile.save: expected a slot of 1 to 32 letters, digits, - or _')
        failsAt(function() saves:load(me, slot, print) end,
            '[systems] Savefile.load: expected a slot of 1 to 32 letters, digits, - or _')
    end
    failsAt(function() saves:save(slots[0], 'a', {}) end, '[systems] Savefile.save: expected Player')
    failsAt(function() saves:load({}, 'a', print) end, '[systems] Savefile.load: expected Player')
    failsAt(function() saves:load(me, 'a') end, '[systems] Savefile.load: expected a callback function')
    failsAt(function() saves.save({}, me, 'a', {}) end, '[systems] Savefile.save: expected Savefile')
    failsAt(function() saves.load({}, me, 'a', print) end, '[systems] Savefile.load: expected Savefile')
    failsAt(function() saves.start({}) end, '[systems] Savefile.start: expected Savefile')
    failsAt(function() saves.dispose({}) end, '[systems] Savefile.dispose: expected Savefile')
    eq(next(files), nil); eq(#sent, 0)
    saves:dispose()
end)
