-- Files of the Palvolve PalSchema mod that the Lua side writes at startup.
--
-- PalSchema reads its data once, when it loads. Settings that live in that
-- data (a recipe, a building cost, an unlock stage) are therefore applied by
-- rewriting the file on every start: that also repairs it after a Workshop
-- update, which replaces the PalSchema folder with the shipped default while
-- config_user.lua survives.

local PalSchemaFile = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

--- Absolute path of a file inside Mods\PalSchema\mods\Palvolve, or nil.
--- `rel` uses backslashes, e.g. "raw\\DT_ItemRecipeDataTable_Fusion.json".
function PalSchemaFile.path(rel)
    local path = nil
    local ok, err = pcall(function()
        -- <...>/Mods/Palvolve/scripts/palschemafile.lua
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) ~= "@" then return end
        local scripts = src:sub(2):match("^(.*)[/\\]")           -- .../Palvolve/scripts
        local modRoot = scripts and scripts:match("^(.*)[/\\]")  -- .../Palvolve
        local modsDir = modRoot and modRoot:match("^(.*)[/\\]")  -- .../Mods
        if modsDir then
            path = modsDir .. "\\PalSchema\\mods\\Palvolve\\" .. rel
        end
    end)
    if not ok then Log("[ERROR] PalSchema path for " .. rel .. " failed: " .. tostring(err)) end
    return path
end

--- Replaces a whole file with `wanted` unless it already holds exactly that.
--- `label` names the file in the log. Returns true when the file holds
--- `wanted` afterwards.
---
--- Written straight over the live file: the whole content is generated, so an
--- interrupted write is repaired by the next launch. techlevel.lua patches a
--- number inside a file it could not rebuild and needs a swap for that reason.
function PalSchemaFile.writeWhole(path, wanted, label)
    -- A file that is not there is the normal first run, and a file that refuses
    -- to be read is not - both end in a rewrite, so say which one happened.
    local existing = nil
    local f, readOpenErr = io.open(path, "rb")
    if f then
        local readErr
        existing, readErr = f:read("*a")
        if not existing then
            Log("[WARN] " .. label .. ": the existing file could not be read, rewriting it: "
                .. tostring(readErr))
        end
        local okClose, closeErr = pcall(function() f:close() end)
        if not okClose then
            Log("[WARN] " .. label .. ": file close failed, continuing: " .. tostring(closeErr))
        end
    else
        Log("[INFO] " .. label .. ": no readable file at the PalSchema path, writing it: "
            .. tostring(readOpenErr))
    end
    if existing == wanted then
        Log("[INFO] " .. label .. ": unchanged")
        return true
    end

    local out, writeOpenErr = io.open(path, "wb")
    if not out then
        Log("[ERROR] " .. label .. ": file not writable - unchanged: " .. tostring(writeOpenErr))
        return false
    end
    -- pcall catches a raised error, the return value catches a refused write
    -- (a full disk reports itself that way, without raising anything).
    local okWrite, wrote, writeErr = pcall(function() return out:write(wanted) end)
    local okClose, closed, closeErr = pcall(function() return out:close() end)
    if not (okWrite and wrote) then
        Log("[ERROR] " .. label .. ": write failed - the file may be incomplete: "
            .. tostring(okWrite and writeErr or wrote))
        return false
    end
    if not (okClose and closed) then
        Log("[WARN] " .. label .. ": file close failed after writing: "
            .. tostring(okClose and closeErr or closed))
    end
    Log("[INFO] " .. label .. ": written")
    return true
end

return PalSchemaFile
