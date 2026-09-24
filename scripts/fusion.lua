-- fusion.lua: two Pals become one stronger Pal for a fight, then split again.
--
-- The summoned Pal (A) turns into the fused species (C) through the same
-- despawn/swap/respawn as an evolution (Evolution.fusionApi.run with a
-- p.fusion block). The partner (B) stays in the party at 0 HP while the fusion
-- lasts, which the game treats as fainted, so it cannot be summoned twice.
--
-- What C is, is decided in fusionrules.lua: an authored rule, else the fallback
-- formula. What C keeps: the level both Pals' exp adds up to (as an override
-- level, so nothing of it reaches the save), the higher IV and rank per stat,
-- Lucky if either was, and up to four passives by rank. The moves stay A's.
--
-- Everything A was is kept in memory AND in a recovery file before the first
-- write. The split restores it exactly. A game that closes mid-fusion restores
-- both Pals from the file on the next load, before anything else can use them.

local Config = require("config")
local Role = require("role")
local I18n = require("i18n")
local Costs = require("costs")
local Conditions = require("conditions")
local PalPassives = require("palpassives")
local FusionRules = require("fusionrules")
local PASSIVE_RANK = require("passive_rank_static")

local Fusion = {}

local MARKER_ACTIVE = "Palvolve_FusionActive"
local STATE_FILE_NAME = "fusion-active.lua"
local TICK_MS = 500

local function Log(msg)
    print(string.format("[Palvolve] [fusion] %s\n", tostring(msg)))
end

local api = nil          -- Evolution.fusionApi, handed over by Fusion.init
local active = {}        -- A's individual key -> fusion entry
local cooldowns = {}     -- pair key .. "|" .. owner uid -> os.clock() when it runs out
local recoveryPending = true

-- ---------------------------------------------------------------- small reads

local function readNumber(param, field)
    local v = nil
    pcall(function() v = param.SaveParameter[field] end)
    return tonumber(v)
end

local function writeBoth(param, field, value)
    param.SaveParameter[field] = value
    param.SaveParameterMirror[field] = value
end

local function hpOf(param)
    local v = nil
    pcall(function() v = param.SaveParameter.Hp.Value end)
    return tonumber(v) or 0
end

local function setHp(param, value)
    param.SaveParameter.Hp.Value = math.max(0, math.floor(value))
end

local function maxHpOf(param)
    local ok, v = pcall(function() return param:GetMaxHP() end)
    if not ok then return nil end
    if type(v) == "number" then return v * 1000 end
    local okValue, raw = pcall(function() return v.Value end)
    return okValue and tonumber(raw) or nil
end

local function totalExp(level)
    local db = nil
    pcall(function() db = FindFirstOf("BP_PalGameInstance_C").ExpDatabase end)
    if not (db and db:IsValid()) then return nil end
    local ok, v = pcall(function() return db:GetTotalExp(level, false) end)
    return ok and tonumber(v) or nil
end

local STAT_FIELDS = { "Talent_HP", "Talent_Shot", "Talent_Defense",
    "Rank", "Rank_HP", "Rank_Attack", "Rank_Defence", "Rank_CraftSpeed" }

--- Everything the split has to put back on A, read from the save.
local function captureA(param)
    local snap = { stats = {} }
    local okId, rawId = pcall(api.characterId, param)
    if not okId then return nil, "species unreadable: " .. tostring(rawId) end
    snap.rawId = rawId
    for _, field in ipairs(STAT_FIELDS) do
        local v = readNumber(param, field)
        if v == nil then return nil, field .. " unreadable" end
        snap.stats[field] = v
    end
    local rare = nil
    pcall(function() rare = param.SaveParameter.IsRarePal end)
    snap.rare = rare == true
    local passives, passiveErr = PalPassives.capture(param)
    if not passives then return nil, "passives unreadable: " .. tostring(passiveErr) end
    snap.passives = passives
    -- Read now: right after the species is written back, the game still answers
    -- with the fused Pal's maximum until the Pal is summoned again.
    snap.maxHp = maxHpOf(param)
    return snap
end

--- Puts A back exactly as captured. Returns nil, or what did not land.
local function restoreA(param, snap)
    local errs = {}
    local speciesErr = api.writeSpecies(param, snap.rawId)
    if speciesErr then errs[#errs + 1] = speciesErr end
    for field, v in pairs(snap.stats) do
        local ok, err = pcall(writeBoth, param, field, v)
        if not ok then errs[#errs + 1] = field .. ": " .. tostring(err) end
    end
    local okRare, rareErr = pcall(writeBoth, param, "IsRarePal", snap.rare)
    if not okRare then errs[#errs + 1] = "IsRarePal: " .. tostring(rareErr) end
    local okPassives, passiveErr = PalPassives.restore(param, snap.passives)
    if not okPassives then errs[#errs + 1] = "passives: " .. tostring(passiveErr) end
    local okOverride, overrideErr = pcall(function() param:SetOverrideLevel(0) end)
    if not okOverride then errs[#errs + 1] = "override level: " .. tostring(overrideErr) end
    if #errs > 0 then return table.concat(errs, "; ") end
    return nil
end

local function withoutMarker(list)
    local out = {}
    for _, id in ipairs(list or {}) do
        if id ~= MARKER_ACTIVE then out[#out + 1] = id end
    end
    return out
end

local function withMarker(list)
    local out = withoutMarker(list)
    out[#out + 1] = MARKER_ACTIVE
    return out
end

-- ---------------------------------------------------------------- recovery file

local function statePath()
    local dir = Config.stateDir()
    if not dir then return nil end
    return dir .. "\\" .. STATE_FILE_NAME
end

local function serialize(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then return "nil" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
        parts[#parts + 1] = indent .. "  " .. key .. " = " .. serialize(v[k], indent .. "  ")
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

--- Writes every running fusion to disk: to a temp file first, then over the old
--- one, so a crash during the write never leaves half a file behind.
local function saveState()
    local path = statePath()
    if not path then
        Log("[ERROR] no folder for the recovery file; a crash now would leave a fused Pal fused")
        return false
    end
    local records = {}
    for key, e in pairs(active) do
        records[#records + 1] = { aKey = key, bKey = e.bKey, snapA = e.snapA, hpB = e.hpB, maxB = e.maxB }
    end
    if #records == 0 then
        local okRemove = os.remove(path)
        if not okRemove and io.open(path, "r") then
            Log("[WARN] the finished recovery file could not be removed: " .. path)
        end
        return true
    end
    local tmp = path .. ".tmp"
    local f, openErr = io.open(tmp, "wb")
    if not f then
        Log("[ERROR] recovery file not written: " .. tostring(openErr))
        return false
    end
    f:write("return " .. serialize(records) .. "\n")
    f:close()
    os.remove(path)
    local okRename, renameErr = os.rename(tmp, path)
    if not okRename then
        Log("[ERROR] recovery file not moved into place: " .. tostring(renameErr))
        return false
    end
    return true
end

local function loadState()
    local path = statePath()
    if not path then return {} end
    local present = io.open(path, "r")
    if not present then return {} end
    present:close()
    local chunk, loadErr = loadfile(path)
    if not chunk then
        Log("[ERROR] recovery file does not load: " .. tostring(loadErr))
        return {}
    end
    local ok, records = pcall(chunk)
    if not ok or type(records) ~= "table" then
        Log("[ERROR] recovery file did not return a list: " .. tostring(records))
        return {}
    end
    return records
end

local function paramByKey(key)
    for _, p in ipairs(FindAllOf("PalIndividualCharacterParameter") or {}) do
        local ok, k = pcall(api.individualKey, p)
        if ok and k == key then return p end
    end
    return nil
end

-- ---------------------------------------------------------------- the split

local function cooldownKey(e)
    return tostring(e.pairKey) .. "|" .. tostring(e.uid)
end

--- Data-only split: A back to what it was, B back to its own HP share.
--- fraction is C's remaining HP share (0 when C died).
local function splitData(e, fraction)
    local errs = {}
    local paramA, paramB = e.paramA, e.paramB
    if not (paramA and paramA:IsValid()) then paramA = paramByKey(e.aKey) end
    if not (paramB and paramB:IsValid()) then paramB = paramByKey(e.bKey) end
    if paramA then
        local err = restoreA(paramA, e.snapA)
        if err then errs[#errs + 1] = "A: " .. err end
        local maxA = tonumber(e.snapA.maxHp)
        if maxA then
            local okHp, hpErr = pcall(setHp, paramA, maxA * fraction)
            if not okHp then errs[#errs + 1] = "A hp: " .. tostring(hpErr) end
        else
            errs[#errs + 1] = "A max HP was not recorded"
        end
    else
        errs[#errs + 1] = "A not found"
    end
    if paramB then
        local passives = PalPassives.capture(paramB)
        if passives then
            local okB, errB = PalPassives.restore(paramB, withoutMarker(passives))
            if not okB then errs[#errs + 1] = "B marker: " .. tostring(errB) end
        end
        local maxB = tonumber(e.maxB) or e.hpB
        local share = fraction <= 0 and 0 or math.min(e.hpB, maxB * fraction)
        local okHp, hpErr = pcall(setHp, paramB, share)
        if not okHp then errs[#errs + 1] = "B hp: " .. tostring(hpErr) end
    else
        errs[#errs + 1] = "B not found"
    end
    if #errs > 0 then return table.concat(errs, "; ") end
    return nil
end

local function finish(key, e, how)
    active[key] = nil
    cooldowns[cooldownKey(e)] = os.clock() + (Config.fusion.cooldownSeconds or 300)
    saveState()
    Log(string.format("fusion %s ended (%s)", tostring(e.target), how))
    Role.chat(e.playerCtx, I18n.msg("fusionEnded", api.displayName(e.target)), "info")
end

--- Ends one fusion. With C out and alive the split plays like a short
--- evolution back into A; otherwise only the data is put back.
local function separate(key, e, reason)
    if e.splitting then return end
    e.splitting = true
    local paramA = e.paramA
    local hp, maxHp = paramA and hpOf(paramA) or 0, paramA and maxHpOf(paramA) or nil
    local fraction = (maxHp and maxHp > 0) and math.max(0, math.min(1, hp / maxHp)) or 1
    if reason == "fainted" then fraction = 0 end

    local actor = nil
    pcall(function() actor = e.holder:TryGetSpawnedOtomo() end)
    -- by key: UE4SS hands out a fresh userdata per lookup, so == never matches
    local summoned = false
    if actor and actor:IsValid() then
        local okKey, key = pcall(function() return api.individualKey(api.paramOf(actor)) end)
        summoned = okKey and key == e.aKey
    end
    if not summoned or reason == "fainted" or api.busy() then
        local err = splitData(e, fraction)
        if err then Log("[ERROR] split after " .. reason .. " left errors: " .. err) end
        finish(key, e, reason)
        return
    end

    local okId, rawC = pcall(api.characterId, paramA)
    local baseC, isAlphaC = api.baseCharacterId(okId and rawC or e.target)
    local started, why = api.run({
        actor = actor, param = paramA, holder = e.holder, playerCtx = e.playerCtx,
        isAlpha = isAlphaC,
        pair = { from = baseC, to = api.baseCharacterId(e.snapA.rawId), category = "fusion", stone = "none" },
        fusion = {
            kind = "temporary",
            keepHp = true,
            mutate = function() return splitData(e, fraction) end,
            restore = function() return nil end,
            onCommitted = function() finish(key, e, reason) end,
        },
    })
    if not started then
        Log("[WARN] split presentation did not start (" .. tostring(why) .. "), splitting the data only")
        local err = splitData(e, fraction)
        if err then Log("[ERROR] split left errors: " .. err) end
        finish(key, e, reason)
    end
end

-- ---------------------------------------------------------------- the tick

local function recoverFromFile()
    local records = loadState()
    if #records == 0 then return true end
    local pending = 0
    for _, r in ipairs(records) do
        local paramA = paramByKey(r.aKey)
        local paramB = paramByKey(r.bKey)
        if not (paramA and paramB) then
            pending = pending + 1
        else
            local e = { aKey = r.aKey, bKey = r.bKey, snapA = r.snapA, hpB = r.hpB, maxB = r.maxB,
                paramA = paramA, paramB = paramB }
            local err = splitData(e, 1)
            if err then
                Log("[ERROR] a fusion left over from the last session could not be undone fully: " .. err)
            else
                Log(string.format("a fusion left over from the last session was undone (%s)", tostring(r.snapA.rawId)))
            end
        end
    end
    if pending > 0 then return false end
    saveState()
    return true
end

local function tickGameThread()
    if not Role.hasWorldAuthority() then return end
    if recoveryPending then
        local okRecover, done = pcall(recoverFromFile)
        if not okRecover then
            Log("[ERROR] recovery raised: " .. tostring(done))
            recoveryPending = false
        elseif done then
            recoveryPending = false
        end
    end
    local now = os.clock()
    for key, e in pairs(active) do
        if not e.splitting then
            local paramA = e.paramA
            if not (paramA and paramA:IsValid()) then
                Log("[WARN] the fused Pal is gone from memory, splitting from the saved record")
                separate(key, e, "lost")
            elseif hpOf(paramA) <= 0 then
                separate(key, e, "fainted")
            elseif now >= e.endsAt then
                separate(key, e, "time")
            end
        end
    end
end

local function tick()
    ExecuteInGameThread(tickGameThread)
    return false
end

-- ---------------------------------------------------------------- the request

local function reply(playerCtx, key, ...)
    local msg = I18n.msg(key, ...)
    Log(msg)
    Role.chat(playerCtx, msg, "reply")
    return false, msg
end

--- What a battle fusion of A with B would give, without changing anything.
--- Returns target id, source ("rule"|"fallback") and the matching rule, or nil
--- and the i18n key that says why not.
function Fusion.resolveTarget(idA, idB, levelA, levelB, condCtx)
    local unmet = nil
    for _, rule in ipairs(Config.findFusions(idA, idB, "temporary")) do
        if levelA >= rule.minLevel and levelB >= rule.minLevel then
            local ok = true
            if rule.conditions then
                ok = Conditions.evaluate({ conditions = rule.conditions }, condCtx)
            end
            if ok then return rule.to, "rule", rule end
            unmet = unmet or "fusionConditionsUnmet"
        else
            unmet = unmet or "fusionLevelTooLow"
        end
    end
    if unmet then return nil, unmet end
    if not Config.fusion.fallback then return nil, "fusionNoRule" end
    local child = FusionRules.fallback(idA, idB, (Config.fusion.fallbackPercent or 20) / 100)
    if not child then return nil, "fusionNothingStronger" end
    return child, "fallback", nil
end

--- Host entry: fuse the requester's summoned Pal with the Pal in party slot
--- partnerSlot (0-based) for a fight.
function Fusion.startBattle(playerCtx, partnerSlot)
    if not (Config.fusion.enabled and Config.fusion.battleEnabled) then
        return reply(playerCtx, "fusionOff")
    end
    if not api then return reply(playerCtx, "optionUnavailable") end
    if api.busy() then return reply(playerCtx, "evolutionRunning") end
    if not (playerCtx and playerCtx.pc and playerCtx.pc:IsValid()) then
        Log("[WARN] fusion request without a player")
        return false
    end
    local okAuth, hasAuth = pcall(api.hasAuthority, playerCtx.pc)
    if not (okAuth and hasAuth) then
        Log("[WARN] fusion request refused: no host authority")
        return false
    end

    local holder = api.findHolder(playerCtx)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return reply(playerCtx, "noPalSummoned") end
    local paramA = api.paramOf(actor)
    if not (paramA and api.isOwnedBy(paramA, playerCtx.playerUId)) then
        return reply(playerCtx, "noPalSummoned")
    end
    local keyA = api.individualKey(paramA)
    if active[keyA] then return reply(playerCtx, "fusionAlreadyActive") end

    local handleB = nil
    pcall(function() handleB = holder:GetOtomoIndividualHandle(partnerSlot) end)
    local paramB = nil
    if handleB and handleB:IsValid() then pcall(function() paramB = handleB:TryGetIndividualParameter() end) end
    if not (paramB and paramB:IsValid()) then return reply(playerCtx, "fusionNoPartner") end
    local keyB = api.individualKey(paramB)
    if keyB == keyA then return reply(playerCtx, "fusionNoPartner") end
    for _, e in pairs(active) do
        if e.bKey == keyB or e.bKey == keyA then return reply(playerCtx, "fusionAlreadyActive") end
    end
    if hpOf(paramB) <= 0 then return reply(playerCtx, "fusionPartnerFainted") end

    local okA, rawA = pcall(api.characterId, paramA)
    local okB, rawB = pcall(api.characterId, paramB)
    if not (okA and okB) then
        Log("[ERROR] fusion: species unreadable")
        return reply(playerCtx, "optionUnavailable")
    end
    local idA, alphaA = api.baseCharacterId(rawA)
    local idB, alphaB = api.baseCharacterId(rawB)
    local levelA, levelB = 1, 1
    pcall(function() levelA = paramA:GetLevel() end)
    pcall(function() levelB = paramB:GetLevel() end)

    local condCtx = { actor = actor, param = paramA, playerCtx = playerCtx, holder = holder }
    local target, source = Fusion.resolveTarget(idA, idB, levelA, levelB, condCtx)
    if not target then
        return reply(playerCtx, source, api.displayName(idA), api.displayName(idB))
    end

    local pairKey = FusionRules.pairKey(idA, idB)
    local uid = playerCtx.playerUId and string.format("%s-%s-%s-%s",
        tostring(playerCtx.playerUId.A), tostring(playerCtx.playerUId.B),
        tostring(playerCtx.playerUId.C), tostring(playerCtx.playerUId.D)) or "local"
    local cdEnd = cooldowns[pairKey .. "|" .. uid]
    if cdEnd and os.clock() < cdEnd then
        return reply(playerCtx, "fusionCooldown", math.ceil(cdEnd - os.clock()))
    end

    local costList = Costs.resolve({ from = idA, to = target, stone = "fusionShard" }, levelA, holder)
    local costOk, missing = Costs.check(playerCtx, costList)
    if not costOk then return reply(playerCtx, "fusionMissing", Costs.describeMissing(missing)) end

    -- What C becomes, worked out before anything is written.
    local expA, expB = readNumber(paramA, "Exp") or 0, readNumber(paramB, "Exp") or 0
    local expOk = totalExp(1) ~= nil
    local level = math.max(levelA, levelB)
    if expOk then
        level = FusionRules.levelFor(levelA, expA, levelB, expB, function(l) return totalExp(l) or 0 end, 80)
    else
        Log("[WARN] exp table unreadable, the fused Pal keeps the higher level")
    end
    local snapA, snapErr = captureA(paramA)
    if not snapA then
        Log("[ERROR] fusion refused, A could not be captured: " .. tostring(snapErr))
        return reply(playerCtx, "swapStateSnapshotFailed")
    end
    local passivesB = PalPassives.capture(paramB) or {}
    local picked = FusionRules.autoPassives(snapA.passives, passivesB,
        function(id) return PASSIVE_RANK[id] end, 4)
    local markers = FusionRules.mergeMarkers(snapA.passives, passivesB, MARKER_ACTIVE)
    local merged = {}
    for _, field in ipairs(STAT_FIELDS) do
        merged[field] = FusionRules.best(snapA.stats[field], readNumber(paramB, field))
    end
    local rareB = false
    pcall(function() rareB = paramB.SaveParameter.IsRarePal == true end)
    local targetId = target
    if alphaA or alphaB then targetId = "BOSS_" .. target end

    local entry = {
        aKey = keyA, bKey = keyB, paramA = paramA, paramB = paramB, holder = holder,
        playerCtx = playerCtx, uid = uid, pairKey = pairKey, target = target,
        snapA = snapA, hpB = hpOf(paramB), maxB = maxHpOf(paramB),
    }

    local function mutate(param)
        local speciesErr = api.writeSpecies(param, targetId)
        if speciesErr and targetId ~= target then
            -- no Alpha row for this species: the plain form is the next best
            speciesErr = api.writeSpecies(param, target)
        end
        if speciesErr then return speciesErr end
        for field, v in pairs(merged) do
            local ok, err = pcall(writeBoth, param, field, v)
            if not ok then return field .. ": " .. tostring(err) end
        end
        local okRare, rareErr = pcall(writeBoth, param, "IsRarePal", snapA.rare or rareB)
        if not okRare then return "IsRarePal: " .. tostring(rareErr) end
        local list = {}
        for _, id in ipairs(picked) do list[#list + 1] = id end
        for _, id in ipairs(markers) do list[#list + 1] = id end
        list[#list + 1] = MARKER_ACTIVE
        local okPassives, passiveErr = PalPassives.restore(param, list)
        if not okPassives then return "passives: " .. tostring(passiveErr) end
        local okLevel, levelErr = pcall(function() param:SetOverrideLevel(level) end)
        if not okLevel then return "override level: " .. tostring(levelErr) end
        return nil
    end

    -- The record exists before the first write, so a crash from here on is undone.
    active[keyA] = entry
    entry.endsAt = math.huge
    if not saveState() then
        active[keyA] = nil
        return reply(playerCtx, "swapStateSnapshotFailed")
    end
    local okMark, markErr = PalPassives.restore(paramB, withMarker(passivesB))
    if not okMark then Log("[WARN] partner marker not written: " .. tostring(markErr)) end
    local okFaint, faintErr = pcall(setHp, paramB, 0)
    if not okFaint then Log("[WARN] partner could not be taken out of play: " .. tostring(faintErr)) end

    local started, why = api.run({
        actor = actor, param = paramA, holder = holder, playerCtx = playerCtx,
        isAlpha = alphaA, key = keyA,
        pair = { from = idA, to = target, category = "fusion", stone = "fusionShard" },
        fusion = {
            kind = "temporary",
            mutate = mutate,
            restore = function(param) return restoreA(param, snapA) end,
            onCommitted = function()
                entry.endsAt = os.clock() + (Config.fusion.durationSeconds or 60)
                Log(string.format("%s + %s fused into %s (Lv %d, %s) for %ds", idA, idB, target, level,
                    source, Config.fusion.durationSeconds or 60))
                Role.chat(playerCtx, I18n.msg("fusionStarted", api.displayName(idA),
                    api.displayName(idB), api.displayName(target)), "info")
            end,
        },
    })
    if not started then
        -- nothing of A was written; give B back its HP and drop the record
        pcall(setHp, paramB, entry.hpB)
        PalPassives.restore(paramB, passivesB)
        active[keyA] = nil
        saveState()
        return reply(playerCtx, "optionUnavailable")
    end
    return true
end

--- Whether this parameter is half of a running fusion (evolution, prestige and
--- rollback refuse it while it is).
function Fusion.isFused(param)
    if not (api and param) then return false end
    local ok, key = pcall(api.individualKey, param)
    if not ok then return false end
    if active[key] then return true end
    for _, e in pairs(active) do
        if e.bKey == key then return true end
    end
    return false
end

function Fusion.init(evolution)
    api = evolution.fusionApi
    if not api then
        Log("[ERROR] Evolution.fusionApi missing, fusion stays off")
        return
    end
    Fusion._tick = tick   -- held by the module so the scheduled callback is never collected
    LoopAsync(TICK_MS, Fusion._tick)
    Log("fusion ready")
end

return Fusion
