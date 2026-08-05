-- Applies Config.techLevelCap to the Pal Alchemy Workbench.
--
-- The unlock stage is PalSchema DATA (buildings/palvolve_extractor.json,
-- "Technology": { "LevelCap": n }), read once when PalSchema loads - long before
-- any Lua of ours runs. It is not a runtime value, so it cannot be changed for
-- the RUNNING session: this rewrites the file and the new stage applies on the
-- next game start.
--
-- Deliberately NOT done through the technology DataTable at runtime. The row is
-- reachable, but every route into it (FindRow, BP_FindRow) hands back the row
-- struct BY VALUE, and a by-value copy is not a handle: struct-by-value
-- marshalling hard-crashes the process from Lua on this build, and pcall does
-- not catch it. Same law the fork's :get() lesson records.
--
-- Running on every launch also REPAIRS the value: a reinstall or a Workshop
-- update replaces the whole data half with its shipped default while
-- config_user.lua survives, which would otherwise silently revert the stage.
--
-- SCOPE: this one file. The data half's raw/ folder carries LevelCap fields of
-- its own (palvolve_saddletech.jsonc moves every gear tech to its map's begin
-- level) - a different feature entirely, and never touched from here.

local Config = require("config")

local TechLevel = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- <...>\Mods\Palvolve-Fork\Scripts\techlevel.lua
--   -> <...>\Mods\PalSchema\mods\Palvolve-Fork\buildings\palvolve_extractor.json
--
-- Same hop count as the STATE_FILE derivation in evolution.lua and for the same
-- reason: the game's working directory is not the mod's, so the only reliable
-- anchor is this script's own source path. The PalSchema mods folder is a
-- SIBLING of the UE4SS Mods folder's entries, so two hops up land on Mods and
-- the rest is a fixed descent. The mod folder NAME is read back off our own
-- path rather than written out - the two halves are installed under the same
-- name, so a renamed install keeps finding its own data.
local function buildingFile()
    local path = nil
    pcall(function()
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) ~= "@" then return end
        local scripts = src:sub(2):match("^(.*)[/\\]")           -- ...\Palvolve-Fork\Scripts
        local modRoot = scripts and scripts:match("^(.*)[/\\]")  -- ...\Palvolve-Fork
        local modsDir = modRoot and modRoot:match("^(.*)[/\\]")  -- ...\Mods
        local modName = modRoot and modRoot:match("([^/\\]+)$")  -- Palvolve-Fork
        if modsDir and modName and modName ~= "" then
            path = modsDir .. "\\PalSchema\\mods\\" .. modName
                .. "\\buildings\\palvolve_extractor.json"
        end
    end)
    return path
end

-- Every filesystem touch is wrapped: this runs at mod load, and a Lua error
-- here would take the whole startup chain with it for the sake of a cosmetic
-- unlock stage.
local function readFile(path)
    local raw = nil
    pcall(function()
        local f = io.open(path, "rb")
        if not f then return end
        raw = f:read("*a")
        f:close()
    end)
    return raw
end

local function writeFile(path, data)
    local ok = false
    pcall(function()
        local out = io.open(path, "wb")
        if not out then return end
        local wrote = out:write(data)
        local closed = out:close()
        ok = (wrote and closed) and true or false
    end)
    return ok
end

local function tryRemove(path)
    local ok, res = pcall(os.remove, path)
    return ok and res and true or false
end

local function tryRename(from, to)
    local ok, res = pcall(os.rename, from, to)
    return ok and res and true or false
end

-- Rewrites the LevelCap number and nothing else, leaving the rest of the file
-- byte for byte alone so hand edits elsewhere in it survive.
function TechLevel.apply()
    local want = tonumber(Config.techLevelCap)
    if not want then return end
    want = math.floor(want)
    if want < 1 then want = 1 end
    if want > 100 then want = 100 end

    local path = buildingFile()
    if not path then
        Log("Tech level: could not resolve the PalSchema building file - stage unchanged")
        return
    end
    if Config.devMode then Log("[techlevel] data half: " .. path) end

    -- Crash-recovery preamble (fork addition over upstream, review catch): a
    -- process kill in the window between the two renames below leaves NO live
    -- file - only the .bak set aside a moment earlier. Without this, every
    -- later launch reads "not readable - stage unchanged" forever and the
    -- workbench silently vanishes from the tech tree. If the live file is
    -- gone and a backup sits beside it, restore the backup FIRST.
    if not readFile(path) then
        local backup = path .. ".bak"
        if readFile(backup) and tryRename(backup, path) then
            Log("Tech level: live building file was missing - restored the backup"
                .. " left by an interrupted swap")
        end
    end

    local raw = readFile(path)
    if not raw then
        Log("Tech level: PalSchema building file not readable - stage unchanged")
        return
    end
    if raw == "" then return end

    local current = tonumber(raw:match('"LevelCap"%s*:%s*(%d+)'))
    if not current then
        Log("Tech level: no LevelCap field in the PalSchema building file - stage unchanged")
        return
    end
    if current == want then return end

    local patched, n = raw:gsub('("LevelCap"%s*:%s*)%d+', '%1' .. tostring(want), 1)
    if n ~= 1 then
        Log("Tech level: LevelCap could not be rewritten - stage unchanged")
        return
    end

    -- Never truncate the LIVE file. Opening it for writing empties it before a
    -- single byte lands, so an interrupted write leaves PalSchema with a
    -- building definition it cannot parse - and the next run cannot repair it
    -- either, because the LevelCap field it matches on is gone with it. Write a
    -- sibling, confirm every step, then swap.
    local tmp = path .. ".new"
    if not writeFile(tmp, patched) then
        tryRemove(tmp)
        Log("Tech level: cannot write next to the PalSchema building file - stage unchanged")
        return
    end

    -- verify the replacement before it replaces anything
    local verify = readFile(tmp)
    if not verify or #verify ~= #patched
        or not verify:match('"LevelCap"%s*:%s*' .. tostring(want)) then
        tryRemove(tmp)
        Log("Tech level: written file did not verify - stage unchanged")
        return
    end

    local backup = path .. ".bak"
    tryRemove(backup)
    if not tryRename(path, backup) then
        tryRemove(tmp)
        Log("Tech level: could not set the old file aside - stage unchanged")
        return
    end
    if not tryRename(tmp, path) then
        tryRename(backup, path) -- put the original back
        tryRemove(tmp)
        Log("Tech level: could not swap the new file in - stage unchanged")
        return
    end
    -- only now, with the new file in place, does the original stop being the
    -- only intact copy
    tryRemove(backup)
    Log(string.format(
        "Tech level: workbench unlock stage changed from %d to %d - active after the next game start",
        current, want))
end

return TechLevel
