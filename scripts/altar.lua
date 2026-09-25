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
--      box and that box slot is emptied (the only step with no way back; B
--      goes through the box because the cage leaves a ghost phantom behind
--      when a slot is emptied in place)
--   5. A leaves the altar and comes back, so the cage spawns C's phantom
--   6. the scene reveals C, the cost is committed
-- A scene that ends before step 3 (a Pal taken out, the player gone, a step
-- that fails) gives the cost back.

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
-- carried by both halves of a running battle fusion (fusion.lua)
local MARKER_ACTIVE = "Palvolve_FusionActive"
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

--- IsValid without raising. A plain pcall around a UFunction call does not
--- guard a freed object; this check before the call does.
local function isLive(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

--- A live instance, not the class default object FindAllOf also returns: a
--- method call on that one faults natively, past any pcall.
local function isInstance(obj)
    if not isLive(obj) then return false end
    local ok, name = pcall(function() return obj:GetFullName() end)
    return ok and type(name) == "string" and not name:find("Default__", 1, true)
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
        local id = isInstance(m) and modelId(m) or nil
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

--- The requesting player's container component (on the controller's
--- transmitter). On a server every connected player has one, so any other
--- instance is only the fallback for a controller that does not expose it.
-- Fusions whose second Pal must have left the altar once the slot moves
-- settle. The moves are requests; a server that refuses one would otherwise
-- leave B in the cage next to the finished result.
local pendingConsumed = {}

--- Runs on the game thread. Empties the cage slot directly when B is still
--- in it, so the Pal does not exist twice.
function Altar._verifyConsumed()
    local due = pendingConsumed
    pendingConsumed = {}
    for _, p in ipairs(due) do
        if not (isInstance(p.cage) and isLive(p.net)) then
            Log("[WARN] consume check skipped: the altar or the network container is gone (B " .. tostring(p.key) .. ")")
        else
            local stuck = nil
            for _, e in ipairs(filledSlots(p.cage)) do
                local okKey, k = pcall(api.individualKey, e.param)
                if okKey and k == p.key then stuck = e end
            end
            if not stuck then
                Log("[INFO] consume check: B " .. tostring(p.key) .. " left the altar")
            else
                Log("[ERROR] B " .. tostring(p.key) .. " is still in the altar after the fusion; emptying its slot")
                local ok, err = pcall(function() p.net:RequestEmptySlot_ToServer_Rep(slotId(p.cage, stuck.index)) end)
                if ok then Log("[INFO] consume check: stuck slot " .. tostring(stuck.index) .. " emptied")
                else Log("[ERROR] consume check: the stuck slot could not be emptied: " .. tostring(err)) end
            end
        end
    end
end

local function scheduleConsumedCheck(cage, net, key)
    if key == nil then
        Log("[WARN] consume check skipped: B has no individual key")
        return
    end
    pendingConsumed[#pendingConsumed + 1] = { cage = cage, net = net, key = key }
    -- one-shot LoopAsync, see UE4SS-LESSONS rule 1
    LoopAsync(1500, function()
        ExecuteInGameThread(Altar._verifyConsumed)
        return true
    end)
end

local function netContainer(playerCtx)
    local okOwn, own = pcall(function() return playerCtx.pc.Transmitter.CharacterContainer end)
    if okOwn and isLive(own) then return own end
    Log("[WARN] the player's own network container is unreadable (" .. tostring(okOwn and "none" or own)
        .. "), using the first one found")
    for _, c in ipairs(FindAllOf("PalNetworkCharacterContainerComponent") or {}) do
        if isInstance(c) then return c end
    end
    return nil
end

--- The phantom actor the cage spawned for this parameter, near the altar.
local function phantomOf(param, near)
    local okKey, key = pcall(api.individualKey, param)
    if not okKey then return nil end
    for _, a in ipairs(FindAllOf("PalCharacter") or {}) do
        if isInstance(a) then
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
    local okRare, rare = pcall(function() return param.SaveParameter.IsRarePal end)
    if not okRare then return nil, "IsRarePal unreadable: " .. tostring(rare) end
    r.rare = rare == true
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
    local okRare, rareErr = pcall(writeBoth, param, "IsRarePal", r.rare == true)
    if not okRare then errs[#errs + 1] = "IsRarePal: " .. tostring(rareErr) end
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
    if not dir then
        Log("[ERROR] ledger not written: no folder for it")
        return false
    end
    local path = dir .. "\\" .. LEDGER_NAME
    local f = io.open(path, "ab")
    if not f then
        Log("[ERROR] ledger not writable: " .. path)
        return false
    end
    local okWrite, writeErr = f:write("-- " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n" .. serialize(entry) .. "\n")
    f:close()
    if not okWrite then
        Log("[ERROR] ledger write failed: " .. tostring(writeErr))
        return false
    end
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
        -- Half of a running battle fusion: its split would later write the
        -- old Pal back over the result, or look for a partner that is gone.
        for _, id in ipairs(PalPassives.capture(e.param) or {}) do
            if id == MARKER_ACTIVE then return reply(playerCtx, "fusionAlreadyActive") end
        end
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
    -- Without the exp table every level would count as reachable and the
    -- result would land at the level cap.
    if totalExp(1) == nil then
        Log("[ERROR] altar fusion refused: the exp table is unreadable")
        return reply(playerCtx, "optionUnavailable")
    end

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
    local pool = FusionRules.passivePool(recA.passives, recB.passives)
    if choice and type(choice.passiveIndexes) == "table" then
        -- a client sends positions in the pool, which it built the same way
        picked = {}
        for _, i in ipairs(choice.passiveIndexes) do
            if pool[i] and #picked < 4 then picked[#picked + 1] = pool[i] end
        end
    elseif choice and type(choice.passives) == "table" then
        local allowed = {}
        for _, id in ipairs(pool) do allowed[id] = true end
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
        local okHeal, healErr = pcall(function() A.param:FullRecoveryHP() end)
        if not okHeal then Log("[WARN] the fused Pal was not healed: " .. tostring(healErr)) end
        return nil
    end

    local net = netContainer(playerCtx)
    local box = boxOf(playerCtx)

    -- The altar menu stays usable while the scene plays: at the burst, the two
    -- slots must still hold the two Pals the scene started with.
    local function stillInside()
        if not (isLive(altar) and isLive(cage)) then return "the altar is gone" end
        if not (isLive(A.param) and isLive(B.param)) then return "a Pal is gone" end
        local keyAt = {}
        for _, e in ipairs(filledSlots(cage)) do
            local okKey, k = pcall(api.individualKey, e.param)
            if okKey then keyAt[e.index] = k end
        end
        if keyAt[A.index] ~= recA.key or keyAt[B.index] ~= recB.key then
            return "the Pals in the altar changed during the scene"
        end
        return nil
    end

    local function consumeB()
        if not (isLive(net) and isLive(box)) then return "no box or network container" end
        local free = emptyBoxSlot(box)
        if not free then return "the box is full" end
        if not ledgerAppend({ consumed = recB, fusedInto = target, fusedWith = recA.key,
            player = tostring(playerCtx.playerUId and playerCtx.playerUId.A) }) then
            Log("[ERROR] the consumed Pal has no ledger entry; its record: species "
                .. tostring(recB.rawId) .. ", key " .. tostring(recB.key))
        end
        local toBox = slotId(box, free.SlotIndex)
        local okMove, errMove = pcall(function() net:RequestSwap_ToServer_Rep(slotId(cage, B.index), toBox) end)
        if not okMove then return "B to box: " .. tostring(errMove) end
        local okEmpty, errEmpty = pcall(function() net:RequestEmptySlot_ToServer_Rep(toBox) end)
        if not okEmpty then return "B release: " .. tostring(errEmpty) end
        return nil
    end

    local function respawnA()
        if not (isLive(net) and isLive(box) and isLive(altar)) then return "no box, network container or altar" end
        local free = emptyBoxSlot(box)
        if not free then return "the box is full" end
        local toBox = slotId(box, free.SlotIndex)
        local okOut, errOut = pcall(function() net:RequestSwap_ToServer_Rep(slotId(cage, A.index), toBox) end)
        if not okOut then return "A out: " .. tostring(errOut) end
        local okIn, errIn = pcall(function() altar:TryMoveToDisplayCage(free) end)
        if not okIn then return "A back in: " .. tostring(errIn) end
        return nil
    end

    local rewriteStarted = false

    -- the burst hid both phantoms; a fusion that stops there shows them again
    local function showPhantomsAgain()
        for _, p in ipairs({ phantomA, phantomB }) do
            if isLive(p) then
                local ok, err = pcall(function() p:SetActorHiddenInGame(false) end)
                if not ok then Log("[WARN] phantom not shown again: " .. tostring(err)) end
            end
        end
    end

    local started, why = FusionFx.play({
        worldCtx = playerCtx.pc, a = phantomA, b = phantomB, center = center,
        idA = idA, idB = idB, freeze = api.freeze,
        onCommit = function()
            local errInside = stillInside()
            if errInside then
                Log("[ERROR] altar fusion stopped before the rewrite: " .. errInside)
                refund("altar changed")
                showPhantomsAgain()
                FusionFx.abort("altar changed")
                Role.chat(playerCtx, I18n.msg("fusionAltarFailed"), "reply")
                return
            end
            rewriteStarted = true
            local err = mutateA()
            if err then
                local restoreErr = restoreRecord(A.param, recA)
                Log("[ERROR] altar fusion failed at the rewrite: " .. err
                    .. (restoreErr and ("; restore: " .. restoreErr) or "; A restored"))
                refund("rewrite failed")
                showPhantomsAgain()
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
                showPhantomsAgain()
                FusionFx.abort("consume failed")
                Role.chat(playerCtx, I18n.msg("fusionAltarFailed"), "reply")
                return
            end
            if txn then txn.commit() end
            scheduleConsumedCheck(cage, net, recB.key)
            local errR = respawnA()
            if errR then
                Log("[WARN] the fused Pal is done but its phantom did not respawn: " .. errR)
            end
            FusionFx.awaitReveal(function() return phantomOf(A.param, center) end, target)
            Log(string.format("%s + %s fused into %s for good (Lv %d, %s)", idA, idB, target, level, source))
            Role.chat(playerCtx, I18n.msg("fusionAltarDone", api.displayName(idA),
                api.displayName(idB), api.displayName(target)), "info")
        end,
        onDone = function(reason)
            Log("altar scene: " .. tostring(reason))
            if not (txn and not txn.done) then return end
            if rewriteStarted then
                -- the commit raised halfway: A may be rewritten already, so the
                -- cost stays taken and the state goes to the log for support
                Log("[ERROR] altar fusion stopped halfway through the commit (" .. tostring(reason)
                    .. "); cost kept, A " .. tostring(recA.key) .. ", B " .. tostring(recB.key))
                return
            end
            -- ended before the rewrite: a Pal left the altar, a step failed, or
            -- the scene ran out of time
            refund("scene ended: " .. tostring(reason))
        end,
    })
    if not started then
        refund("scene did not start")
        Log("[WARN] altar scene did not start: " .. tostring(why))
        return reply(playerCtx, "evolutionRunning")
    end
    return true
end

--- What the pick window shows for the nearby altar: both names, the result,
--- the passive pool in the order Altar.start rebuilds it, and a preset of the
--- passives the automatic pick would take. Returns info, or nil and a message.
function Altar.pickInfo(playerCtx)
    if not api then return nil, I18n.msg("optionUnavailable") end
    local altar = findAltar(playerCtx, Config.devMode)
    if not altar then return nil, I18n.msg("fusionNoAltar") end
    local cage = containerOf(altar)
    local inside = cage and filledSlots(cage) or {}
    if #inside ~= 2 then return nil, I18n.msg("fusionAltarNeedsTwo", #inside) end
    local A, B = inside[1], inside[2]
    local okA, rawA = pcall(api.characterId, A.param)
    local okB, rawB = pcall(api.characterId, B.param)
    if not (okA and okB) then return nil, I18n.msg("optionUnavailable") end
    local idA, idB = api.baseCharacterId(rawA), api.baseCharacterId(rawB)
    local levelA, levelB = readNumber(A.param, "Level") or 1, readNumber(B.param, "Level") or 1
    local target, why = Altar.resolveTarget(idA, idB, levelA, levelB, { param = A.param, playerCtx = playerCtx })
    if not target then return nil, I18n.msg(why, api.displayName(idA), api.displayName(idB)) end
    local passA, errA = PalPassives.capture(A.param)
    local passB, errB = PalPassives.capture(B.param)
    if not (passA and passB) then
        Log("[WARN] pick window: passives unreadable: " .. tostring(errA or errB))
        return nil, I18n.msg("swapStateSnapshotFailed")
    end
    local pool = FusionRules.passivePool(passA, passB)
    local auto = FusionRules.autoPassives(passA, passB, function(id) return PASSIVE_RANK[id] end, 4)
    local at, preset, ranks = {}, {}, {}
    for i, id in ipairs(pool) do
        at[id] = i
        ranks[i] = tonumber(PASSIVE_RANK[id]) or 0
    end
    for _, id in ipairs(auto) do preset[#preset + 1] = at[id] end
    local costList = Costs.resolve({ from = idA, to = target, stone = "fusionCore" }, levelA, playerCtx.pc)
    -- where each passive comes from, so the window can show the Pal that owns it
    local fromA, fromB, sources = {}, {}, {}
    for _, id in ipairs(passA) do fromA[id] = true end
    for _, id in ipairs(passB) do fromB[id] = true end
    for i, id in ipairs(pool) do
        sources[i] = (fromA[id] and fromB[id]) and "ab" or (fromA[id] and "a" or "b")
    end
    local expA = math.max(readNumber(A.param, "Exp") or 0, totalExp(levelA) or 0)
    local expB = math.max(readNumber(B.param, "Exp") or 0, totalExp(levelB) or 0)
    local levelC = FusionRules.levelFor(levelA, expA, levelB, expB, function(l) return totalExp(l) or 0 end, 80)
    return {
        nameA = api.displayName(idA), nameB = api.displayName(idB), nameC = api.displayName(target),
        idA = idA, idB = idB, idC = target, levelA = levelA, levelB = levelB, levelC = levelC,
        sources = sources,
        pool = pool, ranks = ranks, preset = preset,
        gender = readNumber(A.param, "Gender") or 1,
        cost = #costList > 0 and Costs.describe(costList) or "",
    }
end

--- The wheel entry for a nearby altar, or nil when no altar is in reach. Reads
--- only; Altar.start checks everything again.
function Altar.wheelOption(playerCtx)
    if not (Config.fusion.enabled and Config.fusion.altarEnabled) then return nil end
    if not api then
        Log("[WARN] altar wheel entry skipped: not set up")
        return nil
    end
    local altar = findAltar(playerCtx, Config.devMode)
    if not altar then return nil end
    local opt = { fusion = "altar", index = 1, label = I18n.msg("fusionAltarEntry") }
    local cage = containerOf(altar)
    local inside = cage and filledSlots(cage) or {}
    if #inside ~= 2 then
        opt.blocked = I18n.msg("fusionAltarNeedsTwo", #inside)
    else
        local A, B = inside[1], inside[2]
        local okA, rawA = pcall(api.characterId, A.param)
        local okB, rawB = pcall(api.characterId, B.param)
        if not (okA and okB) then
            Log("[WARN] altar wheel entry: species unreadable")
            opt.blocked = I18n.msg("optionUnavailable")
        elseif not (api.isOwnedBy(A.param, playerCtx.playerUId) and api.isOwnedBy(B.param, playerCtx.playerUId)) then
            opt.blocked = I18n.msg("fusionAltarNotYours")
        else
            local idA, idB = api.baseCharacterId(rawA), api.baseCharacterId(rawB)
            local nameA, nameB = api.displayName(idA), api.displayName(idB)
            local levelA, levelB = readNumber(A.param, "Level") or 1, readNumber(B.param, "Level") or 1
            local target, why = Altar.resolveTarget(idA, idB, levelA, levelB,
                { param = A.param, playerCtx = playerCtx })
            if not target then
                opt.blocked = I18n.msg(why, nameA, nameB)
            else
                local costList = Costs.resolve({ from = idA, to = target, stone = "fusionCore" }, levelA, playerCtx.pc)
                local costOk, missing = Costs.check(playerCtx, costList)
                if not costOk then
                    opt.blocked = I18n.msg("fusionMissing", Costs.describeMissing(missing))
                else
                    opt.requirement = I18n.msg("fusionAltarPreview", nameA, nameB, api.displayName(target))
                end
            end
        end
    end
    opt.requirement = opt.requirement or opt.blocked
    return opt
end

-- ---------------------------------------------------------------- the stage
-- The two Pals in an altar do not wander: the host stands Pal 1 on slot 1 and
-- Pal 2 on slot 2, facing each other, until a fusion starts. The slots are the
-- altar model's "Slot1"/"Slot2" components when the building has them, else
-- points left and right of the altar's centre.

local STAGE_TICK_MS = 1000
local SLOT_SPREAD = 150   -- units from the centre to each slot without slot components
local STAGE_LIFT = 0      -- height of the standing point above the altar origin
local SLOT_MARGIN = 60     -- room between a Pal's body and the altar's centre
local BOUNDS_SHARE = 0.6   -- part of the bounds box the visible body fills

local stageDriving = false
local stageWarned = {}    -- one warning per problem, not one per second

local function warnOnce(key, msg)
    if stageWarned[key] then return end
    stageWarned[key] = true
    Log("[WARN] " .. msg)
end

--- World positions of the two standing points of an altar model.
local function slotPoints(model)
    local okT, t = pcall(function() return model:GetTransform() end)
    if not okT or not t then return nil end
    local c = t.Translation
    local q = t.Rotation
    -- yaw from the rotation quaternion
    local yaw = math.atan(2 * (q.W * q.Z + q.X * q.Y), 1 - 2 * (q.Y * q.Y + q.Z * q.Z))
    local points = nil
    local okActor, actor = pcall(function() return model:GetActor() end)
    if okActor and isLive(actor) then
        local found = {}
        local okComps, compErr = pcall(function()
            local comps = actor:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SceneComponent"))
            -- UE4SS hands the returned array over as a plain Lua table here
            local list = {}
            if type(comps) == "table" then
                for _, v in ipairs(comps) do list[#list + 1] = v end
            else
                comps:ForEach(function(_, v) list[#list + 1] = v end)
            end
            for _, v in ipairs(list) do
                local comp = (type(v) == "userdata" and v.get) and v:get() or v
                local name = comp:GetFName():ToString()
                if name == "Slot1" or name == "Slot2" then
                    local l = comp:K2_GetComponentLocation()
                    found[name] = { x = l.X, y = l.Y, z = l.Z }
                end
            end
        end)
        if not okComps then warnOnce("comps", "altar slot components unreadable: " .. tostring(compErr)) end
        if found.Slot1 and found.Slot2 then points = { found.Slot1, found.Slot2, onPedestals = true } end
    elseif not okActor then
        warnOnce("actor", "altar actor unreadable, standing points from the model position: " .. tostring(actor))
    end
    if not points then
        local dx, dy = math.cos(yaw + math.pi / 2) * SLOT_SPREAD, math.sin(yaw + math.pi / 2) * SLOT_SPREAD
        points = {
            { x = c.X - dx, y = c.Y - dy, z = c.Z + STAGE_LIFT },
            { x = c.X + dx, y = c.Y + dy, z = c.Z + STAGE_LIFT },
        }
    end
    return points
end

local function stageGameThread()
    if not api then return end
    if FusionFx.playing() or api.busy() then return end
    local altars = {}
    for _, m in ipairs(FindAllOf("PalMapObjectDisplayCharacterModel") or {}) do
        if isInstance(m) and modelId(m) == ALTAR_ID then altars[#altars + 1] = m end
    end
    if #altars == 0 then return end
    -- every Pal body in the world once, keyed by its individual
    local bodies = {}
    for _, a in ipairs(FindAllOf("PalCharacter") or {}) do
        if isInstance(a) then
            local okK, k = pcall(function() return api.individualKey(api.paramOf(a)) end)
            if okK and k then bodies[k] = a end
        end
    end
    for _, m in ipairs(altars) do
        local cage = containerOf(m)
        local points = cage and slotPoints(m)
        if points then
            local inside = filledSlots(cage)
            table.sort(inside, function(a, b) return a.index < b.index end)
            for i, e in ipairs(inside) do
                if i > 2 then break end
                local okK, k = pcall(api.individualKey, e.param)
                local body = okK and bodies[k] or nil
                if body then
                    local p = points[#inside == 1 and 1 or i]
                    local other = points[i == 1 and 2 or 1]
                    local yaw = math.deg(math.atan(other.y - p.y, other.x - p.x))
                    -- Real pedestals fix the spot. Only the fallback points make room for a
                    -- big Pal: every Pal has the same small capsule, the mesh bounds show its size.
                    if not points.onPedestals and #inside > 1 then
                        local okR, radius = pcall(function()
                            local origin, extent = {}, {}
                            body:GetActorBounds(true, origin, extent, false)
                            return math.max(extent.X or 0, extent.Y or 0) * BOUNDS_SHARE
                        end)
                        if okR and type(radius) == "number" then
                            local mx, my = (points[1].x + points[2].x) / 2, (points[1].y + points[2].y) / 2
                            local ox, oy = p.x - mx, p.y - my
                            local d = math.sqrt(ox * ox + oy * oy)
                            local need = radius + SLOT_MARGIN
                            if d > 1 and need > d then
                                p = { x = mx + ox / d * need, y = my + oy / d * need, z = p.z }
                            end
                        else
                            warnOnce("radius", "altar Pal width unreadable, kept on its slot: " .. tostring(radius))
                        end
                    end
                    if #inside == 1 then
                        -- alone (the fused Pal after a fusion): slot 1, facing the altar's front
                        yaw = yaw - 90
                    end
                    -- the body's origin is the middle of its capsule: stand it on the point
                    local okH, half = pcall(function() return body.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
                    if okH and type(half) == "number" then
                        p = { x = p.x, y = p.y, z = p.z + half }
                    else
                        warnOnce("half", "altar Pal height unreadable, placed at the slot point: " .. tostring(half))
                    end
                    local okFreeze, freezeErr = pcall(api.freeze, body, true)
                    if not okFreeze then warnOnce("freeze", "altar Pal not held still: " .. tostring(freezeErr)) end
                    local okPlace, placeErr = pcall(function()
                        body:K2_SetActorLocation({ X = p.x, Y = p.y, Z = p.z }, false, {}, true)
                        body:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
                    end)
                    if not okPlace then warnOnce("place", "altar Pal not placed on its slot: " .. tostring(placeErr)) end
                end
            end
        end
    end
end
Altar._stageGameThread = stageGameThread

local function stageTick()
    if not (Config.fusion.enabled and Config.fusion.altarEnabled) then return false end
    if not Role.hasWorldAuthority() then return false end
    ExecuteInGameThread(Altar._stageGameThread)
    return false
end
Altar._stageTick = stageTick -- held by the module so the scheduled callback is never collected

function Altar.init(evolution)
    api = evolution.fusionApi
    if not api then Log("[ERROR] Evolution.fusionApi missing, the altar stays off") end
    if not stageDriving then
        stageDriving = true
        LoopAsync(STAGE_TICK_MS, Altar._stageTick)
        Log("altar stage started")
    end
end

return Altar
