-- Runs the behavior suites, each in a fresh environment: yue -e tests/run.lua [suite ...] (spec §5).
local wrappers = os.getenv('MOONWELL_WRAPPERS') or '../moonwell-wrappers'
package.path = './src/?.lua;./tests/?.lua;' .. wrappers .. '/src/?.lua;' .. package.path
local names = {...}
if #names == 0 then names = dofile('tests/suites.lua') end

local globals, loaded = {}, {}
for key, value in pairs(_G) do globals[key] = value end
for key in pairs(package.loaded) do loaded[key] = true end
local realPrint = print

-- Restores the globals and forgets every module loaded since the runner started.
local function reset()
    local extra = {}
    for key in pairs(_G) do if globals[key] == nil then extra[#extra + 1] = key end end
    for _, key in ipairs(extra) do _G[key] = nil end
    for key, value in pairs(globals) do _G[key] = value end
    local modules = {}
    for key in pairs(package.loaded) do if not loaded[key] then modules[#modules + 1] = key end end
    for _, key in ipairs(modules) do package.loaded[key] = nil end
end

local failures = 0
for _, name in ipairs(names) do
    if not name:match('^[a-z]+$') then error('invalid suite name: ' .. name) end
    reset()
    local ok, tests, failed = pcall(function()
        dofile('tests/support.lua')
        dofile('tests/' .. name .. '.lua')
        return finish()
    end)
    reset()
    if not ok then
        failures = failures + 1
        realPrint(name .. ': ERROR ' .. tostring(tests))
    elseif failed > 0 then
        failures = failures + 1
        realPrint(name .. ': ' .. failed .. '/' .. tests .. ' tests failed')
    else
        realPrint(name .. ': SUITE PASSED: ' .. tests .. ' tests')
    end
end
if failures > 0 then
    realPrint(failures .. ' suite(s) failed')
    os.exit(1)
end
realPrint('All ' .. #names .. ' suites passed')
