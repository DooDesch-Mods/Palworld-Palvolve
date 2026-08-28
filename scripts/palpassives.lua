-- Palvolve passive ladder ownership, ordered snapshots and exact rollback.

local PalPassives = {}

local LADDERS = {
    evolved = { prefix = "Palvolve_Evolved_", maxStage = 4 },
    prestige = { prefix = "Palvolve_Prestige_", maxStage = 10 },
}

local function getPassiveList(param)
    return param.SaveParameter.PassiveSkillList
end

local function getArrayNum(list)
    return list:GetArrayNum()
end

local function getArrayValue(list, index)
    return list[index]
end

local function unwrapValue(value)
    local getter = value.get
    if getter then return getter(value) end
    return nil
end

local function valueToString(value)
    return value:ToString()
end

local function writeArrayValue(list, index, id)
    list[index] = FName(id)
end

local function removePassive(param, id)
    param:RemovePassiveSkill(FName(id))
end

local function copyExpected(expected)
    if type(expected) ~= "table" then
        return nil, "passive snapshot is missing"
    end
    local copy = {}
    for i = 1, #expected do
        if type(expected[i]) ~= "string" or expected[i] == "" then
            return nil, string.format("passive snapshot entry %d is invalid", i)
        end
        copy[i] = expected[i]
    end
    return copy
end

local function sameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function readName(value)
    if type(value) == "string" then return value end
    local okName, name = pcall(valueToString, value)
    if okName and name ~= nil then return tostring(name) end

    if type(value) == "userdata" then
        local okInner, inner = pcall(unwrapValue, value)
        if okInner and inner ~= nil then
            okName, name = pcall(valueToString, inner)
            if okName and name ~= nil then return tostring(name) end
        end
    end
    return nil
end

function PalPassives.capture(param)
    local okList, list = pcall(getPassiveList, param)
    if not okList or list == nil then
        return nil, "SaveParameter.PassiveSkillList is unavailable"
    end

    local okCount, count = pcall(getArrayNum, list)
    if not okCount or type(count) ~= "number" then
        return nil, "PassiveSkillList count is unavailable"
    end

    local out = {}
    for i = 1, count do
        local okValue, value = pcall(getArrayValue, list, i)
        if not okValue or value == nil then
            return nil, string.format("PassiveSkillList entry %d is unavailable", i)
        end
        local name = readName(value)
        if not name then
            return nil, string.format("PassiveSkillList entry %d is not an FName", i)
        end
        out[i] = name
    end
    return out
end

local function parseStage(id, ladder)
    local raw = id:match("^" .. ladder.prefix .. "(%d+)$")
    if not raw then return nil end
    return tonumber(raw)
end

local function stateFor(names, ladder)
    local state = { id = nil, stage = 0, index = nil, count = 0 }
    for i, id in ipairs(names) do
        local rawStage = parseStage(id, ladder)
        if rawStage then
            local stage = math.max(1, math.min(rawStage, ladder.maxStage))
            state.count = state.count + 1
            if not state.id or stage > state.stage then
                state.id = id
                state.stage = stage
                state.index = i
            end
        end
    end
    return state
end

local function resolveNames(names)
    return {
        evolved = stateFor(names, LADDERS.evolved),
        prestige = stateFor(names, LADDERS.prestige),
    }
end

--- The top rung of a ladder. Callers need it to refuse work that cannot change
--- anything: a Pal already at the last prestige rank gains nothing from another
--- prestige, and would pay a stone and all of its levels for it.
function PalPassives.maxStage(ladderName)
    local ladder = LADDERS[ladderName]
    return ladder and ladder.maxStage or 0
end

function PalPassives.resolve(param)
    local names, err = PalPassives.capture(param)
    if not names then return nil, err end
    return resolveNames(names)
end

function PalPassives.verify(param, expected)
    local wanted, expectedErr = copyExpected(expected)
    if not wanted then return false, expectedErr end
    local actual, readErr = PalPassives.capture(param)
    if not actual then return false, readErr end
    if sameList(actual, wanted) then return true, actual end
    return false, string.format("passive read-back differs: expected [%s], got [%s]",
        table.concat(wanted, ", "), table.concat(actual, ", "))
end

-- Removal is the only reflected operation that shrinks and compacts this
-- array. Rebuilding is reserved for rollback and damaged duplicate states,
-- where preserving the exact count matters more than minimizing writes.
local function writeExact(param, expected)
    local current, readErr = PalPassives.capture(param)
    if not current then return false, readErr end

    local remaining = #current
    while remaining > 0 do
        local okRemove, removeErr = pcall(removePassive, param, current[remaining])
        if not okRemove then
            return false, "passive removal failed: " .. tostring(removeErr)
        end
        local after, afterErr = PalPassives.capture(param)
        if not after then return false, afterErr end
        if #after >= remaining then
            return false, "passive removal did not reduce the list"
        end
        current = after
        remaining = #current
    end

    local okList, list = pcall(getPassiveList, param)
    if not okList or list == nil then
        return false, "SaveParameter.PassiveSkillList is unavailable"
    end
    for i, id in ipairs(expected) do
        local okWrite, writeErr = pcall(writeArrayValue, list, i, id)
        if not okWrite then
            return false, string.format("passive append %d failed: %s", i, tostring(writeErr))
        end
    end
    return PalPassives.verify(param, expected)
end

function PalPassives.restore(param, expected)
    local wanted, expectedErr = copyExpected(expected)
    if not wanted then return false, expectedErr end

    local before, beforeErr = PalPassives.capture(param)
    if not before then return false, beforeErr end
    if sameList(before, wanted) then return true, before end

    local ok, err = writeExact(param, wanted)
    if ok then return true, wanted end

    -- A failed exact restore should not strand the Pal in a half-rebuilt list.
    -- Put the entry state from this call back when the engine still permits it.
    local rollbackOk, rollbackErr = writeExact(param, before)
    if not rollbackOk then
        return false, tostring(err) .. "; original passive list also failed to restore: "
            .. tostring(rollbackErr)
    end
    return false, err
end

local function canonicalList(names, stages)
    local out = {}
    for _, id in ipairs(names) do
        if not parseStage(id, LADDERS.evolved) and not parseStage(id, LADDERS.prestige) then
            out[#out + 1] = id
        end
    end
    if stages.evolved > 0 then
        out[#out + 1] = LADDERS.evolved.prefix .. tostring(stages.evolved)
    end
    if stages.prestige > 0 then
        out[#out + 1] = LADDERS.prestige.prefix .. tostring(stages.prestige)
    end
    return out
end

local function restoreInitial(param, initial, reason)
    local restored, restoreErr = writeExact(param, initial)
    if not restored then
        return false, tostring(reason) .. "; original passive list also failed to restore: "
            .. tostring(restoreErr)
    end
    return false, reason
end

local function grant(param, ladderName)
    local initial, readErr = PalPassives.capture(param)
    if not initial then return false, readErr end

    local states = resolveNames(initial)
    local selected = states[ladderName]
    local ladder = LADDERS[ladderName]
    local stages = {
        evolved = states.evolved.stage,
        prestige = states.prestige.stage,
    }
    local previousStage = selected.stage
    stages[ladderName] = math.min(previousStage + 1, ladder.maxStage)
    if stages[ladderName] < 1 then stages[ladderName] = 1 end
    local expected = canonicalList(initial, stages)

    if sameList(initial, expected) then
        return true, {
            id = ladder.prefix .. tostring(stages[ladderName]),
            stage = stages[ladderName], previousStage = previousStage,
            changed = false, passives = expected,
        }
    end

    local okList, list = pcall(getPassiveList, param)
    if not okList or list == nil then
        return false, "SaveParameter.PassiveSkillList is unavailable"
    end
    local targetId = ladder.prefix .. tostring(stages[ladderName])
    local okWrite, writeErr
    if selected.index then
        okWrite, writeErr = pcall(writeArrayValue, list, selected.index, targetId)
    else
        okWrite, writeErr = pcall(writeArrayValue, list, #initial + 1, targetId)
    end
    if not okWrite then
        return false, "passive grant failed: " .. tostring(writeErr)
    end

    -- Normal upgrades use the proven in-place replacement above. A duplicate
    -- ladder needs a count-changing rebuild so only one entry can survive.
    if states.evolved.count > 1 or states.prestige.count > 1 then
        local rebuilt, rebuildErr = writeExact(param, expected)
        if not rebuilt then return restoreInitial(param, initial, rebuildErr) end
    else
        local current, currentErr = PalPassives.capture(param)
        if not current then return restoreInitial(param, initial, currentErr) end
        if #current ~= #expected then
            return restoreInitial(param, initial, "passive grant changed the list count unexpectedly")
        end

        -- Locate and order by ID: the Pal's native passives stay first, then
        -- Evolved and Prestige. No slot number is assumed for either ladder.
        for i, id in ipairs(expected) do
            if current[i] ~= id then
                okWrite, writeErr = pcall(writeArrayValue, list, i, id)
                if not okWrite then
                    return restoreInitial(param, initial,
                        string.format("passive ordering write %d failed: %s", i, tostring(writeErr)))
                end
            end
        end
    end

    local verified, verifyErr = PalPassives.verify(param, expected)
    if not verified then return restoreInitial(param, initial, verifyErr) end
    return true, {
        id = targetId, stage = stages[ladderName], previousStage = previousStage,
        changed = true, passives = expected,
    }
end

function PalPassives.grantEvolved(param)
    return grant(param, "evolved")
end

function PalPassives.grantPrestige(param)
    return grant(param, "prestige")
end

return PalPassives
