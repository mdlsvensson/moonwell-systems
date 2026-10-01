-- Every error a public function raises for wrong arguments is a [systems] error at the caller's line (spec §4.2).
-- The sweep calls every function of every module, and of every class a module exposes (such as DamageSystem.Hit),
-- with an empty table as its first argument.
local modules = {'scheduler', 'signal', 'scope', 'time', 'buffs', 'aura', 'dummy', 'damage'}

---@return integer checked How many functions raised.
local function sweep(name, class, wrong)
    local checked = 0
    for key, fn in pairs(class) do
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
    return checked
end

test('every public function given a wrong argument points at its caller', function()
    local wrong = {}
    for _, name in ipairs(modules) do
        local module = require('systems.' .. name)
        assert(sweep(name, module, wrong) > 0, name .. ': no function raised')
        for key, class in pairs(module) do
            if key ~= '__index' and type(class) == 'table' and class.__index == class then
                assert(sweep(name .. '.' .. key, class, wrong) > 0, name .. '.' .. key .. ': no function raised')
            end
        end
    end
    table.sort(wrong)
    assert(#wrong == 0, #wrong .. ' misplaced errors:\n' .. table.concat(wrong, '\n'))
end)
