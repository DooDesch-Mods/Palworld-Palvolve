-- Palvolve feeding condition tracker. The game keeps no durable "last food"
-- field on an individual, so this module records successful party-bag and
-- hand-feeding consumption by stable individual id for the current session.
-- An attempted feed is never enough: both the source stack and fullness must
-- move before the food becomes condition truth.

local ConditionFeed = {}

local PARTY_MEAL_FN =
    "/Script/Pal.PalIndividualCharacterParameter:PartyPalMealInventoryFood"
local HAND_FEED_FN =
    "/Game/Pal/Blueprint/Action/Palmi/Pair/BP_ActionPairBehavior_FeedItem.BP_ActionPairBehavior_FeedItem_C:OnBeginAction"

local lastFoodByIndividual = {}
local pendingParty = {}
local pendingHand = {}
local nativeHookRegistered = false
local blueprintHookRegistered = false
local blueprintPollStarted = false
local stablePlayerPolls = 0
local blueprintRegistrationFailures = 0
local MAX_BLUEPRINT_REGISTRATION_FAILURES = 12

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

local function foodContainerUnsafe(param, util)
    local owner = param.SaveParameter.OwnerPlayerUId
    local inv = util:GetInventoryDataByPlayerUID(param, owner)
    if not objectIsValidUnsafe(inv) then return nil end
    local manager = util:GetItemContainerManager(param)
    if not objectIsValidUnsafe(manager) then return nil end
    return manager:GetContainer(inv.InventoryInfo.FoodEquipContainerId)
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
    pcall(capturePartyUnsafe, self)
end

local function onPartyPost(self)
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
    pcall(captureHandUnsafe, self)
end

local function onHandPost(self)
    pcall(confirmHandUnsafe, self)
end

local function registerNativeUnsafe()
    RegisterHook(PARTY_MEAL_FN, onPartyPre, onPartyPost)
end

local function registerNative()
    if nativeHookRegistered then return true end
    local ok = pcall(registerNativeUnsafe)
    nativeHookRegistered = ok
    return ok
end

local function registerBlueprintUnsafe()
    if blueprintHookRegistered then return end
    local player = FindFirstOf("PalPlayerCharacter")
    if not objectIsValidUnsafe(player) then
        stablePlayerPolls = 0
        return
    end
    stablePlayerPolls = stablePlayerPolls + 1
    if stablePlayerPolls < 2 then return end
    RegisterHook(HAND_FEED_FN, onHandPre, onHandPost)
    blueprintHookRegistered = true
end

local function registerBlueprintOnGameThread()
    local ok, err = pcall(registerBlueprintUnsafe)
    if not ok then
        blueprintRegistrationFailures = blueprintRegistrationFailures + 1
        Log("feeding hook registration failed: " .. tostring(err))
    end
end

local function queueBlueprintRegistration()
    pcall(ExecuteInGameThread, registerBlueprintOnGameThread)
end

local function blueprintRegistrationPoll()
    if blueprintHookRegistered then return true end
    if blueprintRegistrationFailures >= MAX_BLUEPRINT_REGISTRATION_FAILURES then
        Log("feeding hook registration stopped after repeated failures")
        return true
    end
    queueBlueprintRegistration()
    return false
end

function ConditionFeed.init()
    if not registerNative() then Log("party feeding hook registration failed") end
    if not blueprintHookRegistered and not blueprintPollStarted then
        local ok = pcall(LoopAsync, 5000, blueprintRegistrationPoll)
        blueprintPollStarted = ok
    end
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
