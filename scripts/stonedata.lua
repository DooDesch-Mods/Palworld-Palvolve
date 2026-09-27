-- stonedata.lua: the crafting recipes of Palvolve's stones and the Pal
-- Alchemy Workbench's build cost and unlock stage, from Config.recipes.
--
-- All of it is PalSchema data, generated whole at every start (see
-- palschemafile.lua for why that also repairs a Workshop update). PalSchema
-- parses its raw folder before any Lua mod runs and its buildings folder a few
-- seconds after, so a changed setting applies on the next game start.
--
--   raw/DT_ItemRecipeDataTable_Stones.json    Evolution Stone, 9 Adaptation Stones
--   raw/DT_ItemRecipeDataTable_Prestige.json  Prestige Stone (empty with prestige off)
--   buildings/palvolve_extractor.json         the workbench
--
-- An Adaptation Stone always takes its element's essence; the setting is the
-- rest of the recipe, so one value serves all nine.

local Config = require("config")
local PalSchemaFile = require("palschemafile")

local StoneData = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local EVOLUTION_ID = "Palvolve_EvolutionStone"
local PRESTIGE_ID = "Palvolve_PrestigeStone"
local ADAPTATION_PREFIX = "Palvolve_AdaptationStone_"
local ESSENCE_PREFIX = "Palvolve_Essence_"

-- Row order is the order the workbench lists them in.
local ELEMENTS = { "Normal", "Fire", "Water", "Leaf", "Electricity", "Ice", "Earth", "Dark", "Dragon" }

-- Shipped values, used when a configured one does not parse. config.lua
-- already refuses a bad user value, so reaching these means Config itself was
-- edited into something unusable.
local DEFAULTS = {
    evolutionStone = "Pal_crystal_S:20,MeteorDrop:3,PalFluid:5",
    prestigeStone = "Palvolve_EvolutionStone:1,NightStone:1",
    adaptationStone = "Palvolve_EvolutionStone:1",
    benchMaterials = "Wood:30,Stone:20,Pal_crystal_S:10",
}
StoneData.DEFAULTS = DEFAULTS

-- The essence takes one of the four material slots.
local ADAPTATION_MAX = 3

local function materials(key, max)
    local recipes = type(Config.recipes) == "table" and Config.recipes or {}
    local list, err = Config.parseMaterials(recipes[key], max)
    if list then return list end
    Log(string.format("[ERROR] recipes.%s: %s - using the shipped materials", key, tostring(err)))
    return (Config.parseMaterials(DEFAULTS[key], max))
end

local function usesPrefix(list, prefix)
    for _, m in ipairs(list) do
        if m.id:sub(1, #prefix) == prefix then return m.id end
    end
    return nil
end

local function uses(list, id)
    for _, m in ipairs(list) do
        if m.id == id then return true end
    end
    return false
end

local function stonesFile()
    local rows = {}
    local evolution = materials("evolutionStone")
    if uses(evolution, EVOLUTION_ID) then
        Log("[WARN] recipes.evolutionStone uses the Evolution Stone as its own material - the recipe is left out")
    else
        rows[#rows + 1] = PalSchemaFile.recipeRow("Palvolve_Craft_A01_EvolutionStone", EVOLUTION_ID, 300, evolution)
    end

    local shared = materials("adaptationStone", ADAPTATION_MAX)
    local own = usesPrefix(shared, ADAPTATION_PREFIX) or usesPrefix(shared, ESSENCE_PREFIX)
    if own then
        Log(string.format("[WARN] recipes.adaptationStone lists %s, but each stone adds its own essence and "
            .. "cannot take a stone of its kind - the Adaptation Stone recipes are left out", own))
    else
        for i, element in ipairs(ELEMENTS) do
            local list = {}
            for _, m in ipairs(shared) do list[#list + 1] = m end
            list[#list + 1] = { id = ESSENCE_PREFIX .. element, count = 1 }
            rows[#rows + 1] = PalSchemaFile.recipeRow(string.format("Palvolve_Craft_B%02d_Adapt_%s", i, element),
                ADAPTATION_PREFIX .. element, 300, list)
        end
    end
    local summary = string.format("Evolution Stone %s, Adaptation Stones %s",
        uses(evolution, EVOLUTION_ID) and "hidden" or "listed", own and "hidden" or "listed")
    return PalSchemaFile.recipeTable(rows), summary
end

local function prestigeFile()
    if Config.prestigeEnabled == false then
        return PalSchemaFile.recipeTable({}), "hidden (prestige is off)"
    end
    local list = materials("prestigeStone")
    if uses(list, PRESTIGE_ID) then
        Log("[WARN] recipes.prestigeStone uses the Prestige Stone as its own material - the recipe is left out")
        return PalSchemaFile.recipeTable({}), "hidden"
    end
    return PalSchemaFile.recipeTable({
        PalSchemaFile.recipeRow("Palvolve_Craft_A02_PrestigeStone", PRESTIGE_ID, 300, list),
    }), "listed"
end

local function benchFile()
    local level = math.floor(tonumber(Config.techLevelCap) or 10)
    if level < 1 then level = 1 end
    if level > 100 then level = 100 end
    return string.format([[{
    "Palvolve_ElementExtractor": {
        "BlueprintClassName": "BP_BuildObject_MedicineFacility_01",
        "BlueprintClassSoft": "/Game/Pal/Blueprint/MapObject/BuildObject/BP_BuildObject_MedicineFacility_01.BP_BuildObject_MedicineFacility_01_C",
        "IconTexture": "$resource/Palvolve/extractor_bench",
        "Hp": 1000,
        "Defense": 2,
        "MaterialType": "Wood",
        "MaterialSubType": "Wood",
        "bBelongToBaseCamp": true,
        "DeteriorationDamage": 0.08,
        "BuildingData": {
            "TypeA": "Product",
            "TypeB": "Prod_Craft",
            "TypeUIDisplay": "Product_Repair",
            "Rank": 1,
            "RequiredBuildWorkAmount": 800.0,
%s
        },
        "Assignments": [
            {
                "WorkSuitability": "Handcraft",
                "WorkSuitabilityRank": 1,
                "bPlayerWorkable": true,
                "bBaseCampWorkerWorkable": true,
                "WorkType": "CommonTemp",
                "WorkActionType": "CommonWork",
                "WorkerMaxNum": 0,
                "AffectSanityValue": -0.15,
                "AffectFullStomachValue": 1.0
            }
        ],
        "Technology": {
            "UnlockBuildObjects": [
                "Palvolve_ElementExtractor"
            ],
            "IconName": "Palvolve_ElementExtractor",
            "IsBossTechnology": false,
            "LevelCap": %d,
            "Tier": 1,
            "Cost": 2
        }
    }
}
]], PalSchemaFile.materialLines(materials("benchMaterials"), "            "), level),
        string.format("unlocks at technology level %d, costs %s", level,
            tostring(Config.recipes and Config.recipes.benchMaterials))
end

--- Every file this module writes, with its content for the current config:
--- { rel, label, content, summary }. check-mod-lua.mjs compares the default
--- output with the shipped files.
function StoneData.files()
    local out = {}
    local stones, stonesSummary = stonesFile()
    out[#out + 1] = { rel = "raw\\DT_ItemRecipeDataTable_Stones.json", label = "Stone recipes",
        content = stones, summary = stonesSummary }
    local prestige, prestigeSummary = prestigeFile()
    out[#out + 1] = { rel = "raw\\DT_ItemRecipeDataTable_Prestige.json", label = "Prestige recipe",
        content = prestige, summary = prestigeSummary }
    local bench, benchSummary = benchFile()
    out[#out + 1] = { rel = "buildings\\palvolve_extractor.json", label = "Alchemy Workbench",
        content = bench, summary = benchSummary }
    return out
end

function StoneData.apply()
    for _, f in ipairs(StoneData.files()) do
        local path = PalSchemaFile.path(f.rel)
        if not path then
            Log(string.format("[ERROR] %s: could not resolve the PalSchema file - unchanged", f.label))
        elseif PalSchemaFile.writeWhole(path, f.content, f.label) then
            Log(string.format("[INFO] %s: %s", f.label, f.summary))
        end
    end
end

return StoneData
