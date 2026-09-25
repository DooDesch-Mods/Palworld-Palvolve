-- Applies the fusion settings that live in PalSchema data: the Fusion Shard
-- and Fusion Core recipes, and the Fusion Altar's build cost and unlock stage.
--
-- Both files are generated whole from Config.fusion at every start (see
-- palschemafile.lua for why that also repairs a Workshop update). PalSchema
-- parses its raw folder before any Lua mod runs and its buildings folder a
-- few seconds after, so a changed recipe applies on the next game start and a
-- changed altar in the same one. The settings promise the next start for all.
--
-- The altar building itself always stays defined, even with fusion switched
-- off: a save with an altar standing in a base needs the building to exist,
-- and the Pals inside it with it. Only the recipes disappear.

local Config = require("config")
local PalSchemaFile = require("palschemafile")

local FusionData = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local SHARD_ID = "Palvolve_FusionShard"
local CORE_ID = "Palvolve_FusionCore"
local PRESTIGE_ID = "Palvolve_PrestigeStone"

-- Shipped values, used when a configured one does not parse. config.lua
-- already refuses a bad user value, so reaching these means Config itself was
-- edited into something unusable.
local DEFAULTS = {
    shardRecipe = "Palvolve_EvolutionStone:1,PalFluid:5,Pal_crystal_S:10",
    coreRecipe = "Palvolve_PrestigeStone:1,Palvolve_FusionShard:5,MeteorDrop:10,NightStone:3",
    altarMaterials = "PalCrystal_Ex:10,StealIngot:20,Pal_crystal_S:50",
    altarTechLevel = 43,
}

local function materials(key)
    local list, err = Config.parseMaterials(Config.fusion[key])
    if list then return list end
    Log(string.format("[ERROR] fusion.%s: %s - using the shipped materials", key, tostring(err)))
    return (Config.parseMaterials(DEFAULTS[key]))
end

local function uses(list, id)
    for _, m in ipairs(list) do
        if m.id == id then return true end
    end
    return false
end

local function materialLines(list, indent)
    local lines = {}
    for i, m in ipairs(list) do
        lines[#lines + 1] = string.format('%s"Material%d_Id": "%s",', indent, i, m.id)
        lines[#lines + 1] = string.format('%s"Material%d_Count": %d', indent, i, m.count)
    end
    for i = 2, #lines, 2 do
        if i < #lines then lines[i] = lines[i] .. "," end
    end
    return table.concat(lines, "\n")
end

local function recipeRow(rowName, productId, workAmount, list)
    local indent = "            "
    return string.format('        "%s": {\n'
        .. '%s"Product_Id": "%s",\n'
        .. '%s"Product_Count": 1,\n'
        .. '%s"WorkAmount": %d,\n'
        .. '%s\n'
        .. '        }',
        rowName, indent, productId, indent, indent, workAmount, materialLines(list, indent))
end

local function recipeFile(fusionOn)
    local shard = materials("shardRecipe")
    local core = materials("coreRecipe")
    local battle = fusionOn and Config.fusion.battleEnabled ~= false
    local altar = fusionOn and Config.fusion.altarEnabled ~= false

    if uses(shard, SHARD_ID) or uses(shard, CORE_ID) then
        Log("[WARN] fusion.shardRecipe uses a fusion item as its own material - the recipe is left out")
        shard = nil
    end
    if core and uses(core, CORE_ID) then
        Log("[WARN] fusion.coreRecipe uses the Fusion Core as its own material - the recipe is left out")
        core = nil
    end

    -- The Shard also feeds the Core, so a server with only the altar still
    -- needs it on the bench.
    local listShard = shard and (battle or (altar and core and uses(core, SHARD_ID)))
    local listCore = core and altar
    if listCore and uses(core, PRESTIGE_ID) and Config.prestigeEnabled == false then
        Log("[WARN] fusion.coreRecipe needs a Prestige Stone, but prestigeEnabled = false hides its "
            .. "recipe - the Fusion Core cannot be crafted until one of the two changes")
    end

    local rows = {}
    if listShard then rows[#rows + 1] = recipeRow("Palvolve_Craft_A03_FusionShard", SHARD_ID, 300, shard) end
    if listCore then rows[#rows + 1] = recipeRow("Palvolve_Craft_A04_FusionCore", CORE_ID, 1200, core) end
    local body = #rows > 0 and ("{\n" .. table.concat(rows, ",\n") .. "\n    }") or "{}"
    return '{\n    "DT_ItemRecipeDataTable": ' .. body .. '\n}\n',
        listShard and "listed" or "hidden", listCore and "listed" or "hidden"
end

local function altarFile()
    local level = math.floor(tonumber(Config.fusion.altarTechLevel) or DEFAULTS.altarTechLevel)
    if level < 1 then level = 1 end
    if level > 100 then level = 100 end
    local indent = "            "
    return string.format([[{
    "Palvolve_FusionAltar": {
        "BlueprintClassName": "BP_PalvolveFusionAltar",
        "BlueprintClassSoft": "/Game/Palvolve/Buildings/BP_PalvolveFusionAltar.BP_PalvolveFusionAltar_C",
        "IconTexture": "$resource/Palvolve/fusion_altar",
        "Hp": 3000,
        "Defense": 10,
        "MaterialType": "Stone",
        "MaterialSubType": "Stone",
        "bBelongToBaseCamp": true,
        "DeteriorationDamage": 0.08,
        "BuildingData": {
            "TypeA": "Pal",
            "TypeB": "Other",
            "TypeUIDisplay": "PalOther",
            "Rank": 1,
            "RequiredBuildWorkAmount": 3000.0,
%s,
            "bIsInstallOnlyHubAround": true
        },
        "Technology": {
            "UnlockBuildObjects": [
                "Palvolve_FusionAltar"
            ],
            "IconName": "Palvolve_FusionAltar",
            "IsBossTechnology": false,
            "LevelCap": %d,
            "Tier": 1,
            "Cost": 3
        }
    }
}
]], materialLines(materials("altarMaterials"), indent), level), level
end

function FusionData.apply()
    local fusionOn = Config.fusion.enabled ~= false

    local recipePath = PalSchemaFile.path("raw\\DT_ItemRecipeDataTable_Fusion.json")
    if recipePath then
        local content, shardState, coreState = recipeFile(fusionOn)
        if PalSchemaFile.writeWhole(recipePath, content, "Fusion recipes") then
            Log(string.format("[INFO] Fusion recipes: Shard %s, Core %s", shardState, coreState))
        end
    else
        Log("[ERROR] Fusion recipes: could not resolve the PalSchema raw file - recipes unchanged")
    end

    local altarPath = PalSchemaFile.path("buildings\\palvolve_fusion_altar.json")
    if altarPath then
        local content, level = altarFile()
        if PalSchemaFile.writeWhole(altarPath, content, "Fusion Altar") then
            Log(string.format("[INFO] Fusion Altar: unlocks at technology level %d, costs %s",
                level, tostring(Config.fusion.altarMaterials)))
        end
    else
        Log("[ERROR] Fusion Altar: could not resolve the PalSchema building file - altar unchanged")
    end
end

return FusionData
