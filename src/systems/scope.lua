local Callback = require('systems.internal.callback')
local Check = require('systems.internal.check')

---An ownership stack: register how to release each thing you create, then dispose once. Releases run in reverse order,
---and one failing release never stops the others.
---@class MoonwellSystems.Scope
---@field package releases (fun(): ...)[]
---@field package onError (fun(message: string): ...)?
---@field package disposed boolean
local Scope = {}
Scope.__index = Scope

local METHODS = {'dispose', 'destroy', 'remove'}

---@param onError (fun(message: string): ...)? Receives release failures; default prints them.
---@return MoonwellSystems.Scope
function Scope.new(onError)
    Callback.optional(onError, 'Scope.new')
    return setmetatable({releases = {}, onError = onError, disposed = false}, Scope)
end

---@param scope MoonwellSystems.Scope
---@param release fun(): ...
local function keep(scope, release)
    if scope.disposed then
        Callback.call('Scope release', scope.onError, release)
    else
        scope.releases[#scope.releases + 1] = release
    end
end

---Takes ownership of a release function. Owning after dispose releases at once.
---@param release fun(): ...
---@return fun(): ...
function Scope:own(release)
    local scope = Check.receiver(self, Scope, 'Scope', 'Scope.own')
    Callback.check(release, 'Scope.own')
    keep(scope, release)
    return release
end

---Owns anything with a dispose, destroy or remove method (checked in that order), such as a Scheduler, a Timer or a
---Unit. Adding after dispose releases at once.
---@generic T
---@param value T
---@return T
function Scope:add(value)
    local scope = Check.receiver(self, Scope, 'Scope', 'Scope.add')
    local method
    if type(value) == 'table' then
        for _, name in ipairs(METHODS) do
            if type(value[name]) == 'function' then method = value[name]; break end
        end
    end
    if not method then error('[systems] Scope.add: expected a value with dispose, destroy or remove', 2) end
    keep(scope, function() method(value) end)
    return value
end

---True until dispose().
---@return boolean
function Scope:isActive() return not Check.receiver(self, Scope, 'Scope', 'Scope.isActive').disposed end

---Runs every release in reverse registration order. Idempotent.
function Scope:dispose()
    local scope = Check.receiver(self, Scope, 'Scope', 'Scope.dispose')
    if scope.disposed then return end
    scope.disposed = true
    local releases = scope.releases
    scope.releases = {}
    for index = #releases, 1, -1 do Callback.call('Scope release', scope.onError, releases[index]) end
end

return Scope
