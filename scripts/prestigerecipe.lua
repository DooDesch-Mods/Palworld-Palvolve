-- Applies Config.prestigeEnabled to the Prestige Stone recipe.
--
-- Prestige itself is gated at runtime in prestige.lua, which is what decides
-- whether a Pal is ever offered one. The recipe is not a runtime value: it is a
-- PalSchema row read once at load, so switching prestige off would otherwise
-- leave a craftable stone that nothing accepts.
--
-- PalSchema parses its raw folder before any Lua mod runs, so the file written
-- here is the one the NEXT start loads: the switch takes hold one start after
-- it was flipped.
--
-- The row lives in its own raw file rather than among the other 112, so turning
-- it off is a whole-file write instead of surgery inside a 30 KB document shared
-- with every other recipe the mod ships.
--
-- Writing on every launch also repairs the file after a Workshop update, which
-- replaces the PalSchema folder with the shipped default while config_user.lua
-- survives.

local Config = require("config")
local PalSchemaFile = require("palschemafile")

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

function PrestigeRecipe.apply()
    local enabled = Config.prestigeEnabled ~= false
    local path = PalSchemaFile.path("raw\\DT_ItemRecipeDataTable_Prestige.json")
    if not path then
        Log("[ERROR] Prestige recipe: could not resolve the PalSchema raw file - recipe unchanged")
        return
    end
    if PalSchemaFile.writeWhole(path, enabled and WITH_RECIPE or WITHOUT_RECIPE, "Prestige recipe") then
        Log(string.format("[INFO] Prestige recipe: %s", enabled and "listed" or "hidden"))
    end
end

return PrestigeRecipe
