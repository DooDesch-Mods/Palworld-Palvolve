local sourceRoot = (... and ... ~= "") and ... or "."
package.path = sourceRoot .. "/scripts/?.lua;" .. package.path

local timers = {}
local fakeNow = 100
os.clock = function() return fakeNow end

package.loaded.config = {
    modVersion = "1.9.0",
    serverCheck = { enabled = true, timeoutSeconds = 25 },
}

package.loaded.role = {
    chat = function() end,
    localPlayerCtx = function() return {} end,
    getLocalPlayerController = function() return nil end,
    hasWorldAuthority = function() return false end,
}

package.loaded.i18n = { msg = function(key) return key end }
package.loaded.netchannel = {
    beginGeneration = function() end,
}
package.loaded.treesync = {
    beginGeneration = function() end,
    isActive = function() return false end,
    restoreLocal = function() end,
    hasV3ForGeneration = function() return true end,
}

local kismet = {
    IsValid = function() return true end,
    IsStandalone = function() return false end,
    IsServer = function() return false end,
}

StaticFindObject = function(path)
    if path == "/Script/Engine.Default__KismetSystemLibrary" then return kismet end
    return nil
end

LoopAsync = function(_, callback)
    timers[#timers + 1] = callback
end

ExecuteInGameThread = function(callback)
    callback()
end

local function runPendingTimers()
    local pending = timers
    timers = {}
    for _, callback in ipairs(pending) do callback() end
end

local function expect(actual, wanted, label)
    if actual ~= wanted then
        error(string.format("%s: expected %s, got %s", label, wanted, tostring(actual)), 0)
    end
end

package.loaded.servercheck = nil
local ServerCheck = require("servercheck")
ServerCheck.init()

local sameCharacter = {}
ServerCheck.onEnterWorld(sameCharacter)
runPendingTimers()
expect(ServerCheck.getStatus(), "absent", "precondition after missed greet")

ServerCheck.onPong("1.9.0")
expect(ServerCheck.getStatus(), "remote", "late greet rescues the session")

ServerCheck.onEnterWorld(sameCharacter)
fakeNow = fakeNow + 30
runPendingTimers()

expect(ServerCheck.getStatus(), "remote", "duplicate entry for the confirmed world")
print("PASS: duplicate world entry preserves the confirmed Palvolve host")
