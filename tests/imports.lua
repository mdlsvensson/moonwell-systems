-- Importing a module calls no native and creates nothing; time loads no wrappers module (spec §4.1). No natives are
-- defined here, so a native call at import would raise and fail the suite.
test('the time module loads no wrappers module', function()
    require('systems.time')
    eq(totalCalls(), 0)
    for name in pairs(package.loaded) do assert(not name:find('^wrappers%.'), name) end
end)

test('importing every module calls no native', function()
    for _, name in ipairs({'scheduler', 'signal', 'scope', 'time'}) do require('systems.' .. name) end
    eq(totalCalls(), 0)
    eq(package.loaded['wrappers.timer'] ~= nil, true)
    eq(package.loaded['wrappers.unit'], nil)
end)
