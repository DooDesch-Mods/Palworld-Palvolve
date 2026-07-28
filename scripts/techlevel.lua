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
    if not want then return end
    want = math.floor(want)
    if want < 1 then want = 1 end
    if want > 100 then want = 100 end

    local path = buildingFile()
    if not path then
        Log("Tech level: could not resolve the PalSchema building file - stage unchanged")
        return
    end

    local f = io.open(path, "rb")
    if not f then
        Log("Tech level: PalSchema building file not readable - stage unchanged")
        return
    end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return end

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

    local out = io.open(path, "wb")
    if not out then
        Log("Tech level: PalSchema building file not writable - stage unchanged")
        return
    end
    out:write(patched)
    out:close()
    Log(string.format(
        "Tech level: workbench unlock stage changed from %d to %d - active after the next game start",
        current, want))
end

return TechLevel
