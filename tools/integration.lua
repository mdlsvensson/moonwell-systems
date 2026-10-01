-- Builds a consumer map with both libraries, runs LuaLS and checks one-module bundles: yue -e tools/integration.lua.
package.path = './tools/?.lua;' .. package.path
local Lib = require('lib')

local root = Lib.slash(Lib.cwd())
local function absolute(path)
    if path:match('^%a:[/\\]') or path:sub(1, 1) == '/' then return Lib.slash(path) end
    return root .. '/' .. path
end
local wrappers = absolute(os.getenv('MOONWELL_WRAPPERS') or '../moonwell-wrappers')
local cli = os.getenv('MOONWELL_CLI')
    or ('deno run -A ' .. Lib.quote(Lib.native(absolute('../moonwell/cli/src/main.ts'))))
local yue = os.getenv('MOONWELL_YUE') or 'yue'
local luals = os.getenv('MOONWELL_LUALS') or 'lua-language-server'

local work = root .. '/.test-work/integration-' .. os.time()
local consumer = work .. '/consumer'
Lib.mkdir(work)
print('Consumer: ' .. consumer)
local function moonwell(args) return Lib.must(cli .. ' ' .. args, consumer) end

Lib.must(cli .. ' init --link ' .. Lib.quote(Lib.native(consumer)), root)
Lib.write(consumer .. '/moonwell.local.pkl', table.concat({
    'amends "moonwell.pkl"',
    'libraries {',
    '  ["wrappers"] { path = "' .. wrappers .. '"; dir = "src" }',
    '  ["systems"] { path = "' .. root .. '"; dir = "src" }',
    '}',
    os.getenv('MOONWELL_YUE') and ('yue { path = "' .. absolute(yue) .. '" }') or '',
    '',
}, '\n'))

local function compileEditor()
    Lib.must(Lib.quote(yue) .. ' -l -c --target=5.3 --path ' .. Lib.quote(consumer .. '/.moonwell/yue/?.lua')
        .. ' -o src/main.lua src/main.yue', consumer)
end

local function clean(report, label)
    for file, diagnostics in pairs(report) do
        if #diagnostics > 0 then
            local first = diagnostics[1]
            error(label .. ' diagnostics in ' .. file .. ': ' .. first.code .. ' ' .. first.message, 0)
        end
    end
end

-- Positive fixtures: a clean check, normal and minified builds, and no editor diagnostics.
Lib.copy('tests/editor-positive.yue', consumer .. '/src/main.yue')
moonwell('check'); moonwell('build'); moonwell('build --minify')
compileEditor()
Lib.copy('tests/editor-positive.lua', consumer .. '/lua/positive.lua')
clean(Lib.diagnose(luals, consumer, 'positive'), 'Positive editor')
print('LuaLS: positive Lua and compiled Yue fixtures clean')

Lib.copy('tests/editor-negative.lua', consumer .. '/lua/negative.lua')
local intended = Lib.expectMarked('tests/editor-negative.lua', Lib.diagnose(luals, consumer, 'negative'),
    'negative.lua', 'Editor negative fixture')
Lib.remove(consumer .. '/lua/negative.lua')
print('LuaLS: ' .. intended .. ' intentional type errors detected at the expected lines')

-- The library's own files against Moonwell's native declarations, with the wrappers they require.
local source = work .. '/source'
Lib.copyTree('src/systems', source .. '/systems')
Lib.copyTree(wrappers .. '/src/wrappers', source .. '/wrappers')
Lib.mkdir(source .. '/types')
for _, name in ipairs({'natives.d.lua', 'moonwell.d.lua'}) do
    Lib.copy(consumer .. '/.moonwell/types/' .. name, source .. '/types/' .. name)
end
Lib.copy('tests/natives-negative.lua', source .. '/natives-negative.lua')
Lib.write(source .. '/.luarc.json', '{"runtime.version": "Lua 5.3", "runtime.path": ["?.lua", "?/init.lua"], '
    .. '"runtime.builtin": {"io": "disable", "debug": "disable", "package": "disable"}, '
    .. '"workspace.library": ["types"], "workspace.useGitIgnore": false, "workspace.checkThirdParty": false}')
local planted = Lib.expectMarked('tests/natives-negative.lua', Lib.diagnose(luals, source, 'natives'),
    'natives-negative.lua', 'Native-call check')
print("LuaLS: src/systems is clean against Moonwell's natives; " .. planted .. ' planted mistakes detected')

-- A map importing one entry point bundles only that module, what it requires, and the wrappers it names.
local public = {'scheduler', 'signal', 'scope', 'time', 'buffs', 'aura', 'dummy', 'damage', 'geometry', 'terrain',
    'missile', 'knockback', 'codec', 'sync', 'savefile'}
local wrappersPublic = {'unit', 'player', 'item', 'destructable', 'rect', 'region', 'force', 'group', 'timer', 'effect',
    'trigger', 'texttag', 'sound', 'lightning', 'image', 'ubersplat', 'fogmodifier', 'dialog', 'multiboard',
    'leaderboard', 'quest', 'defeatcondition', 'timerdialog', 'frame', 'damage', 'sync'}
-- `systems` and `wrappers` name the other public modules an entry may, and must, bundle.
local unitFamily = {unit = true, player = true, item = true, timer = true}
local entries = {
    time = {source = 'import "systems.time" as Time\nprint Time.formatDuration 5\n', systems = {}, wrappers = {}},
    signal = {source = 'import "systems.signal" as Signal\ns = Signal.new!\ns\\dispose!\n', systems = {},
        wrappers = {}},
    scope = {source = 'import "systems.scope" as Scope\ns = Scope.new!\ns\\dispose!\n', systems = {}, wrappers = {}},
    scheduler = {source = 'import "systems.scheduler" as Scheduler\nc = Scheduler.new!\nc\\dispose!\n', systems = {},
        wrappers = {timer = true}},
    buffs = {source = 'import "systems.buffs" as BuffStore\nimport "systems.scheduler" as Scheduler\n'
        .. 's = BuffStore.new Scheduler.new!\ns\\dispose!\n', systems = {scheduler = true}, wrappers = unitFamily},
    aura = {source = 'import "systems.aura" as Aura\nprint Aura\n', systems = {buffs = true, scheduler = true},
        wrappers = unitFamily},
    dummy = {source = 'import "systems.dummy" as Dummies\nimport "systems.scheduler" as Scheduler\n'
        .. 'd = Dummies.new Scheduler.new!\nd\\dispose!\n', systems = {scheduler = true}, wrappers = unitFamily},
    damage = {source = 'import "systems.damage" as DamageSystem\nd = DamageSystem.new!\nd\\dispose!\n', systems = {},
        wrappers = {unit = true, player = true, item = true, timer = true, damage = true}},
    geometry = {source = 'import "systems.geometry" as Geometry\nprint Geometry.length 3, 4\n', systems = {},
        wrappers = {}},
    terrain = {source = 'import "systems.terrain" as Terrain\nt = Terrain.new!\nt\\dispose!\n', systems = {},
        wrappers = {}},
    missile = {source = 'import "systems.missile" as Missiles\nimport "systems.scheduler" as Scheduler\n'
        .. 'm = Missiles.new Scheduler.new!\nm\\dispose!\n', systems = {scheduler = true},
        wrappers = {unit = true, player = true, item = true, timer = true, effect = true}},
    knockback = {source = 'import "systems.knockback" as Knockbacks\nimport "systems.scheduler" as Scheduler\n'
        .. 'k = Knockbacks.new Scheduler.new!\nk\\dispose!\n', systems = {scheduler = true},
        wrappers = unitFamily},
    codec = {source = 'import "systems.codec" as Codec\n'
        .. 'c = Codec.new version: 1, secret: "s", schemas: {{version: 1, fields: {}}}\nprint c\\getVersion!\n',
        systems = {}, wrappers = {}},
    sync = {source = 'import "systems.sync" as Sync\nimport "systems.scheduler" as Scheduler\n'
        .. 's = Sync.new Scheduler.new!\ns\\dispose!\n', systems = {scheduler = true},
        wrappers = {timer = true, player = true, sync = true}},
    savefile = {source = 'import "systems.savefile" as Savefile\nprint Savefile\n',
        systems = {codec = true, sync = true, scheduler = true},
        wrappers = {timer = true, player = true, sync = true}},
}
-- A module name followed by a closing quote, so wrappers.timer does not match wrappers.timerdialog.
local function bundles(bundle, name)
    return bundle:find(name .. '"', 1, true) ~= nil or bundle:find(name .. "'", 1, true) ~= nil
end
for _, entry in ipairs(public) do
    Lib.write(consumer .. '/src/main.yue', entries[entry].source)
    moonwell('build')
    local bundle = Lib.read(consumer .. '/dist/stage/map.w3x/war3map.lua')
    if not bundles(bundle, 'systems.' .. entry) then error(entry .. '-only bundle lacks systems.' .. entry, 0) end
    for _, other in ipairs(public) do
        local allowed = entries[entry].systems[other] == true
        if other ~= entry and bundles(bundle, 'systems.' .. other) ~= allowed then
            error(entry .. '-only bundle: systems.' .. other .. (allowed and ' missing' or ' included'), 0)
        end
    end
    for _, name in ipairs(wrappersPublic) do
        local allowed = entries[entry].wrappers[name] == true
        if bundles(bundle, 'wrappers.' .. name) ~= allowed then
            error(entry .. '-only bundle: wrappers.' .. name .. (allowed and ' missing' or ' included'), 0)
        end
    end
end
print('Moonwell: every entry point (' .. #public .. ') bundles only what it imports')

-- The gate examples build and have clean editor diagnostics.
Lib.remove(consumer .. '/lua/positive.lua')
for _, name in ipairs({'gate', 'gate-damage', 'gate-physics', 'gate-knockback', 'gate-save'}) do
    Lib.copy('examples/' .. name .. '.yue', consumer .. '/src/main.yue')
    moonwell('check'); moonwell('build --minify')
    compileEditor()
    clean(Lib.diagnose(luals, consumer, name), 'Gate example ' .. name)
end
print('Gate examples: all five build and their editor diagnostics are clean; game execution remains manual')
print('Integration passed')
