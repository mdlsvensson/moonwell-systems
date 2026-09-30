-- Test helpers, loaded fresh for every suite by tests/run.lua. A copy of the wrappers' helpers without their
-- Warcraft fixtures.
local calls, implementations, tests, failed = {}, {}, 0, 0
local realPrint = print
PRINTED = {}
print = function(...)
    local parts = table.pack(...)
    for index = 1, parts.n do parts[index] = tostring(parts[index]) end
    PRINTED[#PRINTED + 1] = table.concat(parts, '\t', 1, parts.n)
end

function eq(actual, expected)
    if actual ~= expected then error('expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2) end
end

function fails(fn, fragment)
    local ok, err = pcall(fn)
    assert(not ok, 'expected failure')
    assert(tostring(err):find(fragment, 1, true), tostring(err))
end

---Like fails, and the error must point at a line in a test file: errors blame their caller (spec §4.2).
function failsAt(fn, fragment)
    local ok, err = pcall(fn)
    assert(not ok, 'expected failure')
    local message = tostring(err)
    assert(message:find(fragment, 1, true), message)
    assert(message:find('^tests/[%w_]+%.lua:%d+: '), 'expected the calling test line in: ' .. message)
end

function native(name, implementation)
    implementations[name] = implementation
    _G[name] = function(...)
        calls[#calls + 1] = {name = name, args = table.pack(...)}
        return implementations[name](...)
    end
end

function resetCalls() calls = {}; PRINTED = {} end
function callCount(name)
    local count = 0
    for _, call in ipairs(calls) do if call.name == name then count = count + 1 end end
    return count
end
function totalCalls() return #calls end
function expectCall(name, ...)
    local expected = table.pack(...)
    for index = #calls, 1, -1 do
        if calls[index].name == name then
            eq(calls[index].args.n, expected.n)
            for position = 1, expected.n do eq(calls[index].args[position], expected[position]) end
            return
        end
    end
    error('no call to ' .. name, 2)
end

function test(name, fn)
    tests = tests + 1
    resetCalls()
    local ok, err = pcall(fn)
    if not ok then failed = failed + 1; realPrint('  FAIL ' .. name .. ': ' .. tostring(err)) end
end

function finish() return tests, failed end
