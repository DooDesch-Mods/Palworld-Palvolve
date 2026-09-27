-- Palvolve rollback snapshots: the file they live in and the table loaded from it.

local EvoSnap = {}

local MOD_NAME = "Palvolve"
local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- Snapshot file next to the mod (derived from this script's location so the
-- path works regardless of the game's working directory); falls back to the
-- manual-install layout relative to Win64.
local STATE_FILE = (function()
    local path = nil
    pcall(function()
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) == "@" then
            local dir = src:sub(2):match("^(.*)[/\\]")          -- .../Palvolve/scripts
            local root = dir and dir:match("^(.*)[/\\]") or nil -- .../Palvolve
            if root then path = root .. "\\palvolve_state.lua" end
        end
    end)
    return path or "ue4ss\\Mods\\Palvolve\\palvolve_state.lua"
end)()
-- Rollback reaches back to the start of this session and no further.
--
-- Restore points live in memory. The file is still written, as executable Lua
-- (simplest robust format without a JSON lib), so the session's restore points
-- stay inspectable from outside the game, but it is never read back: a rollback
-- returns what the evolution cost, and a restore point that outlives the
-- session would hand back stones for an evolution made days ago, on a Pal that
-- has been levelled, bred or traded since. Undoing what you just did is the
-- promise; undoing your history is not.
EvoSnap.snapshots = {}
-- Rollback lives in memory for the session, so there is no state file. Older
-- versions wrote one on the game thread after every evolution, never read it
-- back, and left it behind on uninstall - so it is deleted here, once.
local function loadSnapshots()
    EvoSnap.snapshots = {}
    local hadEntries = false
    pcall(function()
        local f = io.open(STATE_FILE, "r")
        if not f then return end
        local body = f:read("*a") or ""
        f:close()
        hadEntries = body:find("{ key =", 1, true) ~= nil
        os.remove(STATE_FILE)
    end)
    if hadEntries then
        Log("Rollback restore points from earlier sessions discarded - rollback covers this session")
    end
end

EvoSnap.STATE_FILE = STATE_FILE
EvoSnap.loadSnapshots = loadSnapshots

return EvoSnap
