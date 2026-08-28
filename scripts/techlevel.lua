-- Applies Config.techLevelCap to the Pal Alchemy Workbench.
--
-- The unlock stage is PalSchema data (buildings/palvolve_extractor.json,
-- "Technology": { "LevelCap": n }), read once when PalSchema loads. It is not a
-- runtime value, so it cannot be changed for the running session: this rewrites
-- the file and the new stage applies on the next game start.
--
-- Deliberately NOT done through the technology DataTable at runtime. The row is
-- reachable, but every route into it (FindRow, BP_FindRow) returns the row
-- struct by value, and struct-by-value marshalling hard-crashes the process from
-- Lua in this build - pcall does not catch it. See UE4SS-LESSONS.md.
--
-- Writing the file also repairs it after a Workshop update, which replaces the
-- PalSchema folder with the shipped default while config_user.lua survives.

local Config = require("config")

local TechLevel = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- <...>/Mods/Palvolve/scripts/techlevel.lua -> <...>/Mods/PalSchema/mods/Palvolve/...
local function buildingFile()
    local path = nil
    pcall(function()
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) ~= "@" then return end
        local scripts = src:sub(2):match("^(.*)[/\\]")      -- .../Palvolve/scripts
        local modRoot = scripts and scripts:match("^(.*)[/\\]")  -- .../Palvolve
        local modsDir = modRoot and modRoot:match("^(.*)[/\\]")  -- .../Mods
        if modsDir then
            path = modsDir .. "\\PalSchema\\mods\\Palvolve\\buildings\\palvolve_extractor.json"
        end
    end)
    return path
end

-- Rewrites only the LevelCap number and leaves the rest of the file byte for
-- byte alone, so hand edits elsewhere in the file survive.
function TechLevel.apply()
    local want = tonumber(Config.techLevelCap)
    if not want then
        Log("[ERROR] Tech level: update not attempted - configured stage is not a number")
        return
    end
    want = math.floor(want)
    if want < 1 then want = 1 end
    if want > 100 then want = 100 end

    local path = buildingFile()
    if not path then
        Log("[ERROR] Tech level: could not resolve the PalSchema building file - stage unchanged")
        return
    end

    local f, fileOpenErr = io.open(path, "rb")
    if not f then
        Log("[ERROR] Tech level: PalSchema building file not readable - stage unchanged: "
            .. tostring(fileOpenErr))
        return
    end
    local raw, readErr = f:read("*a")
    local readClosed, readCloseErr = f:close()
    if not raw then
        Log("[ERROR] Tech level: PalSchema building file read failed - stage unchanged: "
            .. tostring(readErr))
        return
    end
    if not readClosed then
        Log("[ERROR] Tech level: PalSchema building file close failed - stage unchanged: "
            .. tostring(readCloseErr))
        return
    end
    if raw == "" then
        Log("[ERROR] Tech level: PalSchema building file is empty - stage unchanged")
        return
    end

    local current = tonumber(raw:match('"LevelCap"%s*:%s*(%d+)'))
    if not current then
        Log("[ERROR] Tech level: no LevelCap field in the PalSchema building file - stage unchanged")
        return
    end
    if current == want then
        Log(string.format("[INFO] Tech level: workbench unlock stage already %d - no rewrite needed", want))
        return
    end

    local patched, n = raw:gsub('("LevelCap"%s*:%s*)%d+', '%1' .. tostring(want), 1)
    if n ~= 1 then
        Log("[ERROR] Tech level: LevelCap could not be rewritten - stage unchanged")
        return
    end

    -- Never truncate the live file. Opening it for writing would empty it before
    -- a single byte lands, so an interrupted write leaves PalSchema with a
    -- building definition it cannot parse, and the next run cannot repair it
    -- either because the LevelCap field is gone. Write a sibling file, confirm
    -- every step, then swap.
    local tmp = path .. ".new"
    local function removeTemp(reason)
        local removed, removeErr, removeCode = os.remove(tmp)
        if removed then
            Log("[INFO] Tech level: temporary file removed after " .. reason)
        elseif removeCode == 2 then
            Log("[INFO] Tech level: temporary cleanup skipped after " .. reason .. " - file absent")
        else
            Log("[WARN] Tech level: temporary cleanup failed after " .. reason .. ": "
                .. tostring(removeErr))
        end
    end
    local out, outOpenErr = io.open(tmp, "wb")
    if not out then
        Log("[ERROR] Tech level: cannot write next to the PalSchema building file - stage unchanged: "
            .. tostring(outOpenErr))
        return
    end
    local wrote, writeErr = out:write(patched)
    local closed, closeErr = out:close()
    if not (wrote and closed) then
        removeTemp("write failure")
        Log("[ERROR] Tech level: write or close failed - stage unchanged: write="
            .. tostring(writeErr) .. ", close=" .. tostring(closeErr))
        return
    end

    -- verify the replacement before it replaces anything
    local check, checkOpenErr = io.open(tmp, "rb")
    if not check then
        removeTemp("verification open failure")
        Log("[ERROR] Tech level: written file could not be opened for verification - stage unchanged: "
            .. tostring(checkOpenErr))
        return
    end
    local verify, verifyReadErr = check:read("*a")
    local verifyClosed, verifyCloseErr = check:close()
    if not verifyClosed then
        removeTemp("verification close failure")
        Log("[ERROR] Tech level: verification file close failed - stage unchanged: "
            .. tostring(verifyCloseErr))
        return
    end
    if not verify or #verify ~= #patched or not verify:match('"LevelCap"%s*:%s*' .. tostring(want)) then
        removeTemp("verification failure")
        Log("[ERROR] Tech level: written file did not verify - stage unchanged: " .. tostring(verifyReadErr))
        return
    end

    local backup = path .. ".bak"
    local oldRemoved, oldRemoveErr, oldRemoveCode = os.remove(backup)
    if oldRemoved then
        Log("[INFO] Tech level: stale rollback file removed")
    elseif oldRemoveCode == 2 then
        Log("[INFO] Tech level: no stale rollback file needed cleanup")
    else
        removeTemp("stale rollback cleanup failure")
        Log("[ERROR] Tech level: stale rollback file could not be removed - stage unchanged: "
            .. tostring(oldRemoveErr))
        return
    end
    local backedUp, backupErr = os.rename(path, backup)
    if not backedUp then
        removeTemp("backup rename failure")
        Log("[ERROR] Tech level: could not set the old file aside - stage unchanged: "
            .. tostring(backupErr))
        return
    end
    Log("[INFO] Tech level: original building file set aside for rollback")
    local swapped, swapErr = os.rename(tmp, path)
    if not swapped then
        local rolledBack, rollbackErr = os.rename(backup, path)
        if rolledBack then
            Log("[WARN] Tech level: replacement failed and the original file was restored")
        else
            Log("[ERROR] Tech level: replacement failed and rollback rename failed: "
                .. tostring(rollbackErr) .. "; the original remains at " .. backup)
        end
        removeTemp("replacement failure")
        Log("[ERROR] Tech level: could not swap the new file in - stage unchanged: "
            .. tostring(swapErr))
        return
    end
    local backupRemoved, backupRemoveErr = os.remove(backup)
    if not backupRemoved then
        Log("[WARN] Tech level: stage changed, but rollback file cleanup failed at " .. backup
            .. ": " .. tostring(backupRemoveErr))
    end
    Log(string.format(
        "[INFO] Tech level: workbench unlock stage changed from %d to %d - active after the next game start",
        current, want))
end

return TechLevel
