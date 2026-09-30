LEAK = true
test('a passing test', function() eq(1, 1) end)
test('print is captured', function() print('hidden', 2); eq(PRINTED[1], 'hidden\t2') end)
test('failsAt sees this file', function() failsAt(function() error('boom', 1) end, 'boom') end)
test('the leak from an earlier run is gone', function() eq(SEEN_BEFORE, nil); SEEN_BEFORE = true end)
