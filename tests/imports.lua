-- Importing a module calls no native and creates nothing; time loads no wrappers module (spec §4.1). No natives are
-- defined here, so a native call at import would raise and fail the suite.
test('the time module loads no wrappers module', function()
    require('systems.time')
    eq(totalCalls(), 0)
    for name in pairs(package.loaded) do assert(not name:find('^wrappers%.'), name) end
end)

test('geometry and terrain load no wrappers module', function()
    require('systems.geometry')
    require('systems.terrain')
    eq(totalCalls(), 0)
    for name in pairs(package.loaded) do assert(not name:find('^wrappers%.'), name) end
end)

test('importing every module calls no native', function()
    for _, name in ipairs({'scheduler', 'signal', 'scope', 'time'}) do require('systems.' .. name) end
    eq(totalCalls(), 0)
    eq(package.loaded['wrappers.timer'] ~= nil, true)
    eq(package.loaded['wrappers.unit'], nil)
end)

test('buffs and aura load Unit but no dummy module', function()
    require('systems.aura')
    eq(totalCalls(), 0)
    eq(package.loaded['systems.buffs'] ~= nil, true)
    eq(package.loaded['wrappers.unit'] ~= nil, true)
    eq(package.loaded['systems.dummy'], nil)
end)

test('the damage module calls no native at import and loads no dummy or trigger module', function()
    require('systems.damage')
    eq(totalCalls(), 0)
    eq(package.loaded['wrappers.damage'] ~= nil, true)
    eq(package.loaded['systems.dummy'], nil)
    eq(package.loaded['wrappers.trigger'], nil)
end)

test('the dummy module calls no native at import and loads no group or trigger module', function()
    require('systems.dummy')
    eq(totalCalls(), 0)
    eq(package.loaded['wrappers.group'], nil)
    eq(package.loaded['wrappers.trigger'], nil)
end)

test('the missile and knockback modules call no native at import and load no group module', function()
    require('systems.missile')
    require('systems.knockback')
    eq(totalCalls(), 0)
    eq(package.loaded['wrappers.effect'] ~= nil, true)
    eq(package.loaded['wrappers.group'], nil)
end)
