-- Lua 5.3.6 syntax of every file under src/, tests/ and tools/, and every suite listed: yue -e tools/check.lua.
package.path = './tools/?.lua;' .. package.path
local Lib = require('lib')
local luac = os.getenv('MOONWELL_LUAC') or 'luac'
local version = Lib.must(Lib.quote(Lib.native(luac)) .. ' -v')
if not version:find('Lua 5.3.6', 1, true) then error('Lua 5.3.6 luac is required, found: ' .. version, 0) end
local count = 0
for _, dir in ipairs({'src', 'tests', 'tools'}) do
    for _, file in ipairs(Lib.files(dir, '.lua')) do
        Lib.must(Lib.quote(Lib.native(luac)) .. ' -p ' .. Lib.quote(Lib.native(file)))
        count = count + 1
    end
end
Lib.mkdir('.test-work')
Lib.write('.test-work/lua54-syntax.lua', 'local x <const> = 1\nreturn x\n')
if Lib.run(Lib.quote(Lib.native(luac)) .. ' -p ' .. Lib.quote(Lib.native('.test-work/lua54-syntax.lua'))) == 0 then
    error('Lua 5.4 syntax was accepted', 0)
end
-- Every suite file must be listed, so none is skipped silently.
local listed = {}
for _, name in ipairs(dofile('tests/suites.lua')) do listed[name] = true end
local helpers = {run = true, suites = true, support = true}
for _, file in ipairs(Lib.files('tests', '.lua')) do
    local name = file:match('^tests/([a-z]+)%.lua$')
    if name and not helpers[name] and not listed[name] then error('suite not listed in tests/suites.lua: ' .. name, 0) end
end
print('Lua 5.3.6 syntax: ' .. count .. ' files passed; Lua 5.4-only syntax rejected; every suite listed')
