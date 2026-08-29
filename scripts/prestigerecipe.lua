-- Applies Config.prestigeEnabled to the Prestige Stone recipe.
--
-- Prestige itself is gated at runtime in prestige.lua, which is what decides
-- whether a Pal is ever offered one. The recipe is not a runtime value: it is a
-- PalSchema row read once at load, so switching prestige off would otherwise
-- leave a craftable stone that nothing accepts.
--
-- Lua mods run before PalSchema reads its raw folder, so the file written here
-- is the one PalSchema loads in the same session: the switch takes hold on the
-- start that flips it, without a second one.
--
-- The row lives in its own raw file rather than among the other 112, so turning
-- it off is a whole-file write instead of surgery inside a 30 KB document shared
-- with every other recipe the mod ships.
--
-- Writing on every launch also repairs the file after a Workshop update, which
-- replaces the PalSchema folder with the shipped default while config_user.lua
-- survives.

local Config = require("config")

local PrestigeRecipe = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local WITH_RECIPE = [[{
    "DT_ItemRecipeDataTable": {
        "Palvolve_Craft_A02_PrestigeStone": {
            "Product_Id": "Palvolve_PrestigeStone",
            "Product_Count": 1,
            "WorkAmount": 300,
            "Material1_Id": "Palvolve_EvolutionStone",
            "Material1_Count": 1,
            "Material2_Id": "NightStone",
            "Material2_Count": 1
        }
    }
}
]]

local WITHOUT_RECIPE = [[{
    "DT_ItemRecipeDataTable": {}
}
]]

-- <...>/Mods/Palvolve/scripts/prestigerecipe.lua -> <...>/Mods/PalSchema/mods/Palvolve/...
local function recipeFile()
    local path = nil
    pcall(function()
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) ~= "@" then return end
        local scripts = src:sub(2):match("^(.*)[/\\]")           -- .../Palvolve/scripts
        local modRoot = scripts and scripts:match("^(.*)[/\\]")  -- .../Palvolve
        local modsDir = modRoot and modRoot:match("^(.*)[/\\]")  -- .../Mods
        if modsDir then
            path = modsDir .. "\\PalSchema\\mods\\Palvolve\\raw\\DT_ItemRecipeDataTable_Prestige.json"
        end
    end)
    return path
end

function PrestigeRecipe.apply()
    local enabled = Config.prestigeEnabled ~= false
    local wanted = enabled and WITH_RECIPE or WITHOUT_RECIPE
    local state = enabled and "listed" or "hidden"

    local path = recipeFile()
    if not path then
        Log("[ERROR] Prestige recipe: could not resolve the PalSchema raw file - recipe unchanged")
        return
    end

    -- A file that is not there is the normal first run, and a file that refuses
    -- to be read is not - both end in a rewrite, so say which one happened.
    local existing = nil
    local f, readOpenErr = io.open(path, "rb")
    if f then
        local readErr
        existing, readErr = f:read("*a")
        if not existing then
            Log("[WARN] Prestige recipe: the existing file could not be read, rewriting it: "
                .. tostring(readErr))
        end
        local okClose, closeErr = pcall(function() f:close() end)
        if not okClose then
            Log("[WARN] Prestige recipe: file close failed, continuing: " .. tostring(closeErr))
        end
    else
        Log("[INFO] Prestige recipe: no readable file at the PalSchema path, writing it: "
            .. tostring(readOpenErr))
    end
    if existing == wanted then
        Log(string.format("[INFO] Prestige recipe: already %s - no rewrite needed", state))
        return
    end

    -- Written straight over the live file, unlike the workbench stage next door:
    -- the whole content is right here, so an interrupted write is repaired by
    -- the next launch. techlevel.lua patches a number inside a file it could not
    -- rebuild from scratch; that is why it needs a temporary file and a swap,
    -- and this does not.
    local out, writeOpenErr = io.open(path, "wb")
    if not out then
        Log("[ERROR] Prestige recipe: file not writable - recipe unchanged: " .. tostring(writeOpenErr))
        return
    end
    -- pcall catches a raised error, the return value catches a refused write
    -- (a full disk reports itself that way, without raising anything).
    local okWrite, wrote, writeErr = pcall(function() return out:write(wanted) end)
    local okClose, closed, closeErr = pcall(function() return out:close() end)
    if not (okWrite and wrote) then
        Log("[ERROR] Prestige recipe: write failed - the file may be incomplete: "
            .. tostring(okWrite and writeErr or wrote))
        return
    end
    if not (okClose and closed) then
        Log("[WARN] Prestige recipe: file close failed after writing: "
            .. tostring(okClose and closeErr or closed))
    end
    Log(string.format("[INFO] Prestige recipe: %s", state))
end

return PrestigeRecipe
