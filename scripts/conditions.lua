-- Palvolve conditions: optional per-pair environment/state requirements.
-- A pair's `conditions` field is an array of condition id strings. ALL ids of
-- a pair must hold at evolve time (AND). An either/or split is expressed as
-- two pairs with the same from/to and different conditions (the gates try
-- every same-target candidate). Parameterized ids use a colon:
--   "knowsMove:Dragon"  (EPalElementType name)
--   "inParty:Penguin"   (DT_PalMonsterParameter row name)
--
-- Evaluation is pull-based only: plain reads inside the existing game-thread
-- call frames of the gates. No hooks, no delegates, no timers.
-- A known condition whose game API fails evaluates as NOT met (fail closed):
-- a silently granted evolution would be an invisible correctness hole, a
-- greyed option with a reason is visible and debuggable.
--
-- This module must not require config.lua (config.lua requires this module
-- for its sanitizer); devMode is read lazily via package.loaded.

local I18n = require("i18n")

local Conditions = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local function devMode()
    local cfg = package.loaded and package.loaded["config"]
    return type(cfg) == "table" and cfg.devMode == true
end

-- ------------------------------------------------------------- game constants
-- Values below come from the game data (object dump + DT_WorldMapAreaData).

-- EPalStatusID (objectdump 99757-99836)
local STATUS = {
    Poison = 5, Stun = 7, Sleep = 9, Burn = 19, Wetness = 20,
    Freeze = 21, Electrical = 22, Muddy = 23, Darkness = 25,
    ToxicGas = 43, ToxicGasFromAttack = 44,
}

-- EPalStageType::Dungeon (objectdump 102188-102194)
local STAGE_DUNGEON = 1

-- EPalElementType (objectdump 99921-99931)
local ELEMENTS = {
    Normal = 1, Fire = 2, Water = 3, Leaf = 4, Electricity = 5,
    Ice = 6, Earth = 7, Dark = 8, Dragon = 9,
}

-- EPalGenderType (objectdump 99662-99666)
local GENDER_MALE, GENDER_FEMALE = 1, 2

-- LastInsideRegionNameID row-key patterns (DT_WorldMapAreaData). The live
-- world reports the UNPREFIXED rows with mixed casing ("Grass_001",
-- "Desert_UndergroundCave_001", "Sakurajim_Mushroom"), the REGION_* rows
-- exist as well, so a condition matches when the lowercased region
-- CONTAINS any listed pattern. Side effect by design: a desert cave
-- counts as desert AND cave (conditions stay AND-able).
local REGION_PATTERNS = {
    inCave = { "undergroundcave", "fixeddungeon" },
    inDesert = { "desert" },
    inVolcano = { "volcano" },
    inSnow = { "frost" },
    inGrassland = { "grass" },
    inForest = { "forest" },
    inSakura = { "sakura" },
    inDarkIsland = { "darkisland" },
    onSkyIsland = { "skyisland" },
    onMushroomIsland = { "mushroom" },
    atWorldTree = { "footofworldtree" },
    onOilrig = { "oilrig" },
    inSanctuary = { "preserve" },
}

-- threshold tuning for the value-based conditions
local HP_FIXED_SCALE = 1000   -- FixedPoint64.Value per 1 HP
local HP_LOW_RATE = 0.3
local HP_FULL_RATE = 0.999
local HUNGRY_RATE = 0.3
local WELL_FED_RATE = 0.9
local TRUST_RANK_MIN = 5      -- GetFriendshipRank threshold
local RAIN_MIN = 0.05         -- WeatherFXSettings thresholds
local SNOW_MIN = 0.05
local FOG_MIN = 0.05

-- ---------------------------------------------------------------- ue helpers

local function palUtility()
    local u = StaticFindObject("/Script/Pal.Default__PalUtility")
    if u and u:IsValid() then return u end
    return nil
end

-- first valid world-context object available in the gate ctx
local function worldContextOf(ctx)
    if ctx.actor and ctx.actor:IsValid() then return ctx.actor end
    local pawn = ctx.playerCtx and ctx.playerCtx.pawn
    if pawn and pawn:IsValid() then return pawn end
    if ctx.holder and ctx.holder:IsValid() then return ctx.holder end
    return nil
end

local function playerPawn(ctx)
    local pawn = ctx.playerCtx and ctx.playerCtx.pawn
    if pawn and pawn:IsValid() then return pawn end
    return nil
end

-- UFunction-returned TArray: prefer ForEach, fall back to #/[] indexing.
-- Indexed access hands back RemoteUnrealParam wrappers, so unwrap with
-- :get() before passing the value on.
local function forEachInArray(arr, fn)
    if not arr then return end
    local ok = pcall(function()
        arr:ForEach(function(_, elem) fn(elem:get()) end)
    end)
    if ok then return end
    pcall(function()
        for i = 1, #arr do
            local v = arr[i]
            if type(v) == "userdata" then
                pcall(function() v = v:get() end)
            end
            fn(v)
        end
    end)
end

local function statusActive(ctx, statusId)
    local active = false
    pcall(function()
        local sc = ctx.actor.StatusComponent
        if not (sc and sc:IsValid()) then return end
        local s = sc:GetExecutionStatus(statusId)
        active = (s ~= nil) and s:IsValid()
    end)
    return active
end

-- the player's current region row key ("" when none/unavailable)
local function playerRegion(ctx)
    local region = ""
    pcall(function()
        local pawn = playerPawn(ctx)
        if pawn then region = pawn.LastInsideRegionNameID:ToString() end
    end)
    if region == "None" then return "" end
    return region
end

local function regionMatches(ctx, conditionId)
    local patterns = REGION_PATTERNS[conditionId]
    if not patterns then return false end
    local region = playerRegion(ctx):lower()
    if region == "" then return false end
    for _, pattern in ipairs(patterns) do
        if region:find(pattern, 1, true) then return true end
    end
    return false
end

local function isNightNow(ctx)
    local util = palUtility()
    local wc = worldContextOf(ctx)
    if not (util and wc) then error("no world context") end
    return util:IsNight(wc) == true
end

-- --------------------------------------------------------- boolean evaluators
-- Each returns true/false; thrown errors are treated as NOT met by evalOne.

local BOOL_EVAL = {}

BOOL_EVAL.day = function(ctx) return not isNightNow(ctx) end
BOOL_EVAL.night = function(ctx) return isNightNow(ctx) end

BOOL_EVAL.inWater = function(ctx)
    local mv = ctx.actor:GetPalCharacterMovementComponent()
    if not (mv and mv:IsValid()) then return false end
    local met = nil
    pcall(function() met = mv:IsEnteredWater() == true end)
    if met ~= nil then return met end
    -- fallbacks when IsEnteredWater is unavailable on this build
    pcall(function() met = mv:IsSwimming() == true end)
    if met == true then return true end
    local rate = 0
    pcall(function() rate = mv:GetInWaterRate() end)
    return rate > 0
end

BOOL_EVAL.burning = function(ctx) return statusActive(ctx, STATUS.Burn) end
BOOL_EVAL.electrified = function(ctx) return statusActive(ctx, STATUS.Electrical) end
BOOL_EVAL.frozen = function(ctx) return statusActive(ctx, STATUS.Freeze) end
BOOL_EVAL.wet = function(ctx) return statusActive(ctx, STATUS.Wetness) end
BOOL_EVAL.poisoned = function(ctx) return statusActive(ctx, STATUS.Poison) end
BOOL_EVAL.stunned = function(ctx) return statusActive(ctx, STATUS.Stun) end
BOOL_EVAL.sleeping = function(ctx) return statusActive(ctx, STATUS.Sleep) end
BOOL_EVAL.muddy = function(ctx) return statusActive(ctx, STATUS.Muddy) end
BOOL_EVAL.blinded = function(ctx) return statusActive(ctx, STATUS.Darkness) end
BOOL_EVAL.toxified = function(ctx)
    return statusActive(ctx, STATUS.ToxicGas) or statusActive(ctx, STATUS.ToxicGasFromAttack)
end

BOOL_EVAL.inCave = function(ctx)
    -- portal dungeons are stages; walk-in caves are region-tagged
    local met = false
    pcall(function()
        local ps = ctx.playerCtx and ctx.playerCtx.playerState
        if ps and ps:IsValid() then met = ps:IsInStateByStageType(STAGE_DUNGEON) == true end
    end)
    if met then return true end
    if regionMatches(ctx, "inCave") then return true end
    pcall(function()
        local util = palUtility()
        if util then met = util:IsInsideStage(ctx.actor) == true end
    end)
    return met
end

BOOL_EVAL.inDesert = function(ctx) return regionMatches(ctx, "inDesert") end
BOOL_EVAL.inVolcano = function(ctx) return regionMatches(ctx, "inVolcano") end
BOOL_EVAL.inSnow = function(ctx) return regionMatches(ctx, "inSnow") end
BOOL_EVAL.inGrassland = function(ctx) return regionMatches(ctx, "inGrassland") end
BOOL_EVAL.inForest = function(ctx) return regionMatches(ctx, "inForest") end
BOOL_EVAL.inSakura = function(ctx) return regionMatches(ctx, "inSakura") end
BOOL_EVAL.inDarkIsland = function(ctx) return regionMatches(ctx, "inDarkIsland") end
BOOL_EVAL.onSkyIsland = function(ctx) return regionMatches(ctx, "onSkyIsland") end
BOOL_EVAL.onMushroomIsland = function(ctx) return regionMatches(ctx, "onMushroomIsland") end
BOOL_EVAL.atWorldTree = function(ctx) return regionMatches(ctx, "atWorldTree") end
BOOL_EVAL.onOilrig = function(ctx) return regionMatches(ctx, "onOilrig") end

BOOL_EVAL.inSanctuary = function(ctx)
    local met = false
    pcall(function()
        local util = palUtility()
        local wc = worldContextOf(ctx)
        if not (util and wc) then return end
        local subsystem = util:GetWildlifeSanctuarySubsystem(wc)
        if not (subsystem and subsystem:IsValid()) then return end
        local loc = ctx.actor:K2_GetActorLocation()
        local area = subsystem:FindArea({ X = loc.X, Y = loc.Y, Z = loc.Z })
        met = (area ~= nil) and area:IsValid()
    end)
    if met then return true end
    return regionMatches(ctx, "inSanctuary")
end

BOOL_EVAL.isMale = function(ctx)
    local g = nil
    pcall(function() g = ctx.param:GetGenderType() end)
    return g == GENDER_MALE
end
BOOL_EVAL.isFemale = function(ctx)
    local g = nil
    pcall(function() g = ctx.param:GetGenderType() end)
    return g == GENDER_FEMALE
end

BOOL_EVAL.isGliding = function(ctx)
    local pawn = playerPawn(ctx)
    if not pawn then return false end
    local mv = pawn:GetPalCharacterMovementComponent()
    if not (mv and mv:IsValid()) then return false end
    local met = false
    pcall(function() met = mv:IsGliding() == true end)
    if met then return true end
    pcall(function() met = mv:IsJetpackGliding() == true end)
    return met
end

BOOL_EVAL.inOwnBase = function(ctx)
    local pawn = playerPawn(ctx)
    local util = palUtility()
    if not (pawn and util) then return false end
    local met = false
    pcall(function()
        local mgr = util:GetBaseCampManager(pawn)
        if not (mgr and mgr:IsValid()) then return end
        local loc = pawn:K2_GetActorLocation()
        local camp = mgr:GetInRangedBaseCamp({ X = loc.X, Y = loc.Y, Z = loc.Z }, 0.0)
        if not (camp and camp:IsValid()) then return end
        local campGroup = camp:GetGroupIdBelongTo()
        local playerGroup = pawn.CharacterParameterComponent:GetIndividualParameter():GetGroupId()
        met = campGroup.A == playerGroup.A and campGroup.B == playerGroup.B
            and campGroup.C == playerGroup.C and campGroup.D == playerGroup.D
    end)
    return met
end

BOOL_EVAL.inCombat = function(ctx)
    local pawn = playerPawn(ctx)
    local util = palUtility()
    if not (pawn and util) then return false end
    local bm = util:GetBattleManager(pawn)
    if not (bm and bm:IsValid()) then return false end
    local met = nil
    pcall(function()
        local out = {}
        met = bm:GetConflictEnemies(pawn, out, true) == true
    end)
    if met ~= nil then return met end
    -- out-param call unavailable: fall back to the global battle flag
    -- (exact in singleplayer; on a busy host it may over-report)
    pcall(function() met = bm:IsBattleModeAnyPlayer() == true end)
    return met == true
end

-- Conditions available to hand-written configs only; the web editor
-- does not offer them.

local function weatherFx(ctx)
    local sky = FindFirstOf("PalSkyCreator")
    if not (sky and sky:IsValid()) then error("no sky actor") end
    return sky.WeatherSettings.WeatherFXSettings, sky
end

BOOL_EVAL.raining = function(ctx)
    local fx = weatherFx(ctx)
    return fx.RainAmount > RAIN_MIN
end
BOOL_EVAL.snowing = function(ctx)
    local fx = weatherFx(ctx)
    return fx.SnowAmount > SNOW_MIN
end
BOOL_EVAL.thunderstorm = function(ctx)
    local fx = weatherFx(ctx)
    return fx.EnableLightnings == true
end
BOOL_EVAL.foggy = function(ctx)
    local _, sky = weatherFx(ctx)
    return sky.WeatherSettings.ExponentialHeightFogSettings.FogDensity > FOG_MIN
end

local function hpRate(ctx)
    local hp, maxHp = nil, nil
    pcall(function() hp = ctx.param:GetHP().Value end)
    pcall(function() maxHp = ctx.param:GetMaxHP() end)
    if not (hp and maxHp) or maxHp <= 0 then error("hp unavailable") end
    return hp / (maxHp * HP_FIXED_SCALE)
end

BOOL_EVAL.hpLow = function(ctx) return hpRate(ctx) <= HP_LOW_RATE end
BOOL_EVAL.hpFull = function(ctx) return hpRate(ctx) >= HP_FULL_RATE end

BOOL_EVAL.hungry = function(ctx)
    return ctx.param:GetFullStomachRate() <= HUNGRY_RATE
end
BOOL_EVAL.wellFed = function(ctx)
    return ctx.param:GetFullStomachRate() >= WELL_FED_RATE
end

BOOL_EVAL.highTrust = function(ctx)
    return ctx.param:GetFriendshipRank() >= TRUST_RANK_MIN
end

BOOL_EVAL.isRiding = function(ctx)
    local pc = ctx.playerCtx and ctx.playerCtx.pc
    if not (pc and pc:IsValid()) then return false end
    local riding = false
    pcall(function() riding = pc:IsRiding() == true end)
    if not riding then return false end
    -- bind to THIS pal when the rider lookup resolves; accept plain riding
    -- otherwise (the summoned otomo is the only own pal that can be out)
    local matches = nil
    pcall(function()
        local util = palUtility()
        local rider = util and util:FindRiderByRidingActor(ctx.actor) or nil
        local pawn = playerPawn(ctx)
        if rider and rider:IsValid() and pawn then
            matches = rider:GetFullName() == pawn:GetFullName()
        end
    end)
    if matches ~= nil then return matches end
    return true
end

-- ------------------------------------------------------ parameterized handlers

local PARAM_EVAL = {}

-- "knowsMove:<Element>": any mastered/equipped waza of the element
PARAM_EVAL.knowsMove = function(ctx, elementName)
    local elementValue = ELEMENTS[elementName]
    if not elementValue then return false end
    local util = palUtility()
    local wc = worldContextOf(ctx)
    if not (util and wc) then return false end
    local db = util:GetWazaDatabase(wc)
    if not (db and db:IsValid()) then return false end
    local found = false
    local function scan(list)
        forEachInArray(list, function(waza)
            if found then return end
            pcall(function()
                local out = {}
                if db:FindWazaForBP(waza, out) then
                    local elem = tonumber(out.Element) or out.Element
                    if elem == elementValue then found = true end
                end
            end)
        end)
    end
    pcall(function() scan(ctx.param:GetMasteredWaza()) end)
    if not found then
        pcall(function() scan(ctx.param:GetEquipWaza()) end)
    end
    return found
end

-- numeric parameterized conditions share one bounds table; isKnown()
-- validates integers against it so the web editor and hand-written
-- configs cannot smuggle nonsense thresholds past the sanitizer
local NUMERIC_PARAM_BOUNDS = {
    playerLevel = { min = 1, max = 80 },
    trustRank = { min = 1, max = 10 },
    ivTotal = { min = 1, max = 400 },
    ivEach = { min = 1, max = 100 },
}

-- "playerLevel:<n>": the TRAINER (player character) is at least level n
PARAM_EVAL.playerLevel = function(ctx, value)
    local need = tonumber(value)
    if not need then return false end
    local level = nil
    pcall(function()
        local pawn = playerPawn(ctx)
        if pawn then
            level = pawn.CharacterParameterComponent:GetIndividualParameter():GetLevel()
        end
    end)
    return (tonumber(level) or 0) >= need
end

-- "trustRank:<n>": the pal's friendship rank is at least n (scale 1..10;
-- the fixed highTrust condition keeps its threshold of 5)
PARAM_EVAL.trustRank = function(ctx, value)
    local need = tonumber(value)
    if not need then return false end
    local rank = nil
    pcall(function() rank = ctx.param:GetFriendshipRank() end)
    return (tonumber(rank) or 0) >= need
end

local IV_FIELDS = { "Talent_HP", "Talent_Melee", "Talent_Shot", "Talent_Defense" }

-- reads one talent; nil when unavailable so the callers stay fail closed
local function readIv(ctx, field)
    local v = nil
    pcall(function() v = tonumber(ctx.param.SaveParameter[field]) end)
    return v
end

-- "ivTotal:<n>": the four talents sum to at least n
PARAM_EVAL.ivTotal = function(ctx, value)
    local need = tonumber(value)
    if not need then return false end
    local total = 0
    for _, field in ipairs(IV_FIELDS) do
        local v = readIv(ctx, field)
        if v == nil then return false end
        total = total + v
    end
    return total >= need
end

-- "ivEach:<n>": every one of the four talents is at least n
PARAM_EVAL.ivEach = function(ctx, value)
    local need = tonumber(value)
    if not need then return false end
    for _, field in ipairs(IV_FIELDS) do
        local v = readIv(ctx, field)
        if v == nil or v < need then return false end
    end
    return true
end

-- "inParty:<CharacterID>": species in any otomo slot, spawned or in the ball;
-- an Alpha (BOSS_ prefixed) individual counts as its base species
PARAM_EVAL.inParty = function(ctx, characterId)
    if not (ctx.holder and ctx.holder:IsValid()) then return false end
    local found = false
    pcall(function()
        local n = ctx.holder:GetMaxOtomoNum()
        for i = 0, n - 1 do
            local handle = ctx.holder:GetOtomoIndividualHandle(i)
            if handle and handle:IsValid() then
                local p = handle:TryGetIndividualParameter()
                if p and p:IsValid() then
                    local id = p:GetCharacterID():ToString()
                    if id == characterId or id == ("BOSS_" .. characterId) then
                        found = true
                        return
                    end
                end
            end
        end
    end)
    return found
end

-- ------------------------------------------------------------------ vocabulary

-- Canonical id order for reasons and UI; must stay identical to the web
-- editor vocabulary in data/conditions.ts.
Conditions.ORDER = {
    "day", "night",
    "inWater",
    "burning", "electrified", "frozen", "wet", "poisoned", "stunned",
    "sleeping", "muddy", "blinded", "toxified",
    "inCave", "inDesert", "inVolcano", "inSnow", "inGrassland", "inForest",
    "inSakura", "inDarkIsland", "onSkyIsland", "onMushroomIsland",
    "atWorldTree", "onOilrig", "inSanctuary",
    "isMale", "isFemale",
    "hpLow", "hpFull", "hungry", "wellFed", "highTrust",
    "isGliding", "inOwnBase", "inCombat",
    -- available to hand-written configs only
    "raining", "snowing", "thunderstorm", "foggy", "isRiding",
}

Conditions.LABELS = {
    day = "Daytime", night = "Night",
    inWater = "In water",
    burning = "Burning", electrified = "Electrified", frozen = "Frozen",
    wet = "Wet", poisoned = "Poisoned", stunned = "Stunned",
    sleeping = "Sleeping", muddy = "Muddy", blinded = "Blinded",
    toxified = "In toxic gas",
    inCave = "In a cave", inDesert = "In the desert",
    inVolcano = "In the volcano region", inSnow = "In the snow region",
    inGrassland = "In grassland", inForest = "In the forest",
    inSakura = "In the sakura region", inDarkIsland = "On the dark island",
    onSkyIsland = "On a sky island", onMushroomIsland = "On the mushroom island",
    atWorldTree = "At the World Tree", onOilrig = "On the oil rig",
    inSanctuary = "In a wildlife sanctuary",
    isMale = "Male", isFemale = "Female",
    isGliding = "Gliding", inOwnBase = "In your own base", inCombat = "In combat",
    raining = "Raining", snowing = "Snowing", thunderstorm = "Thunderstorm",
    foggy = "Foggy",
    hpLow = "Low HP", hpFull = "Full HP",
    hungry = "Hungry", wellFed = "Well fed", highTrust = "High trust",
    isRiding = "Being ridden",
}

-- split a parameterized id; returns prefix, value or nil
local function splitParamId(id)
    local prefix, value = id:match("^(%w+):(.+)$")
    if prefix and PARAM_EVAL[prefix] then return prefix, value end
    return nil
end

-- localized pal display name for parameterized labels (falls back to the id)
local function palLabel(id)
    local name = nil
    pcall(function()
        local mdt = StaticFindObject("/Script/Pal.Default__PalMasterDataTablesUtility")
        local ctx = FindFirstOf("PalPlayerCharacter")
        if not (mdt and mdt:IsValid() and ctx and ctx:IsValid()) then return end
        -- EPalLocalizeTextCategory::PalMonsterName = 4
        local txt = mdt:GetLocalizedText(ctx, 4, FName("PAL_NAME_" .. id))
        if txt then
            local s = txt:ToString()
            if s and s ~= "" then name = s end
        end
    end)
    return name or id
end

-- human label for any id (used in blocked reasons and the config drop log)
function Conditions.label(id)
    local localized = I18n.condition(id)
    if localized then return localized end
    if Conditions.LABELS[id] then return Conditions.LABELS[id] end
    local prefix, value = splitParamId(id)
    if prefix == "knowsMove" then return I18n.msg("knowsMoveLabel", I18n.element(value)) end
    if prefix == "inParty" then return I18n.msg("inPartyLabel", palLabel(value)) end
    if prefix and NUMERIC_PARAM_BOUNDS[prefix] then
        return I18n.msg(prefix .. "Label", tonumber(value) or 0)
    end
    return id
end

-- is this id part of the vocabulary (including valid parameterized forms)?
local function isKnown(id)
    if BOOL_EVAL[id] then return true end
    local prefix, value = splitParamId(id)
    if prefix == "knowsMove" then return ELEMENTS[value] ~= nil end
    if prefix == "inParty" then return value:match("^[%w_]+$") ~= nil end
    local bounds = prefix and NUMERIC_PARAM_BOUNDS[prefix]
    if bounds then
        local n = tonumber(value)
        return n ~= nil and n == math.floor(n) and n >= bounds.min and n <= bounds.max
    end
    return false
end

-- ------------------------------------------------------------------ public API

-- Normalizes a raw conditions list from config_user.lua: keeps known ids
-- (deduped, order preserved), returns the dropped raw entries for logging.
function Conditions.sanitize(list)
    local clean, dropped, seen = {}, {}, {}
    if type(list) ~= "table" then return clean, dropped end
    for _, raw in ipairs(list) do
        local id = type(raw) == "string" and raw:match("^%s*(.-)%s*$") or nil
        if id and isKnown(id) then
            if not seen[id] then
                seen[id] = true
                table.insert(clean, id)
            end
        else
            table.insert(dropped, tostring(raw))
        end
    end
    return clean, dropped
end

-- evaluates one id; API errors and unknown ids count as NOT met (fail closed)
local function evalOne(id, ctx)
    local met = false
    local prefix, value = splitParamId(id)
    local ok, err = pcall(function()
        if prefix then
            met = PARAM_EVAL[prefix](ctx, value) == true
        elseif BOOL_EVAL[id] then
            met = BOOL_EVAL[id](ctx) == true
        end
    end)
    if not ok and devMode() then
        Log(string.format("[cond] %s eval error: %s", id, tostring(err)))
    end
    return met
end

-- Evaluates all conditions of a pair against ctx = { actor, param, playerCtx,
-- holder }. Returns true, or false plus a reason listing EVERY unmet condition
-- ("Night + In water").
function Conditions.evaluate(pair, ctx)
    local list = pair and pair.conditions
    if type(list) ~= "table" or #list == 0 then return true end
    local unmet = {}
    for _, id in ipairs(list) do
        if not evalOne(id, ctx) then
            table.insert(unmet, Conditions.label(id))
        end
    end
    if #unmet == 0 then return true end
    return false, table.concat(unmet, I18n.msg("andJoiner"))
end

-- "Night + In water" for a pair, nil when unconditional (UI/hint helper)
function Conditions.describe(pair)
    local list = pair and pair.conditions
    if type(list) ~= "table" or #list == 0 then return nil end
    local labels = {}
    for _, id in ipairs(list) do
        table.insert(labels, Conditions.label(id))
    end
    return table.concat(labels, I18n.msg("andJoiner"))
end

-- Prints every boolean condition and the key raw signals for a
-- gate-shaped ctx (marker [cond]).
function Conditions.debugDump(ctx)
    for _, id in ipairs(Conditions.ORDER) do
        if BOOL_EVAL[id] then
            Log(string.format("[cond] %-18s = %s", id, tostring(evalOne(id, ctx))))
        end
    end
    Log(string.format("[cond] raw region = %q", playerRegion(ctx)))
    pcall(function()
        local mv = ctx.actor:GetPalCharacterMovementComponent()
        Log(string.format("[cond] raw water: entered=%s swimming=%s rate=%.2f",
            tostring(mv:IsEnteredWater()), tostring(mv:IsSwimming()), mv:GetInWaterRate()))
    end)
    pcall(function()
        Log(string.format("[cond] raw hp: fixed=%d maxInt=%d rate=%.3f",
            ctx.param:GetHP().Value, ctx.param:GetMaxHP(), hpRate(ctx)))
    end)
    pcall(function()
        Log(string.format("[cond] raw pal: gender=%s stomachRate=%.2f trustRank=%s",
            tostring(ctx.param:GetGenderType()),
            ctx.param:GetFullStomachRate(),
            tostring(ctx.param:GetFriendshipRank())))
    end)
    pcall(function()
        local pawn = playerPawn(ctx)
        local level = pawn and pawn.CharacterParameterComponent:GetIndividualParameter():GetLevel()
        Log(string.format("[cond] raw player: level=%s", tostring(level)))
    end)
    pcall(function()
        local parts = {}
        for _, field in ipairs(IV_FIELDS) do
            table.insert(parts, string.format("%s=%s", field, tostring(readIv(ctx, field))))
        end
        Log("[cond] raw iv: " .. table.concat(parts, " "))
    end)
end

return Conditions
