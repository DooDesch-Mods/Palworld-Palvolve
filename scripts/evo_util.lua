-- Palvolve evolution helpers without state of their own: ownership, the otomo
-- holder, individual keys, Alpha ids and condition bookkeeping. Split out of
-- evolution.lua; every function here is used by more than one part of it.

local Conditions = require("conditions")
local Config = require("config")
local I18n = require("i18n")

local EvoUtil = {}

local MOD_NAME = "Palvolve"
local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- Absolute per-species capsule half-height, from the pal's static parameter
-- component (filled from the pal database at spawn). Readable on a HEADLESS
-- dedicated server, unlike GetSimpleCollisionHalfHeight / GetScaledCapsuleHalfHeight
-- which return a small BP default (~30) until a loaded mesh resizes the capsule -
-- with no mesh on a server, a big target species therefore sank into the ground.
-- Returns nil when unavailable so callers can fall back.
local function staticCapsuleHalf(actor)
    local h = nil
    pcall(function()
        local spc = actor.StaticCharacterParameterComponent
        if spc and spc:IsValid() then
            local v = spc.MeshCapsuleHalfHeight
            if v and v > 0 then h = v end
        end
    end)
    return h
end
local function palUtility()
    local u = StaticFindObject("/Script/Pal.Default__PalUtility")
    if u and u:IsValid() then return u end
    return nil
end
-- Ownership lives in the guid components (local host = ...-0001 in D),
-- so all four components must be checked.
local function isOwned(param)
    local owned = false
    pcall(function()
        local g = param.SaveParameter.OwnerPlayerUId
        owned = (g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0)
    end)
    return owned
end
-- Strict ownership against a specific player: multiplayer requests may only
-- touch pals owned by the requesting player. Falls back to the any-owner
-- check when no uid is available (playerCtx without a PlayerState yet).
local function isOwnedBy(param, playerUId)
    if not playerUId then return isOwned(param) end
    local owned = false
    pcall(function()
        local g = param.SaveParameter.OwnerPlayerUId
        owned = (g.A == playerUId.A and g.B == playerUId.B
            and g.C == playerUId.C and g.D == playerUId.D)
            and (g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0)
        if not owned and Config.devMode then
            Log(string.format("[ownership] pal owner %08X-%08X-%08X-%08X vs requester %08X-%08X-%08X-%08X",
                g.A, g.B, g.C, g.D, playerUId.A, playerUId.B, playerUId.C, playerUId.D))
        end
    end)
    return owned
end
local function guidString(g)
    return string.format("%08X-%08X-%08X-%08X", g.A, g.B, g.C, g.D)
end
-- An unset FGuid reads as all zeros. It is a table like any other, so a plain nil check
-- accepts it as an identity and it then matches no record at all.
local function isZeroGuid(g)
    return not g or (g.A == 0 and g.B == 0 and g.C == 0 and g.D == 0)
end
local function individualKey(param)
    local key = ""
    pcall(function() key = guidString(param.IndividualId.InstanceId) end)
    if key == "" then pcall(function() key = param:GetFullName() end) end
    return key
end
local function paramOf(palActor)
    local param = nil
    pcall(function()
        param = palActor.CharacterParameterComponent:GetIndividualParameter()
    end)
    if param and param:IsValid() then return param end
    return nil
end
-- Otomo holder of a SPECIFIC player (never FindFirstOf: on a host with
-- connected clients that would return an arbitrary player's holder).
--
-- The holder is a component of the player's CONTROLLER (its GetOwner()
-- is the PalPlayerController). The generic
-- component getter resolves it from a stable controller reference and works
-- for a REMOTE client on a dedicated server - unlike
-- PalUtility:GetOtomoHolderComponent, which takes only a WorldContextObject
-- and resolves via the local player / world context (null for remote
-- clients). Dump: AActor:GetComponentByClass (objectdump ...:511-513),
-- PalOtomoHolderComponentBase class (...:52602).
EvoUtil.otomoHolderClass = nil
local function findHolderFor(playerCtx, actor)
    -- primary: component of the player's own controller
    local holder = nil
    pcall(function()
        local pc = playerCtx and playerCtx.pc
        if pc and pc:IsValid() then
            if not (EvoUtil.otomoHolderClass and EvoUtil.otomoHolderClass:IsValid()) then
                EvoUtil.otomoHolderClass = StaticFindObject("/Script/Pal.PalOtomoHolderComponentBase")
            end
            if EvoUtil.otomoHolderClass then
                local h = pc:GetComponentByClass(EvoUtil.otomoHolderClass)
                if h and h:IsValid() then holder = h end
            end
        end
    end)
    if holder then return holder end
    -- fallbacks: by the summoned otomo, then the world-context util
    -- (the latter works for the local player on standalone/listen host)
    local util = palUtility()
    if not util then return nil end
    if actor then
        pcall(function()
            if actor:IsValid() then holder = util:GetOtomoHolderByOtomoPal(actor) end
        end)
        if holder and holder:IsValid() then return holder end
    end
    pcall(function()
        local pc = playerCtx and playerCtx.pc
        if pc and pc:IsValid() then holder = util:GetOtomoHolderComponent(pc) end
    end)
    if holder and holder:IsValid() then return holder end
    return nil
end
local function findManager(ctx)
    local mgr = nil
    pcall(function()
        local util = palUtility()
        if util then mgr = util:GetCharacterManager(ctx) end
    end)
    if mgr and mgr:IsValid() then return mgr end
    pcall(function() mgr = FindFirstOf("PalCharacterManager") end)
    if mgr and mgr:IsValid() then return mgr end
    return nil
end
-- Alpha pals keep a BOSS_ prefix on their CharacterID while the pair map
-- uses base ids: strip the prefix for matching and re-apply it on the swap
-- target so an Alpha stays an Alpha. Only species with a real BOSS_ row are
-- valid alpha targets - an id without a row cannot resolve its blueprint
-- class (spawn/summon failure risk). Lucky ("shiny") status lives in
-- SaveParameter.IsRarePal, which the in-place swap never touches.
local BOSS_PREFIX = "BOSS_"
EvoUtil.okBoss, EvoUtil.BossSet = pcall(require, "boss_static")
if not EvoUtil.okBoss then EvoUtil.BossSet = nil end
-- This is also the single point where a runtime id gets its spelling fixed.
-- The game reports a CharacterID as an FName, which compares case-insensitively
-- but hands back whichever spelling was registered first that session, while
-- every lookup below this point matches a string exactly. The prefix test runs
-- without case for the same reason: the game's own data spells one Alpha row
-- "Boss_Anubis" rather than "BOSS_Anubis".
local BOSS_PREFIX_LOWER = BOSS_PREFIX:lower()
local function baseCharacterId(rawId)
    if rawId:sub(1, #BOSS_PREFIX):lower() == BOSS_PREFIX_LOWER then
        return Config.canonicalId(rawId:sub(#BOSS_PREFIX + 1)), true
    end
    return Config.canonicalId(rawId), false
end
-- swap target for an alpha; nil when the species has no BOSS_ row
local function alphaTargetId(baseTo)
    if EvoUtil.BossSet and EvoUtil.BossSet[baseTo] then return BOSS_PREFIX .. baseTo end
    return nil
end
local function swapTargetId(pair, isAlpha)
    if not isAlpha then return pair.to end
    return alphaTargetId(pair.to)
end
-- Sanitization keeps known ids usable for diagnostics, but a dropped id means
-- this binary cannot prove the author's complete rule. The metadata never goes
-- on the wire; it only turns every local gate for that pair into fail-closed.
local function unknownConditionReason(pair)
    local metadata = pair and pair.conditionMetadata
    if metadata and metadata.hasUnknown then
        return I18n.msg("unknownConditionsBlocked")
    end
    return nil
end
local function conditionCount(pair)
    return type(pair and pair.conditions) == "table" and #pair.conditions or 0
end
local function controllerHasAuthority(pc)
    return pc:HasAuthority() == true
end
local function characterIdUnsafe(param)
    -- raw on purpose: every caller compares it through Config.canonicalId
    return param:GetCharacterID():ToString()
end
local function disclosedConditions(pair, exactText)
    if Config.conditionDisclosure == "exact" then return exactText end
    return Conditions.describe(pair, Config.conditionDisclosure) or exactText
end

EvoUtil.staticCapsuleHalf = staticCapsuleHalf
EvoUtil.palUtility = palUtility
EvoUtil.isOwned = isOwned
EvoUtil.isOwnedBy = isOwnedBy
EvoUtil.guidString = guidString
EvoUtil.isZeroGuid = isZeroGuid
EvoUtil.individualKey = individualKey
EvoUtil.paramOf = paramOf
EvoUtil.findHolderFor = findHolderFor
EvoUtil.findManager = findManager
EvoUtil.BOSS_PREFIX = BOSS_PREFIX
EvoUtil.BOSS_PREFIX_LOWER = BOSS_PREFIX_LOWER
EvoUtil.baseCharacterId = baseCharacterId
EvoUtil.alphaTargetId = alphaTargetId
EvoUtil.swapTargetId = swapTargetId
EvoUtil.unknownConditionReason = unknownConditionReason
EvoUtil.conditionCount = conditionCount
EvoUtil.controllerHasAuthority = controllerHasAuthority
EvoUtil.characterIdUnsafe = characterIdUnsafe
EvoUtil.disclosedConditions = disclosedConditions

return EvoUtil
