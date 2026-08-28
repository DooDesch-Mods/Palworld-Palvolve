-- Palvolve structural slot rewards: a fourth
-- active move selected deterministically from the Pal's learned move pool.

local Config = require("config")
local Elements = require("elements")
local I18n = require("i18n")
local Role = require("role")
local WAZA_IDS = require("waza_static")

local PalSlots = {}

-- These defaults are intentionally local until config.lua exposes the same
-- keys. Each entry accepts "off" or "active".
--
-- There is no "passive" mode. Palvolve's own two passives reserve slots 5 and 6
-- and nothing more; 7 and 8 belong to the player. Granting a second copy of the
-- ladder passive would fill them with our own reward doubled, which is a stat
-- boost wearing a slot's clothes, and it would be invisible anyway - the status
-- screen draws four cards.
PalSlots.settings = {
    evolutionBonusSlot = "off",
    prestigeBonusSlot = "off",
}

local MAX_ACTIVE_MOVES = 4
local MAX_WAZA_ID = WAZA_IDS.MAX or 391
local ELEMENT_IDS = {
    Normal = 1, Fire = 2, Water = 3, Leaf = 4, Electricity = 5,
    Ice = 6, Earth = 7, Dark = 8, Dragon = 9,
}

local WAZA_NAMES = {}
for name, id in pairs(WAZA_IDS) do
    if type(id) == "number" then WAZA_NAMES[id] = name end
end

local function isValidUnsafe(object)
    return object:IsValid()
end

local function isValid(object)
    if object == nil then return false end
    local ok, valid = pcall(isValidUnsafe, object)
    return ok and valid == true
end

local function hasAuthorityUnsafe(pc)
    return pc:HasAuthority()
end

local function playerController(playerCtx)
    if type(playerCtx) == "table" then return playerCtx.pc end
    return playerCtx
end

local function worldContextOf(param, playerCtx)
    if type(playerCtx) == "table" and isValid(playerCtx.pawn) then return playerCtx.pawn end
    local pc = playerController(playerCtx)
    if isValid(pc) then return pc end
    if isValid(param) then return param end
    return nil
end

local function mutationAllowed(playerCtx)
    if not Role.hasWorldAuthority() then return false end
    local pc = playerController(playerCtx)
    if pc == nil then return true end
    if not isValid(pc) then return false end
    local ok, authority = pcall(hasAuthorityUnsafe, pc)
    return ok and authority == true
end

local function arrayLength(array)
    return #array
end

local function arrayValue(array, index)
    return array[index]
end

local function remoteValue(value)
    return value:get()
end

local function wazaNumber(value)
    local id = tonumber(value)
    if id then return id end
    if type(value) ~= "userdata" then return nil end
    local ok, inner = pcall(remoteValue, value)
    if not ok then return nil end
    return tonumber(inner)
end

local function getEquipWazaUnsafe(param)
    return param:GetEquipWaza()
end

local function getMasteredWazaUnsafe(param)
    return param:GetMasteredWaza()
end

local function readWazaList(param, getter)
    local okArray, array = pcall(getter, param)
    if not okArray or array == nil then return nil, "move list is unavailable" end
    local okCount, count = pcall(arrayLength, array)
    if not okCount or type(count) ~= "number" then
        return nil, "move list count is unavailable"
    end

    local out = {}
    for i = 1, count do
        local okValue, value = pcall(arrayValue, array, i)
        if not okValue then return nil, string.format("move entry %d is unavailable", i) end
        local id = wazaNumber(value)
        if id == nil then return nil, string.format("move entry %d is not an enum", i) end
        -- None is the engine's empty sentinel, not an active skill slot.
        if id > 0 and id < MAX_WAZA_ID then out[#out + 1] = id end
    end
    return out
end

local function copyExpected(expected)
    if type(expected) ~= "table" then return nil, "active move snapshot is missing" end
    local copy, seen = {}, {}
    for i = 1, #expected do
        local id = tonumber(expected[i])
        if not id or id <= 0 or id >= MAX_WAZA_ID or id % 1 ~= 0 then
            return nil, string.format("active move snapshot entry %d is invalid", i)
        end
        if seen[id] then return nil, string.format("active move snapshot entry %d is duplicated", i) end
        seen[id] = true
        copy[i] = id
    end
    if #copy > MAX_ACTIVE_MOVES then return nil, "active move snapshot exceeds four slots" end
    return copy
end

local function sameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

function PalSlots.capture(param)
    if not isValid(param) then return nil, "Pal parameter is unavailable" end
    return readWazaList(param, getEquipWazaUnsafe)
end

function PalSlots.verify(param, expected)
    local wanted, wantedErr = copyExpected(expected)
    if not wanted then return false, wantedErr end
    local actual, readErr = PalSlots.capture(param)
    if not actual then return false, readErr end
    if sameList(actual, wanted) then return true, actual end
    return false, string.format("active move read-back differs: expected [%s], got [%s]",
        table.concat(wanted, ", "), table.concat(actual, ", "))
end

local function addEquipDirectUnsafe(state)
    state.param:AddEquipWaza(state.id)
end

local function addEquipServerUnsafe(state)
    state.pc:AddEquipWaza_ToServer(state.param.IndividualId, state.id)
end

local function removeEquipDirectUnsafe(state)
    state.param:RemoveEquipWaza(state.id)
end

local function removeEquipServerUnsafe(state)
    state.pc:RemoveEquipWaza_ToServer(state.param.IndividualId, state.id)
end

local function mutateEquip(param, id, playerCtx, adding)
    local pc = playerController(playerCtx)
    local state = { param = param, id = id, pc = pc }
    if pc ~= nil then
        if not isValid(pc) then return false, "player controller is unavailable" end
        if adding then return pcall(addEquipServerUnsafe, state) end
        return pcall(removeEquipServerUnsafe, state)
    end
    if adding then return pcall(addEquipDirectUnsafe, state) end
    return pcall(removeEquipDirectUnsafe, state)
end

local function writeExact(param, expected, playerCtx)
    local current, readErr = PalSlots.capture(param)
    if not current then return false, readErr end

    local remaining = #current
    while remaining > 0 do
        local okRemove, removeErr = mutateEquip(param, current[remaining], playerCtx, false)
        if not okRemove then return false, "active move removal failed: " .. tostring(removeErr) end
        local after, afterErr = PalSlots.capture(param)
        if not after then return false, afterErr end
        if #after >= remaining then return false, "active move removal did not reduce the list" end
        current = after
        remaining = #current
    end

    for i, id in ipairs(expected) do
        local okAdd, addErr = mutateEquip(param, id, playerCtx, true)
        if not okAdd then
            return false, string.format("active move append %d failed: %s", i, tostring(addErr))
        end
    end
    return PalSlots.verify(param, expected)
end

function PalSlots.restore(param, expected, playerCtx)
    if not mutationAllowed(playerCtx) then return false, "active move restore requires host authority" end
    local wanted, wantedErr = copyExpected(expected)
    if not wanted then return false, wantedErr end

    local before, beforeErr = PalSlots.capture(param)
    if not before then return false, beforeErr end
    if sameList(before, wanted) then return true, before end

    local restored, restoreErr = writeExact(param, wanted, playerCtx)
    if restored then return true, wanted end

    -- A failed restore must not leave the Pal with a partially rebuilt move
    -- list. Put the entry state from this call back while authority still owns it.
    local rollbackOk, rollbackErr = writeExact(param, before, playerCtx)
    if not rollbackOk then
        return false, tostring(restoreErr) .. "; original active moves also failed to restore: "
            .. tostring(rollbackErr)
    end
    return false, restoreErr
end

local function getWazaDatabaseUnsafe(worldCtx)
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    if not (util and util:IsValid() and worldCtx and worldCtx:IsValid()) then return nil end
    local db = util:GetWazaDatabase(worldCtx)
    if db and db:IsValid() then return db end
    return nil
end

local function getWazaRowUnsafe(db, id)
    local out = {}
    local found = db:FindWazaForBP(id, out)
    return not not found, tonumber(out.Power), out.Element
end

local function characterElementsUnsafe(state)
    local characterId = state.param:GetCharacterID():ToString()
    return Elements.of(characterId, state.worldCtx)
end

local function elementNumber(value)
    local id = tonumber(value)
    if id then return id end
    if type(value) == "userdata" then
        local ok, inner = pcall(remoteValue, value)
        if ok then return elementNumber(inner) end
        return nil
    end
    if type(value) ~= "string" then return nil end
    return ELEMENT_IDS[value:match("([%w]+)$")]
end

local function isNonUniqueMove(id)
    local name = WAZA_NAMES[id]
    if not name or name == "None" or name == "MAX" then return false end
    if name:sub(1, 7) == "Unique_" then return false end
    return true
end

local function stronger(candidate, best)
    if best == nil then return true end
    if candidate.power ~= best.power then return candidate.power > best.power end
    if candidate.elementMatch ~= best.elementMatch then return candidate.elementMatch end
    return candidate.id < best.id
end

function PalSlots.selectStrongestMove(param, playerCtx)
    if not isValid(param) then return nil, "Pal parameter is unavailable" end
    local mastered, masteredErr = readWazaList(param, getMasteredWazaUnsafe)
    if not mastered then return nil, masteredErr end
    local equipped, equippedErr = PalSlots.capture(param)
    if not equipped then return nil, equippedErr end

    local equippedSet = {}
    for _, id in ipairs(equipped) do equippedSet[id] = true end

    local worldCtx = worldContextOf(param, playerCtx)
    if not worldCtx then return nil, "world context is unavailable" end
    local okElements, ownElements = pcall(characterElementsUnsafe, {
        param = param,
        worldCtx = worldCtx,
    })
    if not okElements or type(ownElements) ~= "table" then
        return nil, "Pal element data is unavailable"
    end
    local elementSet = {}
    for _, name in ipairs(ownElements) do
        local id = ELEMENT_IDS[name]
        if id then elementSet[id] = true end
    end
    if next(elementSet) == nil then return nil, "Pal element data is unavailable" end

    local okDb, db = pcall(getWazaDatabaseUnsafe, worldCtx)
    if not okDb or db == nil then return nil, "DT_WazaDataTable is unavailable" end

    local best, seen = nil, {}
    for _, id in ipairs(mastered) do
        if not seen[id] and not equippedSet[id] and isNonUniqueMove(id) then
            seen[id] = true
            local okRow, found, power, element = pcall(getWazaRowUnsafe, db, id)
            if not okRow or not found or type(power) ~= "number" then
                return nil, string.format("DT_WazaDataTable row %d is unavailable", id)
            end
            local candidate = {
                id = id,
                name = WAZA_NAMES[id],
                power = power,
                element = elementNumber(element),
            }
            candidate.elementMatch = candidate.element ~= nil and elementSet[candidate.element] == true
            if stronger(candidate, best) then best = candidate end
        end
    end
    return best
end

function PalSlots.grantActive(param, playerCtx)
    if not mutationAllowed(playerCtx) then return false, "active slot grant requires host authority" end
    local initial, readErr = PalSlots.capture(param)
    if not initial then return false, readErr end
    if #initial >= MAX_ACTIVE_MOVES then
        return true, {
            changed = false, mode = "active", activeMovesBefore = initial,
            activeMoves = initial,
            message = I18n.msg("bonusSlotActiveUnavailable"),
        }
    end

    local selected, selectErr = PalSlots.selectStrongestMove(param, playerCtx)
    if not selected then
        if selectErr then return false, selectErr end
        return true, {
            changed = false, mode = "active", activeMovesBefore = initial,
            activeMoves = initial,
            message = I18n.msg("bonusSlotActiveUnavailable"),
        }
    end

    local okAdd, addErr = mutateEquip(param, selected.id, playerCtx, true)
    if not okAdd then return false, "active slot grant failed: " .. tostring(addErr) end
    local expected = {}
    for i, id in ipairs(initial) do expected[i] = id end
    expected[#expected + 1] = selected.id
    local verified, verifyErr = PalSlots.verify(param, expected)
    if not verified then
        local rollbackOk, rollbackErr = writeExact(param, initial, playerCtx)
        if not rollbackOk then
            return false, tostring(verifyErr) .. "; original active moves also failed to restore: "
                .. tostring(rollbackErr)
        end
        return false, verifyErr
    end
    return true, {
        changed = true, mode = "active", wazaId = selected.id,
        wazaName = selected.name, power = selected.power,
        activeMovesBefore = initial, activeMoves = expected,
        message = I18n.msg("bonusSlotActiveGranted"),
    }
end

local function configuredMode(key)
    local mode = Config[key]
    if mode == nil then mode = PalSlots.settings[key] end
    if mode == "off" or mode == "active" then return mode end
    return nil
end

local function grantConfigured(param, playerCtx, settingKey, passiveGrant)
    local mode = configuredMode(settingKey)
    if mode == nil then return false, settingKey .. " has an invalid slot mode" end
    if mode == "off" then return true, { changed = false, mode = "off" } end
    if not mutationAllowed(playerCtx) then return false, "bonus slot grant requires host authority" end
    return PalSlots.grantActive(param, playerCtx)
end

function PalSlots.grantEvolution(param, playerCtx)
    return grantConfigured(param, playerCtx, "evolutionBonusSlot")
end

function PalSlots.grantPrestige(param, playerCtx)
    return grantConfigured(param, playerCtx, "prestigeBonusSlot")
end

function PalSlots.restoreGrant(param, grantResult, playerCtx)
    if type(grantResult) ~= "table" then return false, "slot grant snapshot is missing" end
    if grantResult.mode == "off" then return true, grantResult end
    if grantResult.mode == "active" then
        return PalSlots.restore(param, grantResult.activeMovesBefore, playerCtx)
    end
    return false, "slot grant snapshot has an invalid mode"
end

return PalSlots
