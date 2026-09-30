-- Every error a public function raises for wrong arguments is a [systems] error at the caller's line (spec §4.2).
-- The sweep calls every function of every module with an empty table as its first argument.
local modules = {'scheduler', 'signal', 'scope', 'time'}

test('every public function given a wrong argument points at its caller', function()
    local wrong = {}
    for _, name in ipairs(modules) do
        local checked = 0
        for key, fn in pairs(require('systems.' .. name)) do
            if type(fn) == 'function' then
                local ok, err = pcall(function() fn({}) end)
                if not ok then
                    checked = checked + 1
                    local message = tostring(err)
                    if not message:find('^tests/blame%.lua:%d+: %[systems%] ') then
                        wrong[#wrong + 1] = name .. '.' .. key .. ' -> ' .. message
                    end
                end
            end
        end
        assert(checked > 0, name .. ': no function raised')
    end
    table.sort(wrong)
    assert(#wrong == 0, #wrong .. ' misplaced errors:\n' .. table.concat(wrong, '\n'))
end)
