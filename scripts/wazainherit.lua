-- Ordered move snapshots and exact species-swap inheritance.

local WazaInherit = {}

local WAZA_IDS = require("waza_static")
local WAZA_NAMES = {}
for name, id in pairs(WAZA_IDS) do
    if type(id) == "number" and WAZA_NAMES[id] == nil then
        WAZA_NAMES[id] = name
    end
end

local function getSaveParameter(param)
    return param.SaveParameter
end

local function getSaveParameterMirror(param)
    return param.SaveParameterMirror
end

local function getField(owner, field)
    return owner[field]
end

local function getArrayLength(list)
    return #list
end

local function getArrayNum(list)
    return list:GetArrayNum()
end

local function getArrayValue(list, index)
    return list[index]
end

local function unwrapValue(value)
    return value:get()
end

local function writeArrayValue(list, index, value)
    list[index] = value
end

local function clearEquipWaza(param)
    param:ClearEquipWaza()
end

local function addEquipWaza(param, id)
    param:AddEquipWaza(id)
end

local function nameForValue(value)
    if type(value) == "userdata" then
        local okUnwrap, unwrapped = pcall(unwrapValue, value)
        if not okUnwrap then return nil end
        value = unwrapped
    end
    local id = tonumber(value)
    if type(id) ~= "number" then return nil end
    return WAZA_NAMES[id]
end

local function copyNames(names, label)
    if type(names) ~= "table" then return nil, label .. " is missing" end
    local copy = {}
    for i = 1, #names do
        local name = names[i]
        local id = type(name) == "string" and WAZA_IDS[name] or nil
        if type(id) ~= "number" or name == "MAX" then
            return nil, string.format("%s entry %d is invalid", label, i)
        end
        copy[i] = name
    end
    return copy
end

local function readCount(list, label)
    local count = nil
    local okRemote, remoteCount = pcall(getArrayNum, list)
    if okRemote and type(remoteCount) == "number" then count = remoteCount end
    local okLength, length = pcall(getArrayLength, list)
    if okLength and type(length) == "number" then count = math.max(count or 0, length) end
    if count ~= nil then return count end
    return nil, label .. " count is unavailable"
end

local function readNames(owner, field, label)
    local okList, list = pcall(getField, owner, field)
    if not okList or list == nil then return nil, label .. " is unavailable" end

    local count, countErr = readCount(list, label)
    if count == nil then return nil, countErr end

    local names = {}
    for i = 1, count do
        local okValue, value = pcall(getArrayValue, list, i)
        if not okValue or value == nil then
            return nil, string.format("%s entry %d is unavailable", label, i)
        end
        local name = nameForValue(value)
        if not name or name == "MAX" then
            return nil, string.format("%s entry %d has an unknown move id", label, i)
        end
        names[i] = name
    end
    return names
end

-- Everything the Pal may currently put in a slot: what the species learns by level
-- plus MasteredWaza, merged by the game itself. Asking the engine beats rebuilding
-- the rule from DT_WazaMasterLevel, and it is the exact list the picker shows.
local function getEquipableWaza(param)
    return param:GetEquipableWaza()
end

local function readKnown(param)
    local okList, list = pcall(getEquipableWaza, param)
    if not okList or list == nil then
        return nil, "GetEquipableWaza is unavailable: " .. tostring(list)
    end
    local count, countErr = readCount(list, "GetEquipableWaza")
    if count == nil then return nil, countErr end

    local names = {}
    for i = 1, count do
        local okValue, value = pcall(getArrayValue, list, i)
        if okValue and value ~= nil then
            local name = nameForValue(value)
            -- An id this build knows and waza_static does not is skipped rather than
            -- fatal: it costs one move, not the whole evolution.
            if name and name ~= "MAX" and name ~= "None" then names[#names + 1] = name end
        end
    end
    return names
end

local function captureHalf(owner, label)
    local equip, equipErr = readNames(owner, "EquipWaza", label .. ".EquipWaza")
    if not equip then return nil, equipErr end
    local mastered, masteredErr = readNames(owner, "MasteredWaza", label .. ".MasteredWaza")
    if not mastered then return nil, masteredErr end
    return { equip = equip, mastered = mastered }
end

function WazaInherit.capture(param)
    local okSave, save = pcall(getSaveParameter, param)
    if not okSave or save == nil then return nil, "SaveParameter is unavailable" end
    local okMirror, mirror = pcall(getSaveParameterMirror, param)
    if not okMirror or mirror == nil then return nil, "SaveParameterMirror is unavailable" end

    local saveState, saveErr = captureHalf(save, "SaveParameter")
    if not saveState then return nil, saveErr end
    local mirrorState, mirrorErr = captureHalf(mirror, "SaveParameterMirror")
    if not mirrorState then return nil, mirrorErr end
    -- Not fatal when it fails: the snapshot still describes both save halves, and
    -- only the wider "known" inheritance mode has nothing to work from. The reason
    -- travels with the snapshot so the caller can put it in the log.
    local known, knownErr = readKnown(param)
    return { save = saveState, mirror = mirrorState, known = known, knownError = knownErr }
end

local function semanticNames(names)
    local out = {}
    for _, name in ipairs(names) do
        if name ~= "None" then out[#out + 1] = name end
    end
    return out
end

local function sameNames(left, right)
    left = semanticNames(left)
    right = semanticNames(right)
    if #left ~= #right then return false end
    for i = 1, #left do
        if left[i] ~= right[i] then return false end
    end
    return true
end

local function writeDirect(owner, field, names, label)
    local wanted, wantedErr = copyNames(names, label)
    if not wanted then return false, wantedErr end
    local ids = {}
    for i, name in ipairs(wanted) do ids[i] = WAZA_IDS[name] end

    local okList, list = pcall(getField, owner, field)
    if not okList or list == nil then return false, label .. " is unavailable" end
    local count, countErr = readCount(list, label)
    if count == nil then return false, countErr end

    -- UE4SS can grow reflected arrays by assigning the next index, but exposes
    -- no safe resize for MasteredWaza. Zeroing the unused tail removes moves
    -- semantically while leaving the allocator-owned array storage intact.
    -- Growing that array is the native half's job, see teachRepertoire below.
    local last = math.max(count, #ids)
    for i = 1, last do
        local okWrite, writeErr = pcall(writeArrayValue, list, i, ids[i] or 0)
        if not okWrite then
            return false, string.format("%s write %d failed: %s", label, i, tostring(writeErr))
        end
    end
    return true
end

local function validateState(state)
    if type(state) ~= "table" or type(state.save) ~= "table"
        or type(state.mirror) ~= "table" then
        return nil, "move snapshot is missing"
    end
    local saveEquip, err = copyNames(state.save.equip, "SaveParameter.EquipWaza snapshot")
    if not saveEquip then return nil, err end
    local saveMastered
    saveMastered, err = copyNames(state.save.mastered, "SaveParameter.MasteredWaza snapshot")
    if not saveMastered then return nil, err end
    local mirrorEquip
    mirrorEquip, err = copyNames(state.mirror.equip, "SaveParameterMirror.EquipWaza snapshot")
    if not mirrorEquip then return nil, err end
    local mirrorMastered
    mirrorMastered, err = copyNames(state.mirror.mastered,
        "SaveParameterMirror.MasteredWaza snapshot")
    if not mirrorMastered then return nil, err end
    return {
        save = { equip = saveEquip, mastered = saveMastered },
        mirror = { equip = mirrorEquip, mastered = mirrorMastered },
    }
end

local function verifyState(param, expected)
    local actual, captureErr = WazaInherit.capture(param)
    if not actual then return false, captureErr end
    if not sameNames(actual.save.equip, expected.save.equip) then
        return false, "SaveParameter.EquipWaza read-back differs"
    end
    if not sameNames(actual.save.mastered, expected.save.mastered) then
        return false, "SaveParameter.MasteredWaza read-back differs"
    end
    if not sameNames(actual.mirror.equip, expected.mirror.equip) then
        return false, "SaveParameterMirror.EquipWaza read-back differs"
    end
    if not sameNames(actual.mirror.mastered, expected.mirror.mastered) then
        return false, "SaveParameterMirror.MasteredWaza read-back differs"
    end
    return true
end

local function writeState(param, requested)
    local state, stateErr = validateState(requested)
    if not state then return false, stateErr end
    local okSave, save = pcall(getSaveParameter, param)
    if not okSave or save == nil then return false, "SaveParameter is unavailable" end
    local okMirror, mirror = pcall(getSaveParameterMirror, param)
    if not okMirror or mirror == nil then return false, "SaveParameterMirror is unavailable" end

    local okClear, clearErr = pcall(clearEquipWaza, param)
    if not okClear then return false, "EquipWaza clear failed: " .. tostring(clearErr) end
    for _, name in ipairs(semanticNames(state.save.equip)) do
        local id = WAZA_IDS[name]
        local okAdd, addErr = pcall(addEquipWaza, param, id)
        if not okAdd then
            return false, string.format("EquipWaza add %s failed: %s", name, tostring(addErr))
        end
    end

    -- AddEquipWaza is the reflected teaching path and requires the numeric
    -- EPalWazaID. Direct writes then keep both save halves ordered, including
    -- MasteredWaza, for which this build exposes no add or clear UFunction.
    local okWrite, writeErr = writeDirect(save, "EquipWaza", state.save.equip,
        "SaveParameter.EquipWaza")
    if not okWrite then return false, writeErr end
    okWrite, writeErr = writeDirect(save, "MasteredWaza", state.save.mastered,
        "SaveParameter.MasteredWaza")
    if not okWrite then return false, writeErr end
    okWrite, writeErr = writeDirect(mirror, "EquipWaza", state.mirror.equip,
        "SaveParameterMirror.EquipWaza")
    if not okWrite then return false, writeErr end
    okWrite, writeErr = writeDirect(mirror, "MasteredWaza", state.mirror.mastered,
        "SaveParameterMirror.MasteredWaza")
    if not okWrite then return false, writeErr end
    return verifyState(param, state)
end

local function writeTransaction(param, expected)
    local before, beforeErr = WazaInherit.capture(param)
    if not before then return false, beforeErr end
    local okWrite, writeErr = writeState(param, expected)
    if okWrite then return true end

    local rollbackOk, rollbackErr = writeState(param, before)
    if not rollbackOk then
        return false, tostring(writeErr) .. "; original move lists also failed to restore: "
            .. tostring(rollbackErr)
    end
    return false, writeErr
end

local function keepInherited(names)
    local kept, removed = {}, 0
    for _, name in ipairs(names) do
        if name:sub(1, 6) == "Unique" then
            removed = removed + 1
        elseif name ~= "None" then
            kept[#kept + 1] = name
        end
    end
    return kept, removed
end

-- Carrying a move across keeps it EQUIPPED, which is not the same as knowing it.
-- The picker offers what the new species learns by level - DT_WazaMasterLevel, read
-- through PalWazaDatabase::GetMasterrableWaza_BetweenLevel - plus whatever sits in
-- MasteredWaza. A move the old species knew is in neither list, so swapping it out
-- of a slot loses it for good.
--
-- MasteredWaza is what a skill fruit writes, it is empty on every wild-caught Pal,
-- and this build exposes no add or setter for it. Growing it from here would mean
-- writing past the end of a zero-length array, so this one step goes native.
local function teachRepertoire(param, ...)
    if type(PalvolveNative_TeachMasteredWaza) ~= "function" then
        return false, "the native half is not loaded"
    end
    local seen, ids = {}, {}
    for _, names in ipairs({ ... }) do
        for _, name in ipairs(names) do
            local id = WAZA_IDS[name]
            if type(id) == "number" and id > 0 and not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    if #ids == 0 then return true, 0 end

    local called, ok, added, message = pcall(PalvolveNative_TeachMasteredWaza,
        param, table.concat(ids, ","))
    if not called then return false, tostring(ok) end
    if not ok then return false, tostring(message) end
    return true, added, message
end

function WazaInherit.apply(param, snapshot, mode)
    local state, stateErr = validateState(snapshot)
    if not state then return false, stateErr end
    local equip, removedEquip = keepInherited(state.save.equip)
    local mastered, removedMastered = keepInherited(state.save.mastered)
    local expected = {
        save = { equip = equip, mastered = mastered },
        mirror = { equip = equip, mastered = mastered },
    }
    local okWrite, writeErr = writeTransaction(param, expected)
    if not okWrite then return false, writeErr end

    -- "equipped" carries only what sat in the slots. "known" carries the whole list
    -- the Pal could choose from, so every evolution widens the choice instead of
    -- trading the old species' moves for the new one's.
    local known, knownError = nil, nil
    if mode == "known" then
        known = type(snapshot.known) == "table" and keepInherited(snapshot.known) or nil
        knownError = snapshot.knownError
    end

    -- Reported, never fatal: the moves are already equipped at this point, and an
    -- evolution that worked must not be rolled back over the repertoire step.
    local okTeach, added, teachDetail = teachRepertoire(param, equip, mastered, known or {})
    return true, {
        removedEquip = removedEquip,
        removedMastered = removedMastered,
        knownCount = known and #known or nil,
        knownError = knownError,
        taught = okTeach and added or nil,
        teachError = (not okTeach) and added or nil,
        teachDetail = okTeach and teachDetail or nil,
    }
end

function WazaInherit.restore(param, snapshot)
    local state, stateErr = validateState(snapshot)
    if not state then return false, stateErr end
    return writeTransaction(param, state)
end

return WazaInherit
