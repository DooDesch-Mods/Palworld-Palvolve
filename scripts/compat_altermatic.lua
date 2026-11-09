-- compat_altermatic.lua: keep Altermatic's per-Pal recolor in step with a species change.
--
-- Altermatic (Nexus mod 1626, a Blueprint LogicMod) remembers which replacer mesh it
-- rolled for each Pal. The key is the Pal's InstanceId GUID and nothing else; the entry
-- holds a swap index, not a species. When a Pal spawns, Altermatic_C:ALTR_SearchAndSwap
-- looks the GUID up in Altermatic_C.Data_SwapInstanceMap and applies the stored swap
-- without checking the species. After an evolution or a prestige the respawned body
-- therefore gets the old species' mesh, which does not fit its skeleton and animation
-- blueprint: the Pal shows its old form and stands without walk or fly animations.
--
-- The same entries are written to Pal/Content/Paks/~mods/_Altermatic_Persist_<WorldID>.json
-- (object "PalSwap", GUID as 32 upper-case hex digits -> "0/<swap index>[/1/<morphs>]")
-- at every world autosave, and read back when a world loads.
--
-- onSpeciesChanged drops the Pal's entry in the window between the species write and the
-- respawn:
--   1. ALTR_SaveObject_C:RemoveFromSaved(guid) removes it from the persist data
--      (PalSwapMap, SavedIDs, Altermatic_C.PersistIDs). It acts only while the live
--      instance still exists, so it runs first.
--   2. Data_SwapInstanceMap:Remove(guid) removes the live instance.
--   3. ALTR_SaveObject_C:SavePersist() rewrites the persist file, so a game closed before
--      the next autosave does not bring the old entry back on the next load.
-- The respawned Pal then has no entry, and Altermatic rolls a recolor for its new species
-- exactly as it does for a newly caught Pal (or keeps the default mesh if none matches).

local ObjTrack = require("objtrack")

local CompatAltermatic = {}

local ALTERMATIC_CLASS = "Altermatic_C"

local function Log(msg)
    print(string.format("[Palvolve] [altermatic] %s\n", msg))
end

local function u32(v)
    local n = math.tointeger(v)
    if n == nil then return nil end
    return n & 0xFFFFFFFF
end

--- The GUID as Altermatic writes it (Conv_GuidToString, 32 hex digits).
local function guidString(guid)
    local a, b, c, d = u32(guid.A), u32(guid.B), u32(guid.C), u32(guid.D)
    if a == nil or b == nil or c == nil or d == nil then return nil end
    return string.format("%08X%08X%08X%08X", a, b, c, d)
end

local function readGuidUnsafe(param)
    local id = param.IndividualId.InstanceId
    return { A = id.A, B = id.B, C = id.C, D = id.D }
end

local function readStateUnsafe(altermatic)
    return altermatic.Data_SwapInstanceMap, altermatic.SaveObject
end

local function containsUnsafe(map, key)
    return map:Contains(key)
end

local function removeFromSavedUnsafe(saveObject, guid)
    saveObject:RemoveFromSaved(guid)
end

local function removeUnsafe(map, key)
    map:Remove(key)
end

local function savePersistUnsafe(saveObject)
    saveObject:SavePersist()
end

local function validUnsafe(obj)
    return obj ~= nil and obj:IsValid()
end

local function isValid(obj)
    local ok, valid = pcall(validUnsafe, obj)
    return ok and valid == true
end

--- Call after the species of a Pal was written and before its new body spawns.
--- param: the Pal's PalIndividualCharacterParameter. newId: the species written (log only).
--- Returns true when Altermatic holds no entry for this Pal afterwards (including when
--- Altermatic is not loaded), false when the entry could not be removed.
function CompatAltermatic.onSpeciesChanged(param, newId)
    local what = tostring(newId)
    local altermatic = ObjTrack.first(ALTERMATIC_CLASS)
    if altermatic == nil then
        Log(string.format("Altermatic not loaded, nothing to reset for '%s'", what))
        return true
    end
    if not isValid(param) then
        Log(string.format("[WARN] species change to '%s': Pal parameter is not valid, Altermatic entry left as is", what))
        return false
    end
    local okGuid, guid = pcall(readGuidUnsafe, param)
    if not okGuid then
        Log(string.format("[ERROR] species change to '%s': InstanceId unreadable, Altermatic entry left as is: %s",
            what, tostring(guid)))
        return false
    end
    local key = guidString(guid)
    if key == nil then
        Log(string.format("[ERROR] species change to '%s': InstanceId has non-integer parts, Altermatic entry left as is", what))
        return false
    end
    local okState, map, saveObject = pcall(readStateUnsafe, altermatic)
    if not okState or map == nil then
        Log(string.format("[ERROR] %s: Altermatic's swap map is unreadable, entry left as is: %s",
            key, tostring(okState and "nil map" or map)))
        return false
    end
    local okHas, has = pcall(containsUnsafe, map, guid)
    if not okHas then
        Log(string.format("[ERROR] %s: Altermatic's swap map rejected the lookup, entry left as is: %s",
            key, tostring(has)))
        return false
    end
    if not has then
        Log(string.format("%s -> '%s': Altermatic has no recolor stored for this Pal", key, what))
        return true
    end

    local saveValid = isValid(saveObject)
    if saveValid then
        local okSaved, savedErr = pcall(removeFromSavedUnsafe, saveObject, guid)
        if not okSaved then
            -- The live entry below is what re-applies the old mesh; go on and remove it.
            Log(string.format("[WARN] %s: RemoveFromSaved failed, the persist data keeps the old entry until Altermatic saves: %s",
                key, tostring(savedErr)))
        end
    else
        Log(string.format("[WARN] %s: Altermatic's save object is not valid, only the live entry is removed", key))
    end

    local okRemove, removeErr = pcall(removeUnsafe, map, guid)
    if not okRemove then
        Log(string.format("[ERROR] %s: removing the live Altermatic entry failed, the old recolor will be applied: %s",
            key, tostring(removeErr)))
        return false
    end
    local okAfter, still = pcall(containsUnsafe, map, guid)
    if not okAfter or still then
        Log(string.format("[ERROR] %s: the Altermatic entry is still there after Remove (%s), the old recolor will be applied",
            key, okAfter and "still present" or tostring(still)))
        return false
    end

    if saveValid then
        local okSave, saveErr = pcall(savePersistUnsafe, saveObject)
        if not okSave then
            Log(string.format("[WARN] %s: SavePersist failed, the persist file keeps the old entry until the next world autosave: %s",
                key, tostring(saveErr)))
        else
            Log(string.format("%s -> '%s': Altermatic recolor reset, persist file rewritten", key, what))
            return true
        end
    end
    Log(string.format("%s -> '%s': Altermatic recolor reset in memory", key, what))
    return true
end

CompatAltermatic._guidString = guidString

return CompatAltermatic
