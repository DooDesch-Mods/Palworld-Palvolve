-- altar.lua: the permanent fusion at the Fusion Altar.
--
-- The altar is a clone of the vanilla Viewing Cage (PalSchema building
-- Palvolve_FusionAltar): the player puts Pals in through its menu and the cage
-- spawns them as phantoms that wander inside. A fusion needs exactly two of the
-- player's own Pals in there.
--
-- Order of the commit, chosen so every step before the last one can be undone:
--   1. cost taken in a transaction, both Pals captured
--   2. the scene plays (fusionfx.lua) until the burst
--   3. A is rewritten into C and read back          -> restore A + refund on failure
--   4. B's full record goes to fusion-ledger.lua, then B leaves the altar for the
--      box and that box slot is emptied (the only step with no way back: the
--      cage leaves a ghost phantom behind when a slot is emptied in place,
--      measured 2026-09-24)
--   5. A leaves the altar and comes back, so the cage spawns C's phantom
--   6. the scene reveals C, the cost is committed

local Config = require("config")
local Role = require("role")
local I18n = require("i18n")
local Costs = require("costs")
local Conditions = require("conditions")
local PalPassives = require("palpassives")
local FusionRules = require("fusionrules")
local FusionFx = require("fusionfx")
local WazaInherit = require("wazainherit")
local PASSIVE_RANK = require("passive_rank_static")

local Altar = {}

local ALTAR_ID = "Palvolve_FusionAltar"
local MARKER_FUSED = "Palvolve_Fused"
local REACH = 2000 -- units from the altar a player may start a fusion
local LEDGER_NAME = "fusion-ledger.lua"

local api = nil

local function Log(msg)
    print(string.format("[Palvolve] [altar] %s\n", tostring(msg)))
end

local function reply(playerCtx, key, ...)
    local msg = I18n.msg(key, ...)
    Log(msg)
    Role.chat(playerCtx, msg, "reply")
    return false, msg
end

local function modelId(model)
    local ok, id = pcall(function() return model:TryGetMapObjectId():ToString() end)
    return ok and id or nil
end

local function modelPos(model)
    local ok, t = pcall(function() return model:GetTransform() end)
    if not ok or not t then return nil end
    return { x = t.Translation.X, y = t.Translation.Y, z = t.Translation.Z }
end

local function dist2(a, b)
    return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2
end

local function pawnPos(playerCtx)
    local ok, l = pcall(function() return playerCtx.pawn:K2_GetActorLocation() end)
    if not ok or not l then return nil end
    return { x = l.X, y = l.Y, z = l.Z }
end

--- The nearest altar within reach. allowCage lets a dev test on a vanilla
--- Viewing Cage before an altar exists in the world.
local function findAltar(playerCtx, allowCage)
    local here = pawnPos(playerCtx)
    if not here then return nil end
    local best, bestD = nil, REACH * REACH
    for _, m in ipairs(FindAllOf("PalMapObjectDisplayCharacterModel") or {}) do
        local id = modelId(m)
        if id == ALTAR_ID or (allowCage and id == "DisplayCharacter") then
            local p = modelPos(m)
            if p and dist2(p, here) <= bestD then best, bestD = m, dist2(p, here) end
        end
    end
    return best
end

local function containerOf(model)
    local ok, c = pcall(function() return model:GetCharacterContainerModule():GetContainer() end)
    return ok and c or nil
end

local function filledSlots(container)
    local out = {}
    container.SlotArray:ForEach(function(_, s)
        local slot = s:get()
        local okEmpty, empty = pcall(function() return slot:IsEmpty() end)
        if okEmpty and not empty then
            local okP, param = pcall(function() return slot:GetHandle():TryGetIndividualParameter() end)
            if okP and param and param:IsValid() then
                out[#out + 1] = { slot = slot, index = slot.SlotIndex, param = param }
            end
        end
    end)
    return out
end

local function slotId(container, index)
    local g = container.ID.ID
    return { ContainerId = { ID = { A = g.A, B = g.B, C = g.C, D = g.D } }, SlotIndex = index }
end

local function boxOf(playerCtx)
    local ok, c = pcall(function() return playerCtx.playerState:GetPalStorage().TargetContainer end)
    if ok and c and c:IsValid() then return c end
    return nil
end

local function emptyBoxSlot(box)
    local found = nil
    box.SlotArray:ForEach(function(_, s)
        if found then return end
        local slot = s:get()
        local ok, empty = pcall(function() return slot:IsEmpty() end)
        if ok and empty then found = slot end
    end)
    return found
end

local function netContainer()
    local c = FindFirstOf("PalNetworkCharacterContainerComponent")
    if c and c:IsValid() then return c end
    return nil
end

--- The phantom actor the cage spawned for this parameter, near the altar.
local function phantomOf(param, near)
    local okKey, key = pcall(api.individualKey, param)
    if not okKey then return nil end
    for _, a in ipairs(FindAllOf("PalCharacter") or {}) do
        if not a:GetFullName():find("Default__") and a:IsValid() then
            local okL, l = pcall(function() return a:K2_GetActorLocation() end)
            if okL and l and dist2({ x = l.X, y = l.Y }, near) <= REACH * REACH then
                local okP, k = pcall(function() return api.individualKey(api.paramOf(a)) end)
                if okP and k == key then return a end
            end
        end
    end
    return nil
end

local function readNumber(param, field)
    local v = nil
    pcall(function() v = param.SaveParameter[field] end)
    return tonumber(v)
end

local function writeBoth(param, field, value)
    param.SaveParameter[field] = value
    param.SaveParameterMirror[field] = value
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
local RECORD_FIELDS = { "Level", "Exp", "Gender", "Talent_HP", "Talent_Shot", "Talent_Defense",
    "Rank", "Rank_HP", "Rank_Attack", "Rank_Defence", "Rank_CraftSpeed" }

local function record(param)
    local r = { fields = {} }
    local okId, raw = pcall(api.characterId, param)
    if not okId then return nil, "species unreadable" end
    r.rawId = raw
    for _, f in ipairs(RECORD_FIELDS) do
        local v = readNumber(param, f)
        if v == nil then return nil, f .. " unreadable" end
        r.fields[f] = v
    end
    pcall(function() r.rare = param.SaveParameter.IsRarePal == true end)
    local passives, err = PalPassives.capture(param)
    if not passives then return nil, "passives: " .. tostring(err) end
    r.passives = passives
    local okKey, key = pcall(api.individualKey, param)
    r.key = okKey and key or nil
    return r
end

local function restoreRecord(param, r)
    local errs = {}
    local e = api.writeSpecies(param, r.rawId)
    if e then errs[#errs + 1] = e end
    for f, v in pairs(r.fields) do
        local ok, err = pcall(writeBoth, param, f, v)
        if not ok then errs[#errs + 1] = f .. ": " .. tostring(err) end
    end
    pcall(writeBoth, param, "IsRarePal", r.rare == true)
    local okP, errP = PalPassives.restore(param, r.passives)
    if not okP then errs[#errs + 1] = "passives: " .. tostring(errP) end
    if #errs > 0 then return table.concat(errs, "; ") end
    return nil
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

--- Appends the consumed Pal's record to the ledger before it leaves for good,
--- so support can rebuild it by hand if something after this goes wrong.
local function ledgerAppend(entry)
    local dir = Config.stateDir()
    if not dir then return false end
    local path = dir .. "\\" .. LEDGER_NAME
    local f = io.open(path, "ab")
    if not f then
        Log("[ERROR] ledger not writable: " .. path)
        return false
    end
    f:write("-- " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n" .. serialize(entry) .. "\n")
    f:close()
    return true
end

--- What an altar fusion of these two Pals would give. Returns target and
--- source, or nil and the i18n key that says why not.
function Altar.resolveTarget(idA, idB, levelA, levelB, condCtx)
    local unmet = nil
    for _, rule in ipairs(Config.findFusions(idA, idB, "permanent")) do
        if levelA >= rule.minLevel and levelB >= rule.minLevel then
            local ok = true
            if rule.conditions then ok = Conditions.evaluate({ conditions = rule.conditions }, condCtx) end
            if ok then return rule.to, "rule" end
            unmet = unmet or "fusionConditionsUnmet"
        else
            unmet = unmet or "fusionLevelTooLow"
        end
    end
    if unmet then return nil, unmet end
    if not Config.fusion.fallback then return nil, "fusionNoRule" end
    local child = FusionRules.fallback(idA, idB, (Config.fusion.fallbackPercent or 20) / 100)
    if not child then return nil, "fusionNothingStronger" end
    return child, "fallback"
end

--- Host entry. choice (optional): { passives = {ids}, gender = 1|2 }; without
--- it the passives are picked by rank and the gender is A's.
function Altar.start(playerCtx, choice, opts)
    opts = opts or {}
    if not (Config.fusion.enabled and Config.fusion.altarEnabled) then return reply(playerCtx, "fusionOff") end
    if not api then return reply(playerCtx, "optionUnavailable") end
    if FusionFx.playing() or api.busy() then return reply(playerCtx, "evolutionRunning") end
    if not (playerCtx and playerCtx.pc and playerCtx.pc:IsValid()) then
        Log("[WARN] altar request without a player")
        return false
    end
    local okAuth, hasAuth = pcall(api.hasAuthority, playerCtx.pc)
    if not (okAuth and hasAuth) then
        Log("[WARN] altar request refused: no host authority")
        return false
    end

    local altar = findAltar(playerCtx, opts.allowCage and Config.devMode)
    if not altar then return reply(playerCtx, "fusionNoAltar") end
    local cage = containerOf(altar)
    if not cage then return reply(playerCtx, "fusionNoAltar") end
    local inside = filledSlots(cage)
    if #inside ~= 2 then return reply(playerCtx, "fusionAltarNeedsTwo", #inside) end
    for _, e in ipairs(inside) do
        if not api.isOwnedBy(e.param, playerCtx.playerUId) then return reply(playerCtx, "fusionAltarNotYours") end
    end
    local A, B = inside[1], inside[2]
    local okA, rawA = pcall(api.characterId, A.param)
    local okB, rawB = pcall(api.characterId, B.param)
    if not (okA and okB) then return reply(playerCtx, "optionUnavailable") end
    local idA, alphaA = api.baseCharacterId(rawA)
    local idB, alphaB = api.baseCharacterId(rawB)
    local levelA, levelB = readNumber(A.param, "Level") or 1, readNumber(B.param, "Level") or 1

    local condCtx = { param = A.param, playerCtx = playerCtx }
    local target, source = Altar.resolveTarget(idA, idB, levelA, levelB, condCtx)
    if not target then return reply(playerCtx, source, api.displayName(idA), api.displayName(idB)) end

    local costList = Costs.resolve({ from = idA, to = target, stone = "fusionCore" }, levelA, playerCtx.pc)
    local txn = nil
    if #costList > 0 then
        local failed
        txn, failed = Costs.beginTransaction(playerCtx, costList)
        if not txn then
            return reply(playerCtx, "fusionMissing", Costs.describeMissing({ failed }))
        end
        Log("Cost taken: " .. Costs.describe(costList))
    end
    local function refund(reason) if txn then txn.refund(reason) end end

    local recA, errA = record(A.param)
    local recB, errB = record(B.param)
    if not (recA and recB) then
        refund("capture failed")
        Log("[ERROR] altar capture failed: " .. tostring(errA or errB))
        return reply(playerCtx, "swapStateSnapshotFailed")
    end

    -- Everything C gets, decided before the scene starts.
    local expA = math.max(recA.fields.Exp, totalExp(levelA) or 0)
    local expB = math.max(recB.fields.Exp, totalExp(levelB) or 0)
    local level = FusionRules.levelFor(levelA, expA, levelB, expB,
        function(l) return totalExp(l) or 0 end, 80)
    local merged = {}
    for _, f in ipairs(STAT_FIELDS) do merged[f] = FusionRules.best(recA.fields[f], recB.fields[f]) end
    local picked = nil
    if choice and type(choice.passives) == "table" then
        local allowed = {}
        for _, id in ipairs(FusionRules.passivePool(recA.passives, recB.passives)) do allowed[id] = true end
        picked = {}
        for _, id in ipairs(choice.passives) do
            if allowed[id] and #picked < 4 then picked[#picked + 1] = id end
        end
    else
        picked = FusionRules.autoPassives(recA.passives, recB.passives,
            function(id) return PASSIVE_RANK[id] end, 4)
    end
    local markers = FusionRules.mergeMarkers(recA.passives, recB.passives, "Palvolve_FusionActive")
    local seenFused = false
    for _, id in ipairs(markers) do if id == MARKER_FUSED then seenFused = true end end
    if not seenFused then markers[#markers + 1] = MARKER_FUSED end
    local gender = (choice and (choice.gender == 1 or choice.gender == 2)) and choice.gender or recA.fields.Gender
    local rare = recA.rare or recB.rare
    local center = modelPos(altar)
    local function knownMoves(param, label)
        local snap, err = WazaInherit.capture(param)
        if not snap then
            Log("[WARN] moves of " .. label .. " unreadable: " .. tostring(err))
            return {}
        end
        if not snap.known then Log("[WARN] learnable moves of " .. label .. ": " .. tostring(snap.knownError)) end
        local out = {}
        for _, list in ipairs({ snap.known or {}, snap.save.mastered, snap.save.equip }) do
            for _, n in ipairs(list) do out[#out + 1] = n end
        end
        return out
    end
    local movesA, movesB = knownMoves(A.param, "A"), knownMoves(B.param, "B")

    local phantomA = phantomOf(A.param, center)
    local phantomB = phantomOf(B.param, center)
    if not (phantomA and phantomB) then
        refund("phantoms missing")
        return reply(playerCtx, "fusionAltarNotReady")
    end

    local function mutateA()
        local wanted = (alphaA or alphaB) and ("BOSS_" .. target) or target
        local e = api.writeSpecies(A.param, wanted)
        if e and wanted ~= target then e = api.writeSpecies(A.param, target) end
        if e then return e end
        for f, v in pairs(merged) do
            local ok, err = pcall(writeBoth, A.param, f, v)
            if not ok then return f .. ": " .. tostring(err) end
        end
        local okL, errL = pcall(function()
            writeBoth(A.param, "Level", level)
            writeBoth(A.param, "Exp", math.max(expA + expB, totalExp(level) or 0))
            writeBoth(A.param, "Gender", gender)
            writeBoth(A.param, "IsRarePal", rare)
        end)
        if not okL then return "level/gender: " .. tostring(errL) end
        local list = {}
        for _, id in ipairs(picked) do list[#list + 1] = id end
        for _, id in ipairs(markers) do list[#list + 1] = id end
        local okP, errP = PalPassives.restore(A.param, list)
        if not okP then return "passives: " .. tostring(errP) end
        -- both repertoires stay pickable: everything either Pal could equip
        local okT, errT = WazaInherit.teach(A.param, movesA, movesB)
        if not okT then Log("[WARN] repertoire not merged: " .. tostring(errT)) end
        pcall(function() A.param:FullRecoveryHP() end)
        return nil
    end

    local net = netContainer()
    local box = boxOf(playerCtx)

    local function consumeB()
        if not (net and box) then return "no box or network container" end
        local free = emptyBoxSlot(box)
        if not free then return "the box is full" end
        ledgerAppend({ consumed = recB, fusedInto = target, fusedWith = recA.key, player = tostring(playerCtx.playerUId and playerCtx.playerUId.A) })
        local toBox = slotId(box, free.SlotIndex)
        local okMove, errMove = pcall(function() net:RequestSwap_ToServer_Rep(slotId(cage, B.index), toBox) end)
        if not okMove then return "B to box: " .. tostring(errMove) end
        local okEmpty, errEmpty = pcall(function() net:RequestEmptySlot_ToServer_Rep(toBox) end)
        if not okEmpty then return "B release: " .. tostring(errEmpty) end
        return nil
    end

    local function respawnA()
        local free = emptyBoxSlot(box)
        if not free then return "the box is full" end
        local toBox = slotId(box, free.SlotIndex)
        local okOut, errOut = pcall(function() net:RequestSwap_ToServer_Rep(slotId(cage, A.index), toBox) end)
        if not okOut then return "A out: " .. tostring(errOut) end
        local okIn, errIn = pcall(function() altar:TryMoveToDisplayCage(free) end)
        if not okIn then return "A back in: " .. tostring(errIn) end
        return nil
    end

    local started, why = FusionFx.play({
        worldCtx = playerCtx.pc, a = phantomA, b = phantomB, center = center,
        idA = idA, idB = idB, freeze = api.freeze,
        onCommit = function()
            local err = mutateA()
            if err then
                local restoreErr = restoreRecord(A.param, recA)
                Log("[ERROR] altar fusion failed at the rewrite: " .. err
                    .. (restoreErr and ("; restore: " .. restoreErr) or "; A restored"))
                refund("rewrite failed")
                pcall(function() phantomA:SetActorHiddenInGame(false) end)
                pcall(function() phantomB:SetActorHiddenInGame(false) end)
                FusionFx.abort("rewrite failed")
                Role.chat(playerCtx, I18n.msg("swapStateMutationFailed"), "reply")
                return
            end
            local errB = consumeB()
            if errB then
                -- A is C already and B is still here: undo A, give the cost back
                local restoreErr = restoreRecord(A.param, recA)
                Log("[ERROR] altar fusion stopped before B left: " .. errB
                    .. (restoreErr and ("; restore: " .. restoreErr) or "; A restored"))
                refund("consume failed")
                pcall(function() phantomA:SetActorHiddenInGame(false) end)
                pcall(function() phantomB:SetActorHiddenInGame(false) end)
                FusionFx.abort("consume failed")
                Role.chat(playerCtx, I18n.msg("fusionAltarFailed"), "reply")
                return
            end
            if txn then txn.commit() end
            local errR = respawnA()
            if errR then
                Log("[WARN] the fused Pal is done but its phantom did not respawn: " .. errR)
            end
            FusionFx.awaitReveal(function() return phantomOf(A.param, center) end, target)
            Log(string.format("%s + %s fused into %s for good (Lv %d, %s)", idA, idB, target, level, source))
            Role.chat(playerCtx, I18n.msg("fusionAltarDone", api.displayName(idA),
                api.displayName(idB), api.displayName(target)), "info")
        end,
        onDone = function(reason) Log("altar scene: " .. tostring(reason)) end,
    })
    if not started then
        refund("scene did not start")
        Log("[WARN] altar scene did not start: " .. tostring(why))
        return reply(playerCtx, "evolutionRunning")
    end
    return true
end

function Altar.init(evolution)
    api = evolution.fusionApi
    if not api then Log("[ERROR] Evolution.fusionApi missing, the altar stays off") end
end

return Altar
