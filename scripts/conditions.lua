-- Palvolve conditions: optional per-pair environment/state requirements.
-- A pair's `conditions` field is an array of condition id strings. ALL ids of
-- a pair must hold at evolve time (AND). An either/or split is expressed as
-- two pairs with the same from/to and different conditions (the gates try
-- every same-target candidate). Parameterized ids use a colon:
--   "knowsMove:Dragon"  (EPalElementType name)
--   "knowsWaza:AirCanon" (EPalWazaID name, resolved to its numeric enum)
--   "hasItem:Money:1000" (read-only inventory threshold)
--   "inParty:Penguin"   (DT_PalMonsterParameter row name)
-- A leading "!" negates any id: "!night" (must not be night), "!trustRank:4"
-- (trust rank below 4). At most one "!"; "!!x" is unknown and dropped.
--
-- Evaluation is pull-based only: plain reads inside the existing game-thread
-- call frames of the gates. No hooks, no delegates, no timers.
-- A known condition whose game API fails evaluates as NOT met (fail closed):
-- a silently granted evolution would be an invisible correctness hole, a
-- greyed option with a reason is visible and debuggable. Negation only
-- inverts a CLEANLY returned boolean - an eval error or unknown id stays
-- unmet regardless of polarity, so "!" can never turn a failure into a met
-- condition.
--
-- This module must not require config.lua because config.lua requires this
-- module for its sanitizer.

local I18n = require("i18n")
local ConditionFeed = require("conditionfeed")
local WAZA_IDS = require("waza_static")

local Conditions = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
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
-- WeatherFXSettings thresholds, read off the sky plugin's own weather presets
-- (DT_PPSC_Weather_*). Every non-rain preset has RainAmount exactly 0 and the
-- weakest rain state is 0.2, so any small positive value separates them. Snow
-- needs a lower bar: the lightest snowfall state sits at 0.01.
local RAIN_MIN = 0.05
local SNOW_MIN = 0.005
-- Fog is only read together with a dry-sky check, see BOOL_EVAL.foggy. The bar
-- sits above the clear-sky band (a daylight preset reaches 0.08, a clear night
-- measured 0.06) and below the weakest fog state that is actually visible.
local FOG_MIN = 0.1

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

-- UFunction-returned TArray access. The indexed route avoids allocating a
-- callback closure for every condition evaluation, which matters once the
-- auto-evolve watcher calls this several times per second.
local function arrayLength(arr)
    return #arr
end

local function arrayValue(arr, index)
    return arr[index]
end

local function remoteValue(value)
    return value:get()
end

local function forEachInArray(arr, fn, state)
    if not arr then return false end
    local okLength, count = pcall(arrayLength, arr)
    if not okLength or type(count) ~= "number" then return false end
    for i = 1, count do
        local okValue, value = pcall(arrayValue, arr, i)
        if not okValue then return false end
        if type(value) == "userdata" then
            local okRemote, unwrapped = pcall(remoteValue, value)
            if not okRemote then return false end
            value = unwrapped
        end
        if fn(value, state) == false then return true end
    end
    return true
end

local function statusActiveUnsafe(ctx, statusId)
    local sc = ctx.actor.StatusComponent
    if not (sc and sc:IsValid()) then error("status component unavailable") end
    local status = sc:GetExecutionStatus(statusId)
    return status ~= nil and status:IsValid()
end

local function statusActive(ctx, statusId)
    local ok, active = pcall(statusActiveUnsafe, ctx, statusId)
    if ok then return active end
    return nil
end

-- the player's current region row key ("" when none, nil when unavailable)
local function playerRegionUnsafe(ctx)
    local pawn = playerPawn(ctx)
    if not pawn then error("player pawn unavailable") end
    return pawn.LastInsideRegionNameID:ToString()
end

local function playerRegion(ctx)
    local ok, region = pcall(playerRegionUnsafe, ctx)
    if not ok then return nil end
    if region == "None" then return "" end
    return region
end

local function regionMatches(ctx, conditionId)
    local patterns = REGION_PATTERNS[conditionId]
    if not patterns then return false end
    local rawRegion = playerRegion(ctx)
    if rawRegion == nil then return nil end
    local region = rawRegion:lower()
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

-- water state of one movement component; nil when unreadable
local function enteredWaterUnsafe(mv)
    return mv:IsEnteredWater() == true
end

local function swimmingUnsafe(mv)
    return mv:IsSwimming() == true
end

local function waterRateUnsafe(mv)
    return mv:GetInWaterRate()
end

local function waterState(mv)
    if not (mv and mv:IsValid()) then return nil end
    local okEntered, entered = pcall(enteredWaterUnsafe, mv)
    if okEntered then return entered end
    -- fallbacks when IsEnteredWater is unavailable on this build
    local okSwimming, swimming = pcall(swimmingUnsafe, mv)
    if okSwimming and swimming then return true end
    local okRate, rate = pcall(waterRateUnsafe, mv)
    if okRate and rate ~= nil then return rate > 0 end
    if okSwimming then return false end
    return nil
end

local function palMovementUnsafe(ctx)
    return ctx.actor:GetPalCharacterMovementComponent()
end

local function playerMovementUnsafe(ctx)
    local pawn = playerPawn(ctx)
    if not pawn then return nil end
    return pawn:GetPalCharacterMovementComponent()
end

BOOL_EVAL.inWater = function(ctx)
    -- The summoned pal counts first, but hovering/flying species (Suzaku,
    -- Ragnahawk, ...) never enter the swim state - they float above the
    -- surface. The PLAYER swimming counts too, which also matches the
    -- region conditions: those read the player's position already.
    --
    -- Not `okPal and waterState(...) or nil`: that idiom cannot carry false,
    -- because `x and false or nil` is nil in Lua. waterState returns a real
    -- false for "measured, and dry", so the shorthand turned every dry answer
    -- into "unknown" - and with both sides unknown this returns nil, which a
    -- negated condition never accepts. "!inWater" therefore passed nowhere,
    -- including on dry land.
    local palIn = nil
    local okPal, palMovement = pcall(palMovementUnsafe, ctx)
    if okPal then palIn = waterState(palMovement) end
    if palIn == true then return true end

    local playerIn = nil
    local okPlayer, playerMovement = pcall(playerMovementUnsafe, ctx)
    if okPlayer then playerIn = waterState(playerMovement) end
    if playerIn == true then return true end
    if palIn == nil and playerIn == nil then return nil end
    return false
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

local function dungeonStateUnsafe(ctx)
    local ps = ctx.playerCtx and ctx.playerCtx.playerState
    if not (ps and ps:IsValid()) then error("player state unavailable") end
    return ps:IsInStateByStageType(STAGE_DUNGEON) == true
end

local function insideStageUnsafe(ctx)
    local util = palUtility()
    if not util then error("pal utility unavailable") end
    return util:IsInsideStage(ctx.actor) == true
end

BOOL_EVAL.inCave = function(ctx)
    -- portal dungeons are stages; walk-in caves are region-tagged
    local okDungeon, dungeon = pcall(dungeonStateUnsafe, ctx)
    if okDungeon and dungeon then return true end
    local region = regionMatches(ctx, "inCave")
    if region then return true end
    local okStage, stage = pcall(insideStageUnsafe, ctx)
    if okStage and stage then return true end
    if not okDungeon and region == nil and not okStage then return nil end
    return false
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

local function sanctuaryUnsafe(ctx)
    local util = palUtility()
    local wc = worldContextOf(ctx)
    if not (util and wc) then error("world context unavailable") end
    local subsystem = util:GetWildlifeSanctuarySubsystem(wc)
    if not (subsystem and subsystem:IsValid()) then error("sanctuary subsystem unavailable") end
    local loc = ctx.actor:K2_GetActorLocation()
    local area = subsystem:FindArea({ X = loc.X, Y = loc.Y, Z = loc.Z })
    return area ~= nil and area:IsValid()
end

BOOL_EVAL.inSanctuary = function(ctx)
    local okArea, inArea = pcall(sanctuaryUnsafe, ctx)
    if okArea and inArea then return true end
    local region = regionMatches(ctx, "inSanctuary")
    if region ~= nil then return region end
    if not okArea then return nil end
    return false
end

local function genderUnsafe(ctx)
    return ctx.param:GetGenderType()
end

BOOL_EVAL.isMale = function(ctx)
    local ok, gender = pcall(genderUnsafe, ctx)
    if not ok then return nil end
    return gender == GENDER_MALE
end
BOOL_EVAL.isFemale = function(ctx)
    local ok, gender = pcall(genderUnsafe, ctx)
    if not ok then return nil end
    return gender == GENDER_FEMALE
end

local function glidingUnsafe(movement)
    return movement:IsGliding() == true
end

local function jetpackGlidingUnsafe(movement)
    return movement:IsJetpackGliding() == true
end

BOOL_EVAL.isGliding = function(ctx)
    local pawn = playerPawn(ctx)
    if not pawn then return nil end
    local mv = pawn:GetPalCharacterMovementComponent()
    if not (mv and mv:IsValid()) then return nil end
    local okGlide, gliding = pcall(glidingUnsafe, mv)
    if okGlide and gliding then return true end
    local okJetpack, jetpack = pcall(jetpackGlidingUnsafe, mv)
    if okJetpack then return jetpack end
    if okGlide then return false end
    return nil
end

local function ownBaseUnsafe(ctx, pawn, util)
    local mgr = util:GetBaseCampManager(pawn)
    if not (mgr and mgr:IsValid()) then error("base camp manager unavailable") end
    local loc = pawn:K2_GetActorLocation()
    local camp = mgr:GetInRangedBaseCamp({ X = loc.X, Y = loc.Y, Z = loc.Z }, 0.0)
    if not (camp and camp:IsValid()) then return false end
    local campGroup = camp:GetGroupIdBelongTo()
    local playerGroup = pawn.CharacterParameterComponent:GetIndividualParameter():GetGroupId()
    return campGroup.A == playerGroup.A and campGroup.B == playerGroup.B
        and campGroup.C == playerGroup.C and campGroup.D == playerGroup.D
end

BOOL_EVAL.inOwnBase = function(ctx)
    local pawn = playerPawn(ctx)
    local util = palUtility()
    if not (pawn and util) then return nil end
    local ok, met = pcall(ownBaseUnsafe, ctx, pawn, util)
    if ok then return met end
    return nil
end

local function conflictEnemiesUnsafe(battleManager, pawn)
    local out = {}
    return battleManager:GetConflictEnemies(pawn, out, true) == true
end

local function battleModeUnsafe(battleManager)
    return battleManager:IsBattleModeAnyPlayer() == true
end

BOOL_EVAL.inCombat = function(ctx)
    local pawn = playerPawn(ctx)
    local util = palUtility()
    if not (pawn and util) then return nil end
    local bm = util:GetBattleManager(pawn)
    if not (bm and bm:IsValid()) then return nil end
    local okConflict, conflict = pcall(conflictEnemiesUnsafe, bm, pawn)
    if okConflict then return conflict end
    -- out-param call unavailable: fall back to the global battle flag
    -- (exact in singleplayer; on a busy host it may over-report)
    local okBattle, battle = pcall(battleModeUnsafe, bm)
    if okBattle then return battle end
    return nil
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

-- Fog needs more than a density threshold, because density alone does not mean
-- fog: it climbs every night on a clear sky, a clear daylight preset sits at
-- 0.08, and heavy snow reaches 0.4. What separates real fog is that the density
-- is high AND the sky is otherwise dry. Measured against the sky plugin's own
-- presets, "above 0.1 with no rain and no snow" catches Fog_01 (0.4), Fog_03
-- (0.105) and Fog_04 (0.3) while excluding Snow_02 (0.4 with full snow),
-- Rain_03 (0.1 with rain) and every clear state. Fog_02 (0.01) is missed on
-- purpose: at that density there is nothing to see anyway.
BOOL_EVAL.foggy = function(ctx)
    local fx, sky = weatherFx(ctx)
    if fx.RainAmount > 0 or fx.SnowAmount > 0 then return false end
    return sky.WeatherSettings.ExponentialHeightFogSettings.FogDensity > FOG_MIN
end

local function hpUnsafe(ctx)
    return ctx.param:GetHP().Value
end

local function maxHpUnsafe(ctx)
    return ctx.param:GetMaxHP()
end

local function hpRate(ctx)
    local okHp, hp = pcall(hpUnsafe, ctx)
    local okMax, maxHp = pcall(maxHpUnsafe, ctx)
    if not (okHp and okMax) then error("hp unavailable") end
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

local function ridingUnsafe(pc)
    return pc:IsRiding() == true
end

local function riderMatchesUnsafe(ctx)
    local util = palUtility()
    local rider = util and util:FindRiderByRidingActor(ctx.actor) or nil
    local pawn = playerPawn(ctx)
    if rider and rider:IsValid() and pawn then
        return rider:GetFullName() == pawn:GetFullName()
    end
    return nil
end

BOOL_EVAL.isRiding = function(ctx)
    local pc = ctx.playerCtx and ctx.playerCtx.pc
    if not (pc and pc:IsValid()) then return nil end
    local okRiding, riding = pcall(ridingUnsafe, pc)
    if not okRiding then return nil end
    if not riding then return false end
    -- bind to THIS pal when the rider lookup resolves; accept plain riding
    -- otherwise (the summoned otomo is the only own pal that can be out)
    local okMatches, matches = pcall(riderMatchesUnsafe, ctx)
    if not okMatches then matches = nil end
    if matches ~= nil then return matches end
    return true
end

-- ------------------------------------------------------ parameterized handlers

local PARAM_EVAL = {}

local function getMasteredWaza(param)
    return param:GetMasteredWaza()
end

local function getEquipWaza(param)
    return param:GetEquipWaza()
end

local function findWazaElementUnsafe(waza, state)
    local out = {}
    if state.db:FindWazaForBP(waza, out) then
        local elem = tonumber(out.Element) or out.Element
        if elem == state.want then state.found = true end
    end
end

local function visitWazaElement(waza, state)
    if state.found then return false end
    pcall(findWazaElementUnsafe, waza, state)
    return not state.found
end

local function visitWazaId(waza, state)
    if (tonumber(waza) or waza) == state.want then
        state.found = true
        return false
    end
    return true
end

local function scanWazaLists(param, visitor, state)
    local readable = false
    local okMastered, mastered = pcall(getMasteredWaza, param)
    if okMastered and mastered then
        readable = forEachInArray(mastered, visitor, state) or readable
    end
    if state.found then return true end
    local okEquipped, equipped = pcall(getEquipWaza, param)
    if okEquipped and equipped then
        readable = forEachInArray(equipped, visitor, state) or readable
    end
    if not readable then return nil end
    return state.found
end

local function usableWazaId(wazaName)
    local wazaId = WAZA_IDS[wazaName]
    if type(wazaId) ~= "number" or wazaId <= 0 or wazaName == "MAX" then return nil end
    if wazaName:find("_PartnerSkill", 1, true) then return nil end
    return wazaId
end

-- "knowsMove:<Element>": any mastered/equipped waza of the element
PARAM_EVAL.knowsMove = function(ctx, elementName)
    local elementValue = ELEMENTS[elementName]
    if not elementValue then return false end
    local util = palUtility()
    local wc = worldContextOf(ctx)
    if not (util and wc) then return nil end
    local db = util:GetWazaDatabase(wc)
    if not (db and db:IsValid()) then return nil end
    return scanWazaLists(ctx.param, visitWazaElement, {
        db = db,
        want = elementValue,
        found = false,
    })
end

-- "knowsWaza:<EPalWazaID>": compare the numeric enum in both arrays. Passing
-- an FName or string to an enum slot silently becomes None, which can produce
-- a convincing false positive because None commonly already exists there.
PARAM_EVAL.knowsWaza = function(ctx, wazaName)
    local wazaId = usableWazaId(wazaName)
    if not wazaId then return false end
    return scanWazaLists(ctx.param, visitWazaId, {
        want = wazaId,
        found = false,
    })
end

-- numeric parameterized conditions share one bounds table; isKnown()
-- validates integers against it so the web editor and hand-written
-- configs cannot smuggle nonsense thresholds past the sanitizer
local NUMERIC_PARAM_BOUNDS = {
    playerLevel = { min = 1, max = 80 },
    trustRank = { min = 1, max = 10 },
    condenserRank = { min = 1, max = 4 },
    soulHP = { min = 1, max = 20 },
    soulAttack = { min = 1, max = 20 },
    soulDefense = { min = 1, max = 20 },
    soulCraftSpeed = { min = 1, max = 20 },
    ivTotal = { min = 1, max = 400 },
    ivEach = { min = 1, max = 100 },
    ivHP = { min = 1, max = 100 },
    ivMelee = { min = 1, max = 100 },
    ivShot = { min = 1, max = 100 },
    ivDefense = { min = 1, max = 100 },
}

local function fnameStringUnsafe(value)
    if type(value) == "string" then return value end
    if value and value.ToString then return value:ToString() end
    return tostring(value)
end

local function visitFName(value, state)
    local ok, name = pcall(fnameStringUnsafe, value)
    if ok and name == state.want then
        state.found = true
        return false
    end
    return true
end

local function passiveListUnsafe(param)
    return param.SaveParameter.PassiveSkillList
end

-- "hasPassive:<FName>": SaveParameter is the measured source of truth. The
-- mirror list can be empty while this one contains every real passive.
PARAM_EVAL.hasPassive = function(ctx, passiveId)
    local ok, list = pcall(passiveListUnsafe, ctx.param)
    if not ok or not list then return nil end
    local state = { want = passiveId, found = false }
    if not forEachInArray(list, visitFName, state) then return nil end
    return state.found
end

local function inventoryCountUnsafe(playerCtx, itemId)
    local pc = playerCtx and playerCtx.pc
    if not (pc and pc:IsValid()) then return nil end
    local inv = pc:GetPalPlayerState():GetInventoryData()
    if not (inv and inv:IsValid()) then return nil end
    return tonumber(inv:CountItemNum(FName(itemId)))
end

local function inventoryCount(playerCtx, itemId)
    local ok, count = pcall(inventoryCountUnsafe, playerCtx, itemId)
    if ok then return count end
    return nil
end

local function splitItemThreshold(value)
    local itemId, rawCount = value:match("^([%w_]+):(%d+)$")
    local count = tonumber(rawCount)
    if not itemId or not count then return nil, nil end
    return itemId, count
end

-- "hasItem:<StaticItemId>:<n>": inventory count only. Money is an ordinary
-- static item id here, and this path never calls a consume function.
PARAM_EVAL.hasItem = function(ctx, value)
    local itemId, need = splitItemThreshold(value)
    if not itemId or need < 1 then return false end
    local count = inventoryCount(ctx.playerCtx, itemId)
    if count == nil then return nil end
    return count >= need
end

-- "fedFood:<StaticItemId>": the tracker records only confirmed stack and
-- fullness changes from the two real party feeding paths.
PARAM_EVAL.fedFood = function(ctx, itemId)
    local lastFood, readable = ConditionFeed.lastFood(ctx.param)
    if not readable then return nil end
    return lastFood == itemId
end

-- "playerLevel:<n>": the TRAINER (player character) is at least level n
local function playerLevelUnsafe(ctx)
    local pawn = playerPawn(ctx)
    if not pawn then error("player pawn unavailable") end
    return pawn.CharacterParameterComponent:GetIndividualParameter():GetLevel()
end

PARAM_EVAL.playerLevel = function(ctx, value)
    local need = tonumber(value)
    if not need then return false end
    local ok, level = pcall(playerLevelUnsafe, ctx)
    if not ok or level == nil then return nil end
    return (tonumber(level) or 0) >= need
end

-- "trustRank:<n>": the pal's friendship rank is at least n (scale 1..10;
-- the fixed highTrust condition keeps its threshold of 5)
local function trustRankUnsafe(ctx)
    return ctx.param:GetFriendshipRank()
end

PARAM_EVAL.trustRank = function(ctx, value)
    local need = tonumber(value)
    if not need then return false end
    local ok, rank = pcall(trustRankUnsafe, ctx)
    if not ok or rank == nil then return nil end
    return (tonumber(rank) or 0) >= need
end

local function readSaveNumberUnsafe(ctx, field)
    return tonumber(ctx.param.SaveParameter[field])
end

local function readSaveNumber(ctx, field)
    local ok, value = pcall(readSaveNumberUnsafe, ctx, field)
    if ok then return value end
    return nil
end

local function saveRankEval(field)
    return function(ctx, value)
        local need = tonumber(value)
        if not need then return false end
        local rank = readSaveNumber(ctx, field)
        if rank == nil then return nil end
        return rank >= need
    end
end

-- The condenser ceiling is game data rather than a magic threshold. The
-- sanitizer uses this build's measured ceiling; evaluation also refuses a
-- threshold above the live setting when it can be read.
local function condenserRankEval(ctx, value)
    local need = tonumber(value)
    if not need then return false end
    local setting = StaticFindObject("/Script/Pal.Default__PalGameSetting")
    if not (setting and setting:IsValid()) then return nil end
    local ceiling = tonumber(setting.CharacterMaxRank)
    if not ceiling then return nil end
    if need > ceiling then return false end
    local rank = readSaveNumber(ctx, "Rank")
    if rank == nil then return nil end
    return rank >= need
end

PARAM_EVAL.condenserRank = condenserRankEval
PARAM_EVAL.soulHP = saveRankEval("Rank_HP")
PARAM_EVAL.soulAttack = saveRankEval("Rank_Attack")
PARAM_EVAL.soulDefense = saveRankEval("Rank_Defence")
PARAM_EVAL.soulCraftSpeed = saveRankEval("Rank_CraftSpeed")

local IV_FIELDS = { "Talent_HP", "Talent_Melee", "Talent_Shot", "Talent_Defense" }

-- reads one talent; nil when unavailable so the callers stay fail closed
local function readIvUnsafe(ctx, field)
    return tonumber(ctx.param.SaveParameter[field])
end

local function readIv(ctx, field)
    local ok, value = pcall(readIvUnsafe, ctx, field)
    if ok then return value end
    return nil
end

-- "ivTotal:<n>": the four talents sum to at least n
PARAM_EVAL.ivTotal = function(ctx, value)
    local need = tonumber(value)
    if not need then return false end
    local total = 0
    for _, field in ipairs(IV_FIELDS) do
        local v = readIv(ctx, field)
        if v == nil then return nil end
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
        if v == nil then return nil end
        if v < need then return false end
    end
    return true
end

-- "ivHP:<n>" / "ivMelee:<n>" / "ivShot:<n>" / "ivDefense:<n>": that one talent
-- is at least n (fail closed when the talent cannot be read)
local function ivStatEval(field)
    return function(ctx, value)
        local need = tonumber(value)
        if not need then return false end
        local v = readIv(ctx, field)
        if v == nil then return nil end
        return v >= need
    end
end
PARAM_EVAL.ivHP = ivStatEval("Talent_HP")
PARAM_EVAL.ivMelee = ivStatEval("Talent_Melee")
PARAM_EVAL.ivShot = ivStatEval("Talent_Shot")
PARAM_EVAL.ivDefense = ivStatEval("Talent_Defense")

-- "inParty:<CharacterID>": species in any otomo slot, spawned or in the ball;
-- an Alpha (BOSS_ prefixed) individual counts as its base species
local function inPartyUnsafe(ctx, characterId)
    -- The game hands a CharacterID back in whichever case the session
    -- registered first, so both sides go to lower case before they meet.
    -- The rest of the mod runs ids through Config.canonicalId instead;
    -- this module cannot, because config.lua requires it (see the header).
    local want = characterId:lower()
    local n = ctx.holder:GetMaxOtomoNum()
    for i = 0, n - 1 do
        local handle = ctx.holder:GetOtomoIndividualHandle(i)
        if handle and handle:IsValid() then
            local param = handle:TryGetIndividualParameter()
            if param and param:IsValid() then
                local id = param:GetCharacterID():ToString():lower()
                if id == want or id == ("boss_" .. want) then return true end
            end
        end
    end
    return false
end

PARAM_EVAL.inParty = function(ctx, characterId)
    if not (ctx.holder and ctx.holder:IsValid()) then return nil end
    local ok, found = pcall(inPartyUnsafe, ctx, characterId)
    if ok then return found end
    return nil
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
    "raining", "snowing", "thunderstorm", "foggy",
    -- available to hand-written configs only
    "isRiding",
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

-- polarity split: "!night" -> true, "night"; anything else -> false, id
local function splitNegation(id)
    if type(id) == "string" and id:sub(1, 1) == "!" then
        return true, id:sub(2)
    end
    return false, id
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


local function localizedSkillTextUnsafe(textId)
    local mdt = StaticFindObject("/Script/Pal.Default__PalMasterDataTablesUtility")
    local ctx = FindFirstOf("PalPlayerCharacter")
    if not (mdt and mdt:IsValid() and ctx and ctx:IsValid()) then return nil end
    -- EPalLocalizeTextCategory::SkillName = 16
    local txt = mdt:GetLocalizedText(ctx, 16, FName(textId))
    if not txt then return nil end
    local value = txt:ToString()
    if value and value ~= "" and value ~= textId then return value end
    return nil
end

local function skillLabel(id, textPrefix)
    local textId = textPrefix .. id
    local ok, name = pcall(localizedSkillTextUnsafe, textId)
    if ok and name then return name end
    return id
end

local function localizedMessage(key, fallback, ...)
    local value = I18n.msg(key, ...)
    if value ~= key then return value end
    local ok, result = pcall(string.format, fallback, ...)
    return ok and result or fallback
end

local NUMERIC_LABEL_FALLBACKS = {
    condenserRank = "Condenser rank %d+",
    soulHP = "HP Soul rank %d+",
    soulAttack = "Attack Soul rank %d+",
    soulDefense = "Defense Soul rank %d+",
    soulCraftSpeed = "Craft Speed Soul rank %d+",
}

local NUMERIC_UNDER_FALLBACKS = {
    condenserRank = "Condenser rank below %d",
    soulHP = "HP Soul rank below %d",
    soulAttack = "Attack Soul rank below %d",
    soulDefense = "Defense Soul rank below %d",
    soulCraftSpeed = "Craft Speed Soul rank below %d",
}

-- human label for a positive (base) id
local function positiveLabel(id)
    local localized = I18n.condition(id)
    if localized then return localized end
    if Conditions.LABELS[id] then return Conditions.LABELS[id] end
    local prefix, value = splitParamId(id)
    if prefix == "knowsMove" then return I18n.msg("knowsMoveLabel", I18n.element(value)) end
    if prefix == "knowsWaza" then
        return localizedMessage("knowsWazaLabel", "Knows %s",
            skillLabel(value, "ACTION_SKILL_"))
    end
    if prefix == "hasPassive" then
        return localizedMessage("hasPassiveLabel", "Has passive %s",
            skillLabel(value, "PASSIVE_"))
    end
    if prefix == "hasItem" then
        local itemId, count = splitItemThreshold(value)
        local itemName = I18n.itemName(itemId or value, itemId or value)
        return localizedMessage("hasItemLabel", "Has %d %s", count or 0, itemName)
    end
    if prefix == "fedFood" then
        local itemName = I18n.itemName(value, value)
        return localizedMessage("fedFoodLabel", "Last ate %s", itemName)
    end
    if prefix == "inParty" then return I18n.msg("inPartyLabel", palLabel(value)) end
    if prefix and NUMERIC_PARAM_BOUNDS[prefix] then
        local fallback = NUMERIC_LABEL_FALLBACKS[prefix]
        if fallback then
            return localizedMessage(prefix .. "Label", fallback, tonumber(value) or 0)
        end
        return I18n.msg(prefix .. "Label", tonumber(value) or 0)
    end
    return id
end

-- Human label for any id (used in blocked reasons and the config drop log).
-- Negated numerics state the complementary requirement ("Trust rank < 4")
-- instead of wrapping the "%d+" form in "not"; other negated ids wrap their
-- positive label in the notLabel template ("not Night").
function Conditions.label(id)
    local negated, base = splitNegation(id)
    if not negated then return positiveLabel(base) end
    local prefix, value = splitParamId(base)
    if prefix and NUMERIC_PARAM_BOUNDS[prefix] then
        local fallback = NUMERIC_UNDER_FALLBACKS[prefix]
        if fallback then
            return localizedMessage(prefix .. "UnderLabel", fallback, tonumber(value) or 0)
        end
        return I18n.msg(prefix .. "UnderLabel", tonumber(value) or 0)
    end
    return I18n.msg("notLabel", positiveLabel(base))
end

-- is this base id part of the vocabulary (including valid parameterized forms)?
local function isKnownBase(id)
    if BOOL_EVAL[id] then return true end
    local prefix, value = splitParamId(id)
    if prefix == "knowsMove" then return ELEMENTS[value] ~= nil end
    if prefix == "knowsWaza" then
        return usableWazaId(value) ~= nil
    end
    if prefix == "hasPassive" then
        return value ~= "None" and value:match("^[%w_]+$") ~= nil
    end
    if prefix == "hasItem" then
        local itemId, count = splitItemThreshold(value)
        return itemId ~= nil and itemId ~= "None" and count >= 1
            and count <= 9007199254740991
    end
    if prefix == "fedFood" then
        return value ~= "None" and value:match("^[%w_]+$") ~= nil
    end
    if prefix == "inParty" then return value:match("^[%w_]+$") ~= nil end
    local bounds = prefix and NUMERIC_PARAM_BOUNDS[prefix]
    if bounds then
        local n = tonumber(value)
        return n ~= nil and n == math.floor(n) and n >= bounds.min and n <= bounds.max
    end
    return false
end

-- vocabulary check for either polarity ("!!x" and a bare "!" stay unknown)
local function isKnown(id)
    local negated, base = splitNegation(id)
    if negated and (base == "" or base:sub(1, 1) == "!") then return false end
    return isKnownBase(base)
end

-- ------------------------------------------------------------------ public API

-- Called from Evolution.init so the native feeding hook is installed and the
-- Blueprint hook can begin its world-safe two-poll registration.
function Conditions.init()
    ConditionFeed.init()
end

local function sanitizeMetadata(dropped)
    return {
        hasUnknown = #dropped > 0,
        unknownIds = dropped,
    }
end

-- Normalizes a raw conditions list from config_user.lua: keeps known ids
-- (deduped, order preserved). The legacy second return stays the dropped
-- array; the third makes the fail-closed handoff explicit for config.lua.
function Conditions.sanitize(list)
    local clean, dropped, seen = {}, {}, {}
    if type(list) ~= "table" then return clean, dropped, sanitizeMetadata(dropped) end
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
    return clean, dropped, sanitizeMetadata(dropped)
end

-- Evaluates one id; API errors and unknown ids count as NOT met (fail
-- closed) REGARDLESS of polarity - "!" only inverts a clean boolean result,
-- so an eval failure can never satisfy a negated condition. A refusal caused
-- by an evaluation failure is always warned about, independent of devMode.
local function evalOne(id, ctx)
    local negated, base = splitNegation(id)
    local prefix, value = splitParamId(base)
    local evaluator = prefix and PARAM_EVAL[prefix] or BOOL_EVAL[base]
    if not evaluator then
        Log(string.format("[WARN] condition %s could not be evaluated: no evaluator", tostring(id)))
        return false
    end
    local ok, result = pcall(evaluator, ctx, value)
    if not ok then
        Log(string.format("[WARN] condition %s could not be evaluated: %s",
            tostring(id), tostring(result)))
        return false
    end
    if type(result) ~= "boolean" then
        Log(string.format("[WARN] condition %s could not be evaluated: evaluator returned %s",
            tostring(id), type(result)))
        return false
    end
    local met = result == true
    if negated then return not met end
    return met
end

-- Hot-path count for the auto-evolve watcher. It deliberately does no label
-- lookup, localization, concatenation, or unmet-list allocation.
function Conditions.progress(pair, ctx)
    local list = pair and pair.conditions
    if type(list) ~= "table" or #list == 0 then return 0, 0 end
    local met = 0
    for _, id in ipairs(list) do
        if evalOne(id, ctx) then met = met + 1 end
    end
    return met, #list
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

local function disclosedLabel(id, level)
    if level == "exact" then return Conditions.label(id) end
    local resolver = I18n.conditionDescription
    if type(resolver) == "function" then
        local ok, label = pcall(resolver, id, level)
        if ok and type(label) == "string" and label ~= "" then return label end
    end
    -- Missing disclosure data must hide detail, never leak the exact label.
    return "???"
end

-- Disclosure-aware pair description. Exact remains the default for old
-- callers. Hint and hidden are resolved through i18n data; duplicate group
-- hints collapse naturally, so adding the third level stays a catalog change.
function Conditions.describe(pair, level)
    local list = pair and pair.conditions
    if type(list) ~= "table" or #list == 0 then return nil end
    if level ~= "partial" and level ~= "hidden" then level = "exact" end
    local labels, seen = {}, {}
    for _, id in ipairs(list) do
        local label = disclosedLabel(id, level)
        if not seen[label] then
            seen[label] = true
            table.insert(labels, label)
        end
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
