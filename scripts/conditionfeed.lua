-- Palvolve feeding condition tracker. The game keeps no durable "last food"
-- field on an individual, so this module records successful party-bag and
-- hand-feeding consumption by stable individual id for the current session.
-- An attempted feed is never enough: both the source stack and fullness must
-- move before the food becomes condition truth.

local Role = require("role")
local ConditionFeed = {}

local PARTY_MEAL_FN =
    "/Script/Pal.PalIndividualCharacterParameter:PartyPalMealInventoryFood"
local HAND_FEED_FN =
    "/Game/Pal/Blueprint/Action/Palmi/Pair/BP_ActionPairBehavior_FeedItem.BP_ActionPairBehavior_FeedItem_C:OnBeginAction"

local lastFoodByIndividual = {}
local pendingParty = {}
local pendingHand = {}
local hooksArmed = false
local nativeHookRegistered = false
local blueprintHookRegistered = false
local pollStarted = false
local stablePlayerPolls = 0
local registrationFailures = 0
local MAX_REGISTRATION_FAILURES = 12
local ARM_POLL_MS = 5000
local ARM_STABLE_POLLS = 2

--- The party-bag half of the tracker is off, and the reason is a crash, not a
--- preference.
---
--- A listen host dies with an access violation on 0xffffffffffffffff while a
--- singleplayer world loads, and the only thing that reliably decides it is
--- whether PartyPalMealInventoryFood carries this module's hook: registered, the
--- process dies partway through the restore; not registered, the world finishes.
--- A dedicated server never registers it and a remote client never runs the
--- authoritative feeding, which is why only singleplayer showed it.
---
--- Two guesses at the mechanism did not hold. Rejecting an unresolved owner uid
--- changed nothing. Passing a real WorldContextObject to
--- GetInventoryDataByPlayerUID and GetItemContainerManager - which the header at
--- Pal.hpp:38031 and Pal.hpp:38027 does ask for, and which this file used to get
--- wrong - bought 1.4 seconds and 22 more restored pals, then died anyway. So
--- the wrong context was real and was not the whole story. What kills it is
--- still unknown, which is exactly why the hook stays off rather than guarded
--- again: a pcall cannot catch a native access violation, so a wrong guess here
--- costs the player their world, not a log line.
---
--- The cost of leaving it off is nothing, because this half never worked. The
--- container lookup read inv.InventoryInfo, and the member is MyInventoryInfo
--- (Pal.hpp:31774). An unknown reflected member yields an invalid wrapper, the
--- enclosing pcall swallowed it, and pendingParty was therefore never filled:
--- party-bag eating has never once marked fedFood. Hand feeding does, through
--- the Blueprint hook below, which survived every run that this one killed.
---
--- Before turning it back on, run the probe that separates our code from the
--- framework: register this same hook with two named no-op callbacks and load a
--- singleplayer world. If that still dies, the fault is in UE4SS hook dispatch,
--- not in anything guarding can reach - this build is c838a8ac, whose LoopAsync
--- runs Lua on a worker thread against the same lua_State the hook dispatch uses
--- (UE4SS issues #1345 and #1372).
local PARTY_HOOK_ENABLED = false

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local function objectIsValidUnsafe(obj)
    return obj ~= nil and obj:IsValid() == true
end

local function objectIsValid(obj)
    local ok, valid = pcall(objectIsValidUnsafe, obj)
    return ok and valid == true
end

local function unwrapUnsafe(value)
    if type(value) == "userdata" and value.get then return value:get() end
    return value
end

local function unwrap(value)
    local ok, result = pcall(unwrapUnsafe, value)
    if ok then return result end
    return nil
end

local function individualKeyUnsafe(param)
    local g = param.IndividualId.InstanceId
    return string.format("%08X-%08X-%08X-%08X", g.A, g.B, g.C, g.D)
end

local function individualKey(param)
    if not objectIsValid(param) then return nil end
    local ok, key = pcall(individualKeyUnsafe, param)
    if not ok or key == "00000000-00000000-00000000-00000000" then return nil end
    return key
end

local function fullnessUnsafe(param)
    return tonumber(param:GetFullStomachRate())
end

local function fullness(param)
    if not objectIsValid(param) then return nil end
    local ok, value = pcall(fullnessUnsafe, param)
    if ok then return value end
    return nil
end

local function palUtilityUnsafe()
    return StaticFindObject("/Script/Pal.Default__PalUtility")
end

local function palUtility()
    local ok, util = pcall(palUtilityUnsafe)
    if ok and objectIsValid(util) then return util end
    return nil
end

local function playerUtilityUnsafe()
    return StaticFindObject("/Script/Pal.Default__PalPlayerUtility")
end

local function playerUtility()
    local ok, util = pcall(playerUtilityUnsafe)
    if ok and objectIsValid(util) then return util end
    return nil
end

--- True once the owner uid is a real guid rather than a zeroed one.
---
--- A pal whose owner has not resolved yet carries all-zero. Handing that to
--- GetInventoryDataByPlayerUID is the call this file already documents as fatal:
--- it dies reading 0xffffffffffffffff, and the pcall around it catches nothing,
--- because a native access violation is not a Lua error.
---
--- The join case was known. The one that was not: a LISTEN HOST builds its own
--- local player while the world streams in, so every singleplayer load walks
--- through the same unresolved window - and a listen host is the only role that
--- both registers this hook and owns the authoritative party feeding, which is
--- why a dedicated server and a remote client never showed it.
local function ownerResolved(param)
    local ok, resolved = pcall(function()
        local g = param.SaveParameter.OwnerPlayerUId
        return g ~= nil and (g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0)
    end)
    return ok and resolved == true
end

--- A live object that can resolve a world, cached but never trusted.
---
--- Both utility calls below take a WorldContextObject:
---   Pal.hpp:38031  GetInventoryDataByPlayerUID(const UObject* WorldContextObject, FGuid)
---   Pal.hpp:38027  GetItemContainerManager(const UObject* WorldContextObject)
---
--- This file used to hand them the individual parameter itself. That is a plain
--- UObject whose outer chain does not reach a world, so the engine resolved a
--- null world and dereferenced it, dying on 0xffffffffffffffff. The hand-feeding
--- path never crashed because it passes the action object, which does resolve.
---
--- The handle is revalidated on every use rather than kept, because a pointer
--- that was good last tick says nothing about this one, and a pcall does not
--- catch an access violation through a dead UObject.
local worldContext = nil

local function worldContextUnsafe()
    if objectIsValidUnsafe(worldContext) then return worldContext end
    worldContext = FindFirstOf("PalPlayerCharacter")
    if objectIsValidUnsafe(worldContext) then return worldContext end
    worldContext = nil
    return nil
end

local function foodContainerUnsafe(param, util)
    if not ownerResolved(param) then return nil end
    local context = worldContextUnsafe()
    if context == nil then return nil end
    local owner = param.SaveParameter.OwnerPlayerUId
    local inv = util:GetInventoryDataByPlayerUID(context, owner)
    if not objectIsValidUnsafe(inv) then return nil end
    local manager = util:GetItemContainerManager(context)
    if not objectIsValidUnsafe(manager) then return nil end
    -- MyInventoryInfo, not InventoryInfo: Pal.hpp:31774 declares the member at
    -- offset 0x100 under that name, and uninstall.lua:249 already reads it
    -- correctly. Unreachable while PARTY_HOOK_ENABLED is false, and corrected
    -- so that a future attempt starts from working code rather than this.
    return manager:GetContainer(inv.MyInventoryInfo.FoodEquipContainerId)
end

local function foodContainer(param)
    local util = palUtility()
    if not util then return nil end
    local ok, container = pcall(foodContainerUnsafe, param, util)
    if ok and objectIsValid(container) then return container end
    return nil
end

local function slotStateUnsafe(slot)
    local itemId = slot:GetItemId().StaticId:ToString()
    return itemId, tonumber(slot:GetStackCount())
end

local function slotState(slot)
    if not objectIsValid(slot) then return nil, nil end
    local ok, itemId, count = pcall(slotStateUnsafe, slot)
    if not ok or type(itemId) ~= "string" or itemId == "" or itemId == "None" then
        return nil, nil
    end
    return itemId, count
end

local function containerSnapshotUnsafe(container)
    local snapshot = {}
    local count = container:Num()
    for index = 0, count - 1 do
        local slot = container:Get(index)
        if objectIsValidUnsafe(slot) then
            local itemId, stack = slotStateUnsafe(slot)
            if itemId and itemId ~= "" and itemId ~= "None" and stack then
                snapshot[index] = { id = itemId, count = stack }
            end
        end
    end
    return snapshot
end

local function containerSnapshot(container)
    if not objectIsValid(container) then return nil end
    local ok, snapshot = pcall(containerSnapshotUnsafe, container)
    if ok then return snapshot end
    return nil
end

local function consumedFromSnapshotUnsafe(container, before)
    local consumed = nil
    for index, old in pairs(before) do
        local slot = container:Get(index)
        local afterId, afterCount = nil, 0
        if objectIsValidUnsafe(slot) then
            afterId, afterCount = slotStateUnsafe(slot)
        end
        if (afterId ~= old.id or (tonumber(afterCount) or 0) < old.count) then
            if consumed ~= nil then return nil end
            consumed = old.id
        end
    end
    return consumed
end

local function consumedFromSnapshot(container, before)
    if not objectIsValid(container) or type(before) ~= "table" then return nil end
    local ok, itemId = pcall(consumedFromSnapshotUnsafe, container, before)
    if ok then return itemId end
    return nil
end

local function remember(key, itemId)
    if type(key) ~= "string" or key == "" then return end
    if type(itemId) ~= "string" or itemId == "" or itemId == "None" then return end
    lastFoodByIndividual[key] = itemId
end

local function hookSelf(value)
    local self = unwrap(value)
    if objectIsValid(self) then return self end
    return nil
end

local function capturePartyUnsafe(hookParam)
    local param = hookSelf(hookParam)
    if not param then return end
    local key = individualKey(param)
    local beforeFullness = fullness(param)
    local container = foodContainer(param)
    local beforeSlots = containerSnapshot(container)
    if not (key and beforeFullness and container and beforeSlots) then return end
    pendingParty[key] = {
        fullness = beforeFullness,
        slots = beforeSlots,
    }
end

local function confirmPartyUnsafe(hookParam)
    local param = hookSelf(hookParam)
    if not param then return end
    local key = individualKey(param)
    local pending = key and pendingParty[key] or nil
    if not pending then return end
    pendingParty[key] = nil
    local afterFullness = fullness(param)
    if not afterFullness or afterFullness <= pending.fullness then return end
    local itemId = consumedFromSnapshot(foodContainer(param), pending.slots)
    if itemId then remember(key, itemId) end
end

local function onPartyPre(self)
    if not hooksArmed then return end
    pcall(capturePartyUnsafe, self)
end

local function onPartyPost(self)
    if not hooksArmed then return end
    pcall(confirmPartyUnsafe, self)
end

local function targetParamUnsafe(action, util)
    local target = action:GetActionTarget()
    if not objectIsValidUnsafe(target) then return nil end
    return util:GetIndividualCharacterParameterByActor(target)
end

local function readFeedSlotUnsafe(action, playerUtil, util)
    local blackboard = action:GetBlackboard()
    local outSlot = {}
    local returnedSlot, returnedNum = playerUtil:ReadPlayerFeedItemTo(blackboard, outSlot, 0)
    local slotId = outSlot
    if type(returnedSlot) == "table" or type(returnedSlot) == "userdata" then
        slotId = returnedSlot
    end
    local slotIndex = tonumber(slotId.SlotIndex)
    if slotIndex == nil then return nil end
    local manager = util:GetItemContainerManager(action)
    if not objectIsValidUnsafe(manager) then return nil end
    local container = manager:GetContainer(slotId.ContainerId)
    if not objectIsValidUnsafe(container) then return nil end
    local slot = container:Get(slotIndex)
    if not objectIsValidUnsafe(slot) then return nil end
    local itemId, count = slotStateUnsafe(slot)
    return slot, itemId, count, tonumber(returnedNum) or 1
end

local function captureHandUnsafe(hookParam)
    local action = hookSelf(hookParam)
    local util = palUtility()
    local playerUtil = playerUtility()
    if not (action and util and playerUtil) then return end
    local param = targetParamUnsafe(action, util)
    if not objectIsValidUnsafe(param) then return end
    local key = individualKey(param)
    local beforeFullness = fullness(param)
    local slot, itemId, count = readFeedSlotUnsafe(action, playerUtil, util)
    if not (key and beforeFullness and slot and itemId and count) then return end
    pendingHand[key] = {
        fullness = beforeFullness,
        slot = slot,
        itemId = itemId,
        count = count,
    }
end

local function confirmHandUnsafe(hookParam)
    local action = hookSelf(hookParam)
    local util = palUtility()
    if not (action and util) then return end
    local param = targetParamUnsafe(action, util)
    if not objectIsValidUnsafe(param) then return end
    local key = individualKey(param)
    local pending = key and pendingHand[key] or nil
    if not pending then return end
    pendingHand[key] = nil
    local afterFullness = fullness(param)
    if not afterFullness or afterFullness <= pending.fullness then return end
    local afterId, afterCount = slotState(pending.slot)
    if afterId ~= pending.itemId or (tonumber(afterCount) or 0) < pending.count then
        remember(key, pending.itemId)
    end
end

local function onHandPre(self)
    if not hooksArmed then return end
    pcall(captureHandUnsafe, self)
end

local function onHandPost(self)
    if not hooksArmed then return end
    pcall(confirmHandUnsafe, self)
end

local function registerNativeUnsafe()
    RegisterHook(PARTY_MEAL_FN, onPartyPre, onPartyPost)
end

local function registerBlueprintUnsafe()
    RegisterHook(HAND_FEED_FN, onHandPre, onHandPost)
end

local function localPlayerPresentUnsafe()
    return objectIsValidUnsafe(FindFirstOf("PalPlayerCharacter"))
end

--- True while a local player character exists, which is this module's proxy for
--- "the world is finished, not still streaming in".
local function localPlayerPresent()
    local ok, present = pcall(localPlayerPresentUnsafe)
    if not ok then
        Log("feeding tracker: local player probe failed, staying disarmed")
        return false
    end
    return present == true
end

local function disarm(reason)
    stablePlayerPolls = 0
    if not hooksArmed then return end
    hooksArmed = false
    pendingParty = {}
    pendingHand = {}
    worldContext = nil
    Log("feeding tracker disarmed: " .. reason)
end

--- Arms both hooks once a local player has been present for two consecutive
--- polls, and disarms them again the moment it disappears.
---
--- The gate exists because of a crash, not for tidiness. Restoring a base
--- replays PartyPalMealInventoryFood for the pals it brings back, and the
--- callback walks into GetInventoryDataByPlayerUID while the player inventory
--- registry does not exist yet. That call dies reading 0xffffffffffffffff, and
--- the pcall around it catches nothing, because a native access violation is
--- not a Lua error.
---
--- Only a LISTEN HOST hits it: a dedicated server skips the module entirely,
--- and a remote client never runs the authoritative party feeding. That is why
--- three days of dedicated testing showed a healthy mod and every singleplayer
--- load died. The flag has to be able to go back to false as well - a hook, once
--- registered, survives leaving the world into the next load screen.
local function armOnGameThread()
    if not localPlayerPresent() then
        disarm("no local player")
        return
    end
    stablePlayerPolls = stablePlayerPolls + 1
    if stablePlayerPolls < ARM_STABLE_POLLS then return end
    if PARTY_HOOK_ENABLED and not nativeHookRegistered then
        local ok, err = pcall(registerNativeUnsafe)
        nativeHookRegistered = ok
        if ok then
            Log("party feeding hook registered")
        else
            registrationFailures = registrationFailures + 1
            Log("party feeding hook registration failed: " .. tostring(err))
        end
    end
    if not blueprintHookRegistered then
        local ok, err = pcall(registerBlueprintUnsafe)
        blueprintHookRegistered = ok
        if ok then
            Log("hand feeding hook registered")
        else
            registrationFailures = registrationFailures + 1
            Log("hand feeding hook registration failed: " .. tostring(err))
        end
    end
    if not hooksArmed and (nativeHookRegistered or blueprintHookRegistered) then
        hooksArmed = true
        Log("feeding tracker armed")
    end
end

local function queueArm()
    local ok, err = pcall(ExecuteInGameThread, armOnGameThread)
    if not ok then Log("feeding tracker: arm dispatch failed: " .. tostring(err)) end
end

--- Never returns true. The poll has to keep running after both hooks are up,
--- because it is also what disarms them when the world goes away.
local function armPoll()
    if registrationFailures >= MAX_REGISTRATION_FAILURES then
        Log("feeding tracker stopped after repeated registration failures")
        return true
    end
    queueArm()
    return false
end

function ConditionFeed.init()
    -- The whole tracker stays off on a dedicated server, not just its Blueprint
    -- half. Both hooks end up in foodContainerUnsafe, which reads
    -- SaveParameter.OwnerPlayerUId and hands it to GetInventoryDataByPlayerUID.
    -- A second after a join that UID is not resolvable yet on the host, and the
    -- native call dies reading 0xffffffffffffffff. The pcall around it is no
    -- help: it catches Lua errors, not an access violation, which is why gating
    -- only the Blueprint hook left the server crashing exactly as before.
    --
    -- The cost: fedFood never becomes true on a dedicated server. That is a
    -- condition that quietly never fires, against a host process that reliably
    -- dies on every join.
    if Role.isDedicated() then
        Log("feeding hooks skipped: dedicated server cannot resolve a joining player's inventory")
        return
    end
    -- Neither hook is registered here. Both wait for armPoll, which needs a
    -- local player first; see the comment there for the crash that bought this.
    if pollStarted then return end
    local ok, err = pcall(LoopAsync, ARM_POLL_MS, armPoll)
    pollStarted = ok
    if not ok then Log("feeding tracker poll failed to start: " .. tostring(err)) end
end

function ConditionFeed.lastFood(param)
    local key = individualKey(param)
    if not key then return nil, false end
    return lastFoodByIndividual[key], true
end

function ConditionFeed.wasLastFood(param, itemId)
    return type(itemId) == "string" and ConditionFeed.lastFood(param) == itemId
end

return ConditionFeed
