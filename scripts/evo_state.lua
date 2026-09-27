-- Palvolve per-Pal state around an evolution: auto-evolve locks and unlocks,
-- prestige stage and level, and the skin and prestige fields that have to
-- survive a species swap.

local Config = require("config")
local PalPassives = require("palpassives")
local PalSlots = require("palslots")
local Prestige = require("prestige")
local Role = require("role")
local WazaInherit = require("wazainherit")
local EvoUtil = require("evo_util")

local EvoState = {}

local MOD_NAME = "Palvolve"
local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

--- The player's own veto on a single Pal.
---
--- Two levels of protection exist and they answer different people: the tree
--- author decides in the editor which CONNECTIONS may fire on their own, and
--- this decides which PAL is left alone. Narayan's case is the second one - he
--- keeps a particular Pal for its partner skill and does not want to lose it,
--- which is nothing to do with the species.
---
--- The passive is the store, so it survives a restart and is visible in game.
local AutoLock = {}
function AutoLock.isLocked(param)
    if not (param and param:IsValid()) then return false end
    local ok, locked = pcall(PalPassives.isAutoLocked, param)
    return ok and locked == true
end
--- Returns ok, locked. A failure is reported, never swallowed: this is a write
--- to the Pal's passive list and a silent miss would read as "the button does
--- nothing".
function AutoLock.set(param, wanted)
    if not (param and param:IsValid()) then return false, nil end
    local ok, res = pcall(PalPassives.setAutoLock, param, wanted == true)
    if not ok then
        Log("auto-evolve lock failed: " .. tostring(res))
        return false, nil
    end
    if res == false then
        Log("auto-evolve lock could not be written")
        return false, nil
    end
    return true, wanted == true
end
--- Which evolutions a Pal has already earned the right to, this session.
---
--- Keyed by the Pal's own instance id, valued by target species. It lives in
--- memory ONLY and is gone when the game closes, which is the whole point: a
--- passive would cost one of the player's four slots per unlocked target, and a
--- passive cannot name a target anyway - it can say "ready", not "ready for
--- what".
---
--- What it buys: of the mod's 67 conditions the majority are transient
--- (electrified, raining, inCombat, hpLow, night, every region). Without this a
--- player can only act on such a condition if they are standing at the wheel in
--- the second it holds.
local AutoUnlock = {}
local autoUnlocked = {}
local function unlockKeyUnsafe(param)
    return EvoUtil.guidString(param.IndividualId.InstanceId)
end
local function unlockKey(param)
    if not (param and param:IsValid()) then return nil end
    local ok, key = pcall(unlockKeyUnsafe, param)
    if not ok or type(key) ~= "string" or key == "" then return nil end
    return key
end
function AutoUnlock.remember(param, pair)
    local key = unlockKey(param)
    if not key or type(pair) ~= "table" or type(pair.to) ~= "string" then return end
    local set = autoUnlocked[key]
    if not set then set = {}; autoUnlocked[key] = set end
    if set[pair.to] then return end
    set[pair.to] = true
    Log(string.format("auto-evolve: %s unlocked, several ways were open at once", pair.to))
end
--- True once this Pal has met that target's conditions at least once today.
function AutoUnlock.has(param, targetId)
    local key = unlockKey(param)
    if not key or type(targetId) ~= "string" then return false end
    local set = autoUnlocked[key]
    return set ~= nil and set[targetId] == true
end
--- The species changed, so every target the old form had earned is meaningless.
function AutoUnlock.forget(param)
    local key = unlockKey(param)
    if key then autoUnlocked[key] = nil end
end
--- True when this Pal already wears the last prestige rank.
---
--- Without this a Pal at the top can prestige again: the rank is clamped at the
--- ceiling (palpassives.lua, grant), so the Pal pays a Prestige Stone and every
--- level it had for a rank it already carries. The ladder is asked for its own
--- ceiling rather than the number being repeated here.
local function prestigeAtMax(param)
    if not param then return false end
    local okStages, stages = pcall(PalPassives.resolve, param)
    if not okStages or type(stages) ~= "table" then return false end
    local current = stages.prestige and tonumber(stages.prestige.stage) or 0
    local ceiling = tonumber(PalPassives.maxStage("prestige")) or 0
    return ceiling > 0 and current >= ceiling
end
local function isPrestigePair(pair)
    return pair ~= nil and pair.category == "prestige"
end
--- The index a client sends for an option: a prestige pair carries its own
--- prestigeIndex, any other pair is addressed by its position in
--- Config.findPairs, which optionPairsFor keeps at the front of its list.
local function pairIndexFor(pair, position)
    if isPrestigePair(pair) then return pair.prestigeIndex end
    return position
end
--- The pairs a Pal is offered, and whether that offer is prestige alone.
---
--- A Pal that can still evolve is offered its ordinary pairs and nothing else,
--- even while their level or conditions are unmet: prestige is no shortcut
--- around a step that is still ahead. One whose only connections are
--- adaptations is at the end of its line, since an adaptation is the same Pal
--- in another element, so it is offered its adaptations and its prestige side
--- by side. The second value is true only when prestige is all there is; a
--- mixed list is marked per pair instead.
local function optionPairsFor(characterId, param)
    local ordinary = Config.findPairs(characterId)
    if Config.hasProgressPair(characterId) then return ordinary, false end
    local prestige, err = Prestige.forSpecies(Config, characterId)
    if #ordinary == 0 then return prestige, true, err end
    local offered = {}
    for _, pair in ipairs(ordinary) do offered[#offered + 1] = pair end
    if param and prestigeAtMax(param) then return offered, false, err end
    for _, pair in ipairs(prestige) do offered[#offered + 1] = pair end
    return offered, false, err
end
--- The prestige stage a Pal has reached, 0 for none.
local function prestigeStageOf(param)
    if not param then return 0 end
    local okStages, stages = pcall(PalPassives.resolve, param)
    if not okStages or type(stages) ~= "table" then
        Log("[WARN] prestige stage unreadable, counting it as 0: " .. tostring(stages))
        return 0
    end
    return stages.prestige and tonumber(stages.prestige.stage) or 0
end
--- The level a pair asks of this Pal. A prestige asks prestigeMinLevel for its
--- first stage and prestigeLevelStep more for each stage after it, up to 80;
--- without the Pal at hand the first stage's level is the answer.
local function requiredLevelFor(pair, param)
    if pair and pair.category == "prestige" then
        local base = tonumber(Config.prestigeMinLevel) or 1
        local step = tonumber(Config.prestigeLevelStep) or 0
        if step <= 0 or not param then return base end
        return math.min(80, base + step * prestigeStageOf(param))
    end
    return tonumber(pair and pair.minLevel) or 0
end
--- The species is about to change, so every target the old form had earned is
--- meaningless: they belong to a Pal that no longer exists. Called from the one
--- place that writes the species, so no path can forget it.
local function forgetUnlocksFor(param)
    pcall(AutoUnlock.forget, param)
end
local function writeSpeciesUnsafe(param, characterId)
    forgetUnlocksFor(param)
    param.SaveParameter.CharacterID = FName(characterId)
    param.SaveParameterMirror.CharacterID = FName(characterId)
end
local function copyGuidUnsafe(guid)
    return { A = guid.A, B = guid.B, C = guid.C, D = guid.D }
end
local function skinNameUnsafe(value)
    return value:ToString()
end
local function readSkinName(value)
    if type(value) == "string" then return value end
    local okName, name = pcall(skinNameUnsafe, value)
    if okName and name ~= nil then return tostring(name) end
    return nil
end
local function captureSkinStateUnsafe(param)
    local save = param.SaveParameter
    local mirror = param.SaveParameterMirror
    return {
        saveApplied = copyGuidUnsafe(save.SkinAppliedCharacterId),
        saveName = readSkinName(save.SkinName),
        mirrorApplied = copyGuidUnsafe(mirror.SkinAppliedCharacterId),
        mirrorName = readSkinName(mirror.SkinName),
    }
end
local function validGuid(guid)
    return type(guid) == "table" and type(guid.A) == "number"
        and type(guid.B) == "number" and type(guid.C) == "number"
        and type(guid.D) == "number"
end
local function validSkinState(state)
    return type(state) == "table" and validGuid(state.saveApplied)
        and validGuid(state.mirrorApplied) and type(state.saveName) == "string"
        and type(state.mirrorName) == "string"
end
local function captureSkinState(param)
    local okState, state = pcall(captureSkinStateUnsafe, param)
    if not okState or not validSkinState(state) then
        return nil, okState and "skin fields are unavailable" or tostring(state)
    end
    return state
end
local function writeSkinStateUnsafe(param, state)
    param.SaveParameter.SkinAppliedCharacterId = copyGuidUnsafe(state.saveApplied)
    param.SaveParameter.SkinName = FName(state.saveName)
    param.SaveParameterMirror.SkinAppliedCharacterId = copyGuidUnsafe(state.mirrorApplied)
    param.SaveParameterMirror.SkinName = FName(state.mirrorName)
end
local function sameGuid(left, right)
    return left.A == right.A and left.B == right.B
        and left.C == right.C and left.D == right.D
end
local function skinStateMatchesUnsafe(param, expected)
    local actual = captureSkinStateUnsafe(param)
    return validSkinState(actual) and sameGuid(actual.saveApplied, expected.saveApplied)
        and actual.saveName == expected.saveName
        and sameGuid(actual.mirrorApplied, expected.mirrorApplied)
        and actual.mirrorName == expected.mirrorName
end
local function writeSkinState(param, state)
    if not validSkinState(state) then return false, "skin snapshot is invalid" end
    local okWrite, writeErr = pcall(writeSkinStateUnsafe, param, state)
    if not okWrite then return false, tostring(writeErr) end
    local okVerify, matches = pcall(skinStateMatchesUnsafe, param, state)
    if not okVerify or not matches then return false, "skin field read-back differs" end
    return true
end
local EMPTY_SKIN = {
    saveApplied = { A = 0, B = 0, C = 0, D = 0 }, saveName = "None",
    mirrorApplied = { A = 0, B = 0, C = 0, D = 0 }, mirrorName = "None",
}
local function applySwapSurvivors(param, skinState, wazaState)
    if skinState then
        local skinOk, skinErr = writeSkinState(param, EMPTY_SKIN)
        if not skinOk then return false, "skin clear failed: " .. tostring(skinErr) end
    end
    if wazaState then
        local wazaOk, wazaResult = WazaInherit.apply(param, wazaState, Config.moveInheritance)
        if not wazaOk then return false, "move inheritance failed: " .. tostring(wazaResult) end
        if (wazaResult.removedEquip or 0) > 0 or (wazaResult.removedMastered or 0) > 0 then
            Log(string.format("Move inheritance dropped %d equipped and %d mastered Unique moves",
                wazaResult.removedEquip or 0, wazaResult.removedMastered or 0))
        end
        if wazaResult.knownError then
            Log("Move inheritance could not read the known move list, carrying the equipped ones only: "
                .. tostring(wazaResult.knownError))
        elseif wazaResult.knownCount then
            Log(string.format("Move inheritance carries %d known move(s)", wazaResult.knownCount))
        end
        if wazaResult.teachError then
            -- The evolution stands; only the repertoire half of it did not.
            Log("Move inheritance could not write the repertoire: " .. tostring(wazaResult.teachError))
        elseif (wazaResult.taught or 0) > 0 then
            -- The count is entries written, and both save halves are written, so
            -- it reads as double the moves unless the detail is right next to it.
            Log(string.format("Move inheritance taught %d repertoire entr(ies) [%s]",
                wazaResult.taught, tostring(wazaResult.teachDetail)))
        end
        if (wazaResult.cleared or 0) > 0 then
            Log(string.format("Move inheritance removed %d empty mastered entr(ies)", wazaResult.cleared))
        end
    end
    return true
end
local function restoreSwapSurvivors(param, skinState, wazaState)
    local errors = {}
    if skinState then
        local skinOk, skinErr = writeSkinState(param, skinState)
        if not skinOk then errors[#errors + 1] = "skin=" .. tostring(skinErr) end
    end
    if wazaState then
        local wazaOk, wazaErr, wazaNote = WazaInherit.restore(param, wazaState)
        if not wazaOk then errors[#errors + 1] = "moves=" .. tostring(wazaErr) end
        if wazaNote then Log("Move lists restored: " .. wazaNote) end
    end
    if #errors > 0 then return false, table.concat(errors, "; ") end
    return true
end
local function readPrestigeFieldsUnsafe(param)
    return {
        -- raw on purpose: written back as read, compared through Config.canonicalId
        characterId = param:GetCharacterID():ToString(),
        level = param.SaveParameter.Level,
        exp = param.SaveParameter.Exp,
        mirrorLevel = param.SaveParameterMirror.Level,
        mirrorExp = param.SaveParameterMirror.Exp,
    }
end
local function writePrestigeLevelUnsafe(param, level, exp, mirrorLevel, mirrorExp)
    param.SaveParameter.Level = level
    param.SaveParameter.Exp = exp
    param.SaveParameterMirror.Level = mirrorLevel
    param.SaveParameterMirror.Exp = mirrorExp
end
local function prestigeFieldsMatchUnsafe(param, state)
    return Config.canonicalId(param:GetCharacterID():ToString())
            == Config.canonicalId(state.characterId)
        and tonumber(param.SaveParameter.Level) == tonumber(state.level)
        and tostring(param.SaveParameter.Exp) == tostring(state.exp)
        and tonumber(param.SaveParameterMirror.Level) == tonumber(state.mirrorLevel)
        and tostring(param.SaveParameterMirror.Exp) == tostring(state.mirrorExp)
end
local function capturePrestigeState(param)
    local okFields, state = pcall(readPrestigeFieldsUnsafe, param)
    if not okFields or type(state) ~= "table" then
        return nil, "level and experience fields are unavailable"
    end
    local passives, passiveErr = PalPassives.capture(param)
    if not passives then return nil, passiveErr end
    state.passives = passives
    return state
end
local function restorePrestigeState(param, state)
    local okSpecies, speciesErr = pcall(writeSpeciesUnsafe, param, state.characterId)
    local okLevel, levelErr = pcall(writePrestigeLevelUnsafe, param,
        state.level, state.exp, state.mirrorLevel, state.mirrorExp)
    local okPassives, passiveErr = PalPassives.restore(param, state.passives)
    local okVerify, matches = pcall(prestigeFieldsMatchUnsafe, param, state)
    if okSpecies and okLevel and okPassives and okVerify and matches then return true end
    return false, string.format("species=%s levelExp=%s passives=%s verify=%s (%s; %s; %s)",
        tostring(okSpecies), tostring(okLevel), tostring(okPassives), tostring(okVerify and matches),
        tostring(speciesErr), tostring(levelErr), tostring(passiveErr))
end
--- Says what the bonus slot did, in every outcome.
---
--- It said nothing in two of the three. PalSlots answers "true, changed=false"
--- when the Pal already has four moves, and again when nothing in its learned
--- pool is left to promote - both perfectly ordinary, both indistinguishable
--- from the setting having no effect at all. It even built the sentence for the
--- player, in all 17 languages, and neither caller ever sent it. A reporter
--- switched the option on, evolved, counted three slots and had nothing to go
--- on; so did the next person to look at the log.
local function reportBonusSlot(playerCtx, ok, result, what)
    if not ok then
        Log(string.format("%s bonus slot FAILED: %s", what, tostring(result)))
        return
    end
    if type(result) ~= "table" then
        Log(string.format("%s bonus slot returned no result", what))
        return
    end
    if result.mode == "off" then return end
    if result.changed then
        Log(string.format("%s bonus slot: granted %s (waza %s)",
            what, tostring(result.wazaName), tostring(result.wazaId)))
    else
        Log(string.format("%s bonus slot: nothing to grant (%d move(s) equipped)",
            what, type(result.activeMoves) == "table" and #result.activeMoves or -1))
    end
    if result.message and playerCtx then
        -- Role.chat logs its own refusals and returns false; this catches an
        -- outright error, which would otherwise leave the player told nothing
        -- under a log line that says the slot was handled.
        local sent, sendErr = pcall(function() Role.chat(playerCtx, result.message, "reply") end)
        if not sent then
            Log(string.format("%s bonus slot message not sent: %s", what, tostring(sendErr)))
        end
    end
end
--- playerCtx is a PARAMETER, not an upvalue. It used to read an undeclared
--- global here, so PalSlots.grantPrestige always got nil and the fourth move
--- slot a prestige is supposed to hand out was never granted to anybody.
local function applyPrestigeMutation(param, targetId, playerCtx)
    local okSpecies, speciesErr = pcall(writeSpeciesUnsafe, param, targetId)
    local idNow = nil
    local okId, readId = pcall(EvoUtil.characterIdUnsafe, param)
    if okId then idNow = readId end
    if not okSpecies or Config.canonicalId(idNow) ~= Config.canonicalId(targetId) then
        return false, "species write failed: " .. tostring(speciesErr)
    end

    local okLevel, levelErr = pcall(writePrestigeLevelUnsafe, param, 1, 0, 1, 0)
    if not okLevel then return false, "level/experience write failed: " .. tostring(levelErr) end
    local expected = {
        characterId = targetId, level = 1, exp = 0, mirrorLevel = 1, mirrorExp = 0,
    }
    local okVerify, fieldsMatch = pcall(prestigeFieldsMatchUnsafe, param, expected)
    if not okVerify or not fieldsMatch then return false, "level/experience read-back differs" end

    local passiveOk, passiveResult = PalPassives.grantPrestige(param)
    if not passiveOk then return false, "Prestige passive write failed: " .. tostring(passiveResult) end
    -- Optional and off by default. A failure here does not fail the prestige:
    -- the rank is already written, and refusing it over a bonus nobody asked
    -- for would cost the player the thing they did ask for.
    local slotOk, slotResult = PalSlots.grantPrestige(param, playerCtx)
    reportBonusSlot(playerCtx, slotOk, slotResult, "Prestige")
    return true, passiveResult
end

EvoState.AutoLock = AutoLock
EvoState.AutoUnlock = AutoUnlock
EvoState.autoUnlocked = autoUnlocked
EvoState.unlockKeyUnsafe = unlockKeyUnsafe
EvoState.unlockKey = unlockKey
EvoState.prestigeAtMax = prestigeAtMax
EvoState.isPrestigePair = isPrestigePair
EvoState.pairIndexFor = pairIndexFor
EvoState.optionPairsFor = optionPairsFor
EvoState.prestigeStageOf = prestigeStageOf
EvoState.requiredLevelFor = requiredLevelFor
EvoState.forgetUnlocksFor = forgetUnlocksFor
EvoState.writeSpeciesUnsafe = writeSpeciesUnsafe
EvoState.copyGuidUnsafe = copyGuidUnsafe
EvoState.skinNameUnsafe = skinNameUnsafe
EvoState.readSkinName = readSkinName
EvoState.captureSkinStateUnsafe = captureSkinStateUnsafe
EvoState.validGuid = validGuid
EvoState.validSkinState = validSkinState
EvoState.captureSkinState = captureSkinState
EvoState.writeSkinStateUnsafe = writeSkinStateUnsafe
EvoState.sameGuid = sameGuid
EvoState.skinStateMatchesUnsafe = skinStateMatchesUnsafe
EvoState.writeSkinState = writeSkinState
EvoState.EMPTY_SKIN = EMPTY_SKIN
EvoState.applySwapSurvivors = applySwapSurvivors
EvoState.restoreSwapSurvivors = restoreSwapSurvivors
EvoState.readPrestigeFieldsUnsafe = readPrestigeFieldsUnsafe
EvoState.writePrestigeLevelUnsafe = writePrestigeLevelUnsafe
EvoState.prestigeFieldsMatchUnsafe = prestigeFieldsMatchUnsafe
EvoState.capturePrestigeState = capturePrestigeState
EvoState.restorePrestigeState = restorePrestigeState
EvoState.reportBonusSlot = reportBonusSlot
EvoState.applyPrestigeMutation = applyPrestigeMutation

return EvoState
