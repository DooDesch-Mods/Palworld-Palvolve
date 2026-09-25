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
local GameLoop = require("gameloop")
local I18n = require("i18n")
local Costs = require("costs")
local Conditions = require("conditions")
local PalPassives = require("palpassives")
local FusionRules = require("fusionrules")
local FusionPartner = require("fusionpartner")
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
local starting = {}      -- individual keys of both Pals while the partner steps out
local recoveryPending = true
-- Fusions that ended in this session. The game's save on disk can still hold
-- the fused state until its next autosave, so their records stay in the
-- recovery file; the next load undoes the ones whose Pal still carries the
-- fusion marker and drops the rest.
local settled = {}
local SETTLED_KEEP = 20
-- records the recovery could not match in this world (another world's Pals)
local carried = {}
local RECOVERY_GIVE_UP_S = 120
local recoveryStartedAt = nil
local recoverySkipLogged = {} -- A's key -> true once the skip was logged

-- ---------------------------------------------------------------- small reads

--- IsValid without raising. A plain pcall around a UFunction call does not
--- guard a freed object; this check before the call does.
local function isLive(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function readNumber(param, field)
    local ok, v = pcall(function() return param.SaveParameter[field] end)
    if not ok then
        Log("[WARN] " .. tostring(field) .. " unreadable: " .. tostring(v))
        return nil
    end
    return tonumber(v)
end

local function writeBoth(param, field, value)
    param.SaveParameter[field] = value
    param.SaveParameterMirror[field] = value
end

--- HP (fixed point, x1000) and whether it could be read at all. An unreadable
--- HP counts as 0 for the checks that refuse a fusion, but never as a faint.
local function hpOf(param)
    local ok, v = pcall(function() return param.SaveParameter.Hp.Value end)
    if not ok then
        Log("[WARN] HP unreadable: " .. tostring(v))
        return 0, false
    end
    return tonumber(v) or 0, true
end

local function levelOf(param)
    local ok, v = pcall(function() return param:GetLevel() end)
    if not ok or tonumber(v) == nil then
        Log("[WARN] level unreadable, counting it as 1: " .. tostring(v))
        return 1
    end
    return tonumber(v)
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
    local okRare, rare = pcall(function() return param.SaveParameter.IsRarePal end)
    if not okRare then return nil, "IsRarePal unreadable: " .. tostring(rare) end
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
    for _, r in ipairs(settled) do records[#records + 1] = r end
    for _, r in ipairs(carried) do records[#records + 1] = r end
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

local function recoveryFileExists()
    local path = statePath()
    if not path then return false end
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
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
    if not isLive(paramA) then paramA = paramByKey(e.aKey) end
    if not isLive(paramB) then paramB = paramByKey(e.bKey) end
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
        local passives, captureErr = PalPassives.capture(paramB)
        if passives then
            local okB, errB = PalPassives.restore(paramB, withoutMarker(passives))
            if not okB then errs[#errs + 1] = "B marker: " .. tostring(errB) end
        else
            errs[#errs + 1] = "B passives unreadable, marker left: " .. tostring(captureErr)
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

-- ---------------------------------------------------------------- invulnerability

-- The fused Pal cannot be hit while the fusion or the split plays, and for a
-- moment after the new body appears. One muteki flag of our own, so the game's
-- own reasons for invulnerability are left alone.
local MUTEKI_FLAG = "PalvolveFusion"
local guards = {} -- holder address -> { holder, untilT }

local function setMuteki(actor, on)
    if not isLive(actor) then return end
    local ok, err = pcall(function() actor.CharacterParameterComponent:SetMuteki(FName(MUTEKI_FLAG), on) end)
    if not ok then Log("[WARN] invulnerability " .. (on and "on" or "off") .. " failed: " .. tostring(err)) end
end

local function holderKey(holder)
    local ok, addr = pcall(function() return holder:GetAddress() end)
    return ok and addr or tostring(holder)
end

--- The Pal the holder has out, or nil. The holder dies with the world or with
--- a player who leaves, so it is checked before the call.
local function spawnedOf(holder)
    if not isLive(holder) then return nil end
    local ok, actor = pcall(function() return holder:TryGetSpawnedOtomo() end)
    if not ok then
        Log("[WARN] summoned Pal unreadable: " .. tostring(actor))
        return nil
    end
    return actor
end

--- Makes the Pal the holder has out invulnerable for `seconds` (the timer
--- restarts, so calling it again after the swap covers the new body).
local function protect(holder, seconds)
    if not isLive(holder) then return end
    setMuteki(spawnedOf(holder), true)
    guards[holderKey(holder)] = { holder = holder, untilT = os.clock() + seconds }
end

local function release(holder)
    if not holder then return end
    setMuteki(spawnedOf(holder), false)
    guards[holderKey(holder)] = nil
end

local function expireGuards(now)
    for key, g in pairs(guards) do
        if now >= g.untilT then
            guards[key] = nil
            setMuteki(spawnedOf(g.holder), false)
        end
    end
end

--- Keeps the record of a fusion that just ended, for the next load to check.
local function settle(e)
    for i = #settled, 1, -1 do
        if settled[i].aKey == e.aKey then table.remove(settled, i) end
    end
    settled[#settled + 1] = { aKey = e.aKey, bKey = e.bKey, snapA = e.snapA, hpB = e.hpB, maxB = e.maxB,
        settled = true }
    while #settled > SETTLED_KEEP do table.remove(settled, 1) end
end

local function finish(key, e, how)
    settle(e)
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
    local live = isLive(paramA)
    local hp, maxHp = live and hpOf(paramA) or 0, live and maxHpOf(paramA) or nil
    local fraction = (maxHp and maxHp > 0) and math.max(0, math.min(1, hp / maxHp)) or 1
    if reason == "fainted" then fraction = 0 end
    e.splitFraction, e.splitReason = fraction, reason

    local actor = spawnedOf(e.holder)
    -- by key: UE4SS hands out a fresh userdata per lookup, so == never matches
    local summoned = false
    if isLive(actor) then
        local okKey, key = pcall(function() return api.individualKey(api.paramOf(actor)) end)
        summoned = okKey and key == e.aKey
    end
    if not summoned or reason == "fainted" or api.busy() then
        local err = splitData(e, fraction)
        if err then Log("[ERROR] split after " .. reason .. " left errors: " .. err) end
        -- A fainted C whose body is still out would keep C's look over A's
        -- data; back into the ball, the next summon spawns A.
        if summoned and reason == "fainted" then
            local okOff, errOff = pcall(function() e.holder:InactivateCurrentOtomo() end)
            if not okOff then Log("[WARN] the fainted fused Pal could not be recalled: " .. tostring(errOff)) end
        end
        finish(key, e, reason)
        return
    end

    local okId, rawC = pcall(api.characterId, paramA)
    local baseC, isAlphaC = api.baseCharacterId(okId and rawC or e.target)
    protect(e.holder, 10)
    local started, why = api.run({
        actor = actor, param = paramA, holder = e.holder, playerCtx = e.playerCtx,
        isAlpha = isAlphaC,
        pair = { from = baseC, to = api.baseCharacterId(e.snapA.rawId), category = "fusion", stone = "none" },
        fusion = {
            kind = "temporary",
            keepHp = true,
            mutate = function() return splitData(e, fraction) end,
            restore = function() return nil end,
            onCommitted = function()
                protect(e.holder, 1.5)
                finish(key, e, reason)
            end,
        },
    })
    if not started then
        release(e.holder)
        Log("[WARN] split presentation did not start (" .. tostring(why) .. "), splitting the data only")
        local err = splitData(e, fraction)
        if err then Log("[ERROR] split left errors: " .. err) end
        finish(key, e, reason)
        return
    end
    -- the tick finishes the split from the data if the run ends before its swap
    e.splitRunning = true
end

--- Takes back a fusion whose start never reached the swap: the run ended
--- early, so B gets its HP and its markers back and A is only restored if
--- the rewrite had begun.
local function undoStart(key, e, why)
    local errs = {}
    if isLive(e.paramA) then
        local passivesA = PalPassives.capture(e.paramA)
        local marked = false
        for _, id in ipairs(passivesA or {}) do
            if id == MARKER_ACTIVE then marked = true end
        end
        if marked or not passivesA then
            local err = restoreA(e.paramA, e.snapA)
            if err then errs[#errs + 1] = "A: " .. err end
        end
    else
        errs[#errs + 1] = "A not found"
    end
    if isLive(e.paramB) then
        local passivesB, captureErr = PalPassives.capture(e.paramB)
        if passivesB then
            local okB, errB = PalPassives.restore(e.paramB, withoutMarker(passivesB))
            if not okB then errs[#errs + 1] = "B marker: " .. tostring(errB) end
        else
            errs[#errs + 1] = "B passives unreadable, marker left: " .. tostring(captureErr)
        end
        local okHp, hpErr = pcall(setHp, e.paramB, e.hpB)
        if not okHp then errs[#errs + 1] = "B hp: " .. tostring(hpErr) end
    else
        errs[#errs + 1] = "B not found"
    end
    release(e.holder)
    settle(e)
    active[key] = nil
    saveState()
    if #errs > 0 then
        Log("[ERROR] fusion of " .. tostring(e.target) .. " taken back (" .. why .. ") with errors: "
            .. table.concat(errs, "; "))
    else
        Log("fusion of " .. tostring(e.target) .. " taken back (" .. why .. ")")
    end
end

-- ---------------------------------------------------------------- the tick

local function carriesMarker(param)
    local passives = PalPassives.capture(param)
    if not passives then return nil end
    for _, id in ipairs(passives) do
        if id == MARKER_ACTIVE then return true end
    end
    return false
end

local function recoverFromFile()
    local records = loadState()
    if #records == 0 then return true end
    recoveryStartedAt = recoveryStartedAt or os.clock()
    local giveUp = os.clock() - recoveryStartedAt > RECOVERY_GIVE_UP_S
    local pending = 0
    local keep = {}
    for _, r in ipairs(records) do
        -- A record of a fusion running in this session (written while an older
        -- record still waited for its world) is live, not left over.
        local running = active[r.aKey] ~= nil
        local ownSettled = false
        for _, s2 in ipairs(settled) do
            if s2.aKey == r.aKey then ownSettled = true end
        end
        local paramA = not (running or ownSettled) and paramByKey(r.aKey) or nil
        local paramB = not (running or ownSettled) and paramByKey(r.bKey) or nil
        if running or ownSettled then
            if not recoverySkipLogged[r.aKey] then
                recoverySkipLogged[r.aKey] = true
                Log("[INFO] recovery skips the record of a fusion from this session")
            end
        elseif not (paramA and paramB) then
            if giveUp then
                keep[#keep + 1] = r
            else
                pending = pending + 1
            end
        else
            local markedA, markedB = carriesMarker(paramA), carriesMarker(paramB)
            local e = { aKey = r.aKey, bKey = r.bKey, snapA = r.snapA, hpB = r.hpB, maxB = r.maxB,
                paramA = paramA, paramB = paramB }
            if r.settled and markedA == false and markedB == false then
                Log(string.format("[INFO] a fusion that ended last session is already saved as split (%s)",
                    tostring(r.snapA and r.snapA.rawId)))
            elseif r.settled and markedA == false then
                -- A is back, only B still carries the fusion: give B its HP and drop the marker
                local passivesB, captureErr = PalPassives.capture(paramB)
                local okB, errB = false, "passives unreadable, marker left: " .. tostring(captureErr)
                if passivesB then okB, errB = PalPassives.restore(paramB, withoutMarker(passivesB)) end
                local okHp, hpErr = pcall(setHp, paramB, r.hpB)
                if okB and okHp then
                    Log("a partner left over from the last session was given back")
                else
                    Log("[ERROR] a partner left over from the last session was not fully given back: "
                        .. tostring(errB) .. "; " .. tostring(hpErr))
                end
            else
                local err = splitData(e, 1)
                if err then
                    Log("[ERROR] a fusion left over from the last session could not be undone fully: " .. err)
                else
                    Log(string.format("a fusion left over from the last session was undone (%s)%s",
                        tostring(r.snapA and r.snapA.rawId),
                        r.settled and ", the save was older than its split" or ""))
                end
            end
        end
    end
    if pending > 0 then return false end
    if #keep > 0 then
        Log(string.format("[WARN] %d fusion record(s) belong to Pals that are not in this world; they stay in the recovery file", #keep))
    end
    carried = keep
    saveState()
    return true
end

-- A fused Pal whose parameter is gone from memory: the world closed, or its
-- owner left. Its record, and with it the recovery file, stays until both Pals
-- are loaded again; only then is anything written.
local LOST_RETRY_S = 5
local function tickLost(key, e, now)
    if now < (e.nextLookup or 0) then return end
    e.nextLookup = now + LOST_RETRY_S
    local paramA, paramB = paramByKey(e.aKey), paramByKey(e.bKey)
    if not (paramA and paramB) then
        if not e.lostLogged then
            e.lostLogged = true
            Log("[WARN] a fused Pal is gone from memory; its record waits until both Pals are loaded again")
        end
        return
    end
    Log("[WARN] the fused Pal is back in memory, splitting it from the saved record")
    -- the holder and the running presentation belonged to the old world
    e.paramA, e.paramB, e.holder = paramA, paramB, nil
    e.splitting, e.splitRunning = false, false
    if e.endsAt == math.huge then
        undoStart(key, e, "lost before it started")
    else
        separate(key, e, "lost")
    end
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
    expireGuards(now)
    for key, e in pairs(active) do
        -- a presentation that ended without reaching its swap (aborted, or the
        -- sequence watchdog) never calls back, so the tick notices it here
        local runEnded = not api.busy()
        if not isLive(e.paramA) then
            if not e.splitRunning or runEnded then tickLost(key, e, now) end
        elseif e.splitRunning then
            if runEnded then
                e.splitRunning = false
                Log("[WARN] the split presentation ended before the swap, splitting the data only")
                local err = splitData(e, e.splitFraction or 1)
                if err then Log("[ERROR] split left errors: " .. err) end
                finish(key, e, e.splitReason or "time")
            end
        elseif not e.splitting then
            if e.endsAt == math.huge then
                if runEnded then undoStart(key, e, "the presentation ended before the swap") end
            else
                local hp, hpKnown = hpOf(e.paramA)
                if hpKnown and hp <= 0 then
                    separate(key, e, "fainted")
                elseif now >= e.endsAt then
                    separate(key, e, "time")
                end
            end
        end
    end
end

-- Runs on the game thread (gameloop.lua); an idle tick returns at once.
local function tick()
    if recoveryPending and not recoveryFileExists() then
        recoveryPending = false
    end
    if not recoveryPending and next(active) == nil and next(guards) == nil then return false end
    tickGameThread()
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
    local actor = spawnedOf(holder)
    if not isLive(actor) then return reply(playerCtx, "noPalSummoned") end
    local paramA = api.paramOf(actor)
    if not (paramA and api.isOwnedBy(paramA, playerCtx.playerUId)) then
        return reply(playerCtx, "noPalSummoned")
    end
    local keyA = api.individualKey(paramA)
    if active[keyA] or starting[keyA] then return reply(playerCtx, "fusionAlreadyActive") end

    local paramB, handleB = nil, nil
    local okSlot, slotErr = pcall(function()
        handleB = holder:GetOtomoIndividualHandle(partnerSlot)
        if handleB and handleB:IsValid() then paramB = handleB:TryGetIndividualParameter() end
    end)
    if not okSlot then Log("[WARN] party slot " .. tostring(partnerSlot) .. " unreadable: " .. tostring(slotErr)) end
    if not isLive(paramB) then return reply(playerCtx, "fusionNoPartner") end
    local keyB = api.individualKey(paramB)
    if keyB == keyA then return reply(playerCtx, "fusionNoPartner") end
    -- B can be the fused half of another fusion, recalled into its ball
    if active[keyB] or starting[keyB] then return reply(playerCtx, "fusionAlreadyActive") end
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
    local levelA, levelB = levelOf(paramA), levelOf(paramB)

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
    local okRareB, rawRareB = pcall(function() return paramB.SaveParameter.IsRarePal end)
    if not okRareB then Log("[WARN] partner's Lucky flag unreadable, counting it as not Lucky: " .. tostring(rawRareB)) end
    local rareB = okRareB and rawRareB == true
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

    -- Everything below writes. It runs once B has stepped out next to A, so the
    -- partner still has its HP while its body is on screen.
    local function begin()
        starting[keyA], starting[keyB] = nil, nil
        -- A can be recalled or swapped while B shows itself
        local now = spawnedOf(holder)
        local nowParam = isLive(now) and api.paramOf(now) or nil
        if not (nowParam and api.individualKey(nowParam) == keyA) then
            Log("[WARN] fusion stopped: the summoned Pal changed while the partner stepped out")
            release(holder)
            return reply(playerCtx, "noPalSummoned")
        end
        actor = now
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

        protect(holder, 10)
        local started, why = api.run({
            actor = actor, param = paramA, holder = holder, playerCtx = playerCtx,
            isAlpha = alphaA, key = keyA,
            pair = { from = idA, to = target, category = "fusion", stone = "fusionShard" },
            fusion = {
                kind = "temporary",
                mutate = mutate,
                restore = function(param) return restoreA(param, snapA) end,
                onCommitted = function()
                    protect(holder, 1.5)
                    entry.endsAt = os.clock() + (Config.fusion.durationSeconds or 60)
                    Log(string.format("%s + %s fused into %s (Lv %d, %s) for %ds", idA, idB, target, level,
                        source, Config.fusion.durationSeconds or 60))
                    Role.chat(playerCtx, I18n.msg("fusionStarted", api.displayName(idA),
                        api.displayName(idB), api.displayName(target)), "info")
                end,
            },
        })
        if not started then
            release(holder)
            Log("[WARN] fusion presentation did not start: " .. tostring(why))
            -- nothing of A was written; give B back its HP and drop the record
            local okHp, hpErr = pcall(setHp, paramB, entry.hpB)
            if not okHp then Log("[ERROR] partner HP not given back: " .. tostring(hpErr)) end
            local okBack, backErr = PalPassives.restore(paramB, passivesB)
            if not okBack then Log("[ERROR] partner marker not removed: " .. tostring(backErr)) end
            active[keyA] = nil
            if not saveState() then Log("[ERROR] recovery file not cleared after the refused start") end
            return reply(playerCtx, "optionUnavailable")
        end
    end

    starting[keyA], starting[keyB] = true, true
    protect(holder, 10)
    local shown, showWhy = FusionPartner.play({
        worldCtx = playerCtx.pc, actorA = actor, handleB = handleB, paramB = paramB, idB = idB,
        freeze = api.freeze,
        onDone = function(wasShown)
            if not wasShown then Log("[INFO] the partner was not shown, the fusion goes on without it") end
            local ok, err = pcall(begin)
            if not ok then
                starting[keyA], starting[keyB] = nil, nil
                Log("[ERROR] fusion start failed after the partner scene: " .. tostring(err))
                Role.chat(playerCtx, I18n.msg("optionUnavailable"), "reply")
            end
        end,
    })
    if not shown then
        Log("[WARN] partner scene did not start (" .. tostring(showWhy) .. "), fusing without it")
        local okBegin, beginMsg = begin()
        if okBegin == false then return false, beginMsg end
    end
    return true
end

--- Wheel entries for the summoned Pal: one per party partner, with what the
--- fusion gives or why it is closed. Reads only; the host checks everything
--- again when the entry is picked.
function Fusion.wheelOptions(playerCtx, holder, paramA)
    local out = {}
    if not (Config.fusion.enabled and Config.fusion.battleEnabled) then return out end
    if not (api and holder and paramA) then
        Log("[WARN] fusion wheel entries skipped: " .. (api and "no holder or Pal" or "not set up"))
        return out
    end
    local okA, rawA = pcall(api.characterId, paramA)
    if not okA then
        Log("[WARN] fusion wheel entries skipped: species unreadable")
        return out
    end
    local idA = api.baseCharacterId(rawA)
    local nameA = api.displayName(idA)
    local keyA = api.individualKey(paramA)
    local levelA = levelOf(paramA)
    local uid = playerCtx and playerCtx.playerUId and string.format("%s-%s-%s-%s",
        tostring(playerCtx.playerUId.A), tostring(playerCtx.playerUId.B),
        tostring(playerCtx.playerUId.C), tostring(playerCtx.playerUId.D)) or "local"
    for slot = 0, 4 do
        local paramB = nil
        local okSlot, slotErr = pcall(function()
            local h = holder:GetOtomoIndividualHandle(slot)
            if h and h:IsValid() then paramB = h:TryGetIndividualParameter() end
        end)
        if not okSlot then Log("[WARN] fusion wheel: party slot " .. slot .. " unreadable: " .. tostring(slotErr)) end
        if paramB and paramB:IsValid() and api.individualKey(paramB) ~= keyA then
            local okB, rawB = pcall(api.characterId, paramB)
            if okB then
                local idB = api.baseCharacterId(rawB)
                local nameB = api.displayName(idB)
                local opt = { fusion = "battle", partnerSlot = slot, index = slot + 1,
                    label = I18n.msg("fusionWithShort", nameB) }
                local levelB = levelOf(paramB)
                if active[keyA] or Fusion.isFused(paramB) then
                    opt.blocked = I18n.msg("fusionAlreadyActive")
                elseif hpOf(paramB) <= 0 then
                    opt.blocked = I18n.msg("fusionPartnerFainted")
                else
                    local condCtx = { param = paramA, playerCtx = playerCtx, holder = holder }
                    local target, why = Fusion.resolveTarget(idA, idB, levelA, levelB, condCtx)
                    if not target then
                        opt.blocked = I18n.msg(why, nameA, nameB)
                    else
                        local cdEnd = cooldowns[FusionRules.pairKey(idA, idB) .. "|" .. uid]
                        local costList = Costs.resolve({ from = idA, to = target, stone = "fusionShard" }, levelA, holder)
                        local costOk, missing = Costs.check(playerCtx, costList)
                        if cdEnd and os.clock() < cdEnd then
                            opt.blocked = I18n.msg("fusionCooldown", math.ceil(cdEnd - os.clock()))
                        elseif not costOk then
                            opt.blocked = I18n.msg("fusionMissing", Costs.describeMissing(missing))
                        else
                            opt.requirement = I18n.msg("fusionIntoShort", api.displayName(target),
                                Config.fusion.durationSeconds or 60)
                        end
                    end
                end
                opt.requirement = opt.requirement or opt.blocked
                out[#out + 1] = opt
            else
                Log("[WARN] fusion wheel: partner in slot " .. slot .. " unreadable")
            end
        end
    end
    return out
end

--- Whether this parameter is half of a running fusion (evolution and prestige
--- refuse it while it is, auto-evolve skips it).
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
    GameLoop.start(TICK_MS, Fusion._tick, "battle fusion")
    Log("fusion ready")
end

return Fusion
