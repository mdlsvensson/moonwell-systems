-- Planted native-call mistakes. Integration checks src/wrappers with LuaLS and Moonwell's native declarations; these
-- lines prove that the check reports each kind of mistake. Every other file in that check must be clean.
local model = 'model.mdx'
AddSpecialEfectTarget(model, nil, 'origin') -- EXPECT undefined-global
local effect = AddSpecialEffect(model, 0) -- EXPECT missing-parameter
DestroyEffect(effect, true) -- EXPECT redundant-parameter
SetUnitX(Player(0), 0) -- EXPECT param-type-mismatch
local function position() return 0, 0 end
SetUnitPosition(CreateUnit(Player(0), 1751543663, 0, 0, 0), position())
return true
