-- installcheck.lua: the two install faults that produce most support threads,
-- reported by the mod instead of by a person reading someone else's log.
--
-- 1. PalSchema is installed but never loads. The radial wheel works, and the
--    Pal Alchemy Workbench, the technology entry and every stone are missing.
--    Eight reports, the same diagnosis every time, and every time it took a
--    thread to reach it.
-- 2. UE4SS is in two places at once. The copy under Pal\Binaries\Win64 wins and
--    the one under Mods\NativeMods never starts, so the log the player is
--    reading belongs to the install that is not running. Six reports.
--
-- Both are visible from inside the game, and neither was ever said out loud.

local InstallCheck = {}

local MOD_NAME = "Palvolve"

local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

--- Absolute path of this file, or nil when the loader hands out a chunk name
--- and the module search cannot resolve one either.
local function ownPath()
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    src = src:gsub("^@", "")
    if src == "" or not src:find("[/\\]") then
        src = ""
        pcall(function() src = package.searchpath("installcheck", package.path) or "" end)
    end
    if src == "" then return nil end
    return src
end

local function exists(path)
    local handle = io.open(path, "rb")
    if not handle then return false end
    handle:close()
    return true
end

-- ---------------------------------------------------------------- loaders

-- Where each layout keeps the framework. The manual install is the proxy dll
-- in Win64 itself; the game-managed one nests it under Mods\NativeMods.
local LOADERS = {
    { name = "Pal\\Binaries\\Win64\\ue4ss", probe = "\\ue4ss\\UE4SS.dll" },
    { name = "Pal\\Binaries\\Win64\\Mods\\NativeMods\\UE4SS",
      probe = "\\Mods\\NativeMods\\UE4SS\\UE4SS.dll" },
}

--- Says so when a second UE4SS sits in the same install. Runs once, at startup.
function InstallCheck.checkLoaders()
    local path = ownPath()
    if not path then
        Log("install check: this loader does not say where the mod was loaded from, "
            .. "so a second UE4SS install cannot be ruled out")
        return
    end
    local win64 = path:match("^(.*[/\\][Bb]inaries[/\\][Ww]in64)[/\\]")
    if not win64 then
        Log("install check: the mod is not under Pal\\Binaries\\Win64 (" .. path .. ")")
        return
    end

    -- Which one loaded us is decided by our own path, not by which files
    -- exist: both can be on disk, and only one of them is running.
    local live = path:find("[/\\][Mm]ods[/\\][Nn]ative[Mm]ods[/\\]") and 2 or 1
    local other = live == 1 and 2 or 1

    if not exists(win64 .. LOADERS[other].probe) then
        -- Said even when there is nothing wrong. A check that only speaks up on
        -- failure cannot be told apart from a check that never ran, and this is
        -- the line a support reader needs first anyway.
        Log("loaded by " .. LOADERS[live].name .. " (no second UE4SS install)")
        return
    end

    Log(string.format(
        "two UE4SS installs found. Running: %s. Idle and writing no log: %s. "
            .. "A log from the idle one shows nothing about this session; remove it.",
        LOADERS[live].name, LOADERS[other].name))
end

-- -------------------------------------------------------------- PalSchema

local schemaChecked = false

--- Says so when the PalSchema half of the mod never arrived. Runs on the first
--- world entry, because the item manager does not exist before then.
function InstallCheck.checkPalSchema()
    if schemaChecked then return end

    local mgr = nil
    pcall(function() mgr = FindFirstOf("PalItemIDManager") end)
    if not (mgr and mgr:IsValid()) then
        -- Not an answer yet: no manager means the world is not far enough
        -- along, and reporting a missing item from here would be a false
        -- alarm. Left unchecked so the next world entry tries again.
        return
    end
    schemaChecked = true

    local found = false
    pcall(function()
        local data = mgr:GetStaticItemData(FName("Palvolve_EvolutionStone"))
        found = data ~= nil and data:IsValid()
    end)
    if found then
        Log("PalSchema data is loaded (the evolution stone exists)")
        return
    end

    Log("PalSchema did not load Palvolve's items. The evolve wheel still works, "
        .. "but the Pal Alchemy Workbench, its technology entry and every stone "
        .. "are absent. Check UE4SS.log for a PalSchema line: if the word does "
        .. "not appear, PalSchema itself never started. The usual cause is a "
        .. "stale copy - delete the PalSchema folder from both Mods\\ManagedMods "
        .. "and ue4ss\\Mods, then subscribe again.")
end

function InstallCheck.init()
    pcall(InstallCheck.checkLoaders)
end

return InstallCheck
