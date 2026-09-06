-- installcheck.lua: which UE4SS is actually running.
--
-- Six people had UE4SS in two places at once. The copy under Pal\Binaries\Win64
-- wins and the one under Mods\NativeMods never starts, so the log the player is
-- reading belongs to the install that is not running, and the search then goes
-- everywhere except the cause.
--
-- The mod knows which one loaded it, and nothing ever said so.
--
-- The other install fault of this class, a PalSchema that did not apply, is NOT
-- here. benchfilter asks the same question from a poll that runs on every role
-- and retries until the item manager is up; a second check that runs once, on a
-- client only, and cannot tell an absent item from a throwing engine call is
-- strictly worse than the one that already exists.

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

--- true, false, or nil when the answer is "the file system would not say".
--- The three are kept apart because the all-clear below is phrased as a fact,
--- and a refused open is not the same as an absent file.
local function exists(path)
    local handle, err, code = io.open(path, "rb")
    if handle then
        handle:close()
        return true
    end
    -- ENOENT is the ordinary answer and means the file is not there. Anything
    -- else (a denied read, a path this process cannot reach) is not an answer.
    if code == 2 then return false end
    return nil, err
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

    local found, probeErr = exists(win64 .. LOADERS[other].probe)
    if found == nil then
        -- The line below states a fact, so it is not written on a guess.
        Log(string.format("loaded by %s. Whether a second UE4SS sits under %s could not be "
            .. "checked: %s", LOADERS[live].name, LOADERS[other].name, tostring(probeErr)))
        return
    end
    if not found then
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

function InstallCheck.init()
    pcall(InstallCheck.checkLoaders)
end

return InstallCheck
