-- Palvolve core: eligibility, two-stage confirm, transactional species swap,
-- snapshots/rollback, IV bonus and the staged evolution sequence.
-- API facts: Workspace/docs/Palvolve/RESEARCH.md. Sequence design: direct manager
-- teardown first (the holder recall animates a mesh clone that ignores a hidden
-- actor and is therefore only a fallback), species swap while despawned,
-- activation pump with class-verified respawn, staged reveal driven by the
-- selected FX prototype (fx.lua).

local Config = require("config")
local FX = require("fx")

local Evolution = {}

local MOD_NAME = "Palvolve"
local STATE_FILE = "ue4ss\\Mods\\Palvolve\\palvolve_state.lua"

local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- ---------------------------------------------------------------- utilities

local function palUtility()
    local u = StaticFindObject("/Script/Pal.Default__PalUtility")
    if u and u:IsValid() then return u end
    return nil
end

-- Ownership lives in the guid components (local host = ...-0001 in D),
-- so all four components must be checked.
local function isOwned(param)
    local owned = false
    pcall(function()
        local g = param.SaveParameter.OwnerPlayerUId
        owned = (g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0)
    end)
    return owned
end

local function guidString(g)
    return string.format("%08X-%08X-%08X-%08X", g.A, g.B, g.C, g.D)
end

local function individualKey(param)
    local key = ""
    pcall(function() key = guidString(param.IndividualId.InstanceId) end)
    if key == "" then pcall(function() key = param:GetFullName() end) end
    return key
end

local function paramOf(palActor)
    local param = nil
    pcall(function()
        param = palActor.CharacterParameterComponent:GetIndividualParameter()
    end)
    if param and param:IsValid() then return param end
    return nil
end

local function findHolder(actor)
    local util = palUtility()
    if not util then return nil end
    local holder = nil
    if actor then
        pcall(function()
            if actor:IsValid() then holder = util:GetOtomoHolderByOtomoPal(actor) end
        end)
        if holder and holder:IsValid() then return holder end
    end
    pcall(function()
        local pc = FindFirstOf("PalPlayerController")
        if pc and pc:IsValid() then holder = util:GetOtomoHolderComponent(pc) end
    end)
    if holder and holder:IsValid() then return holder end
    return nil
end

local function findManager(ctx)
    local mgr = nil
    pcall(function()
        local util = palUtility()
        if util then mgr = util:GetCharacterManager(ctx) end
    end)
    if mgr and mgr:IsValid() then return mgr end
    pcall(function() mgr = FindFirstOf("PalCharacterManager") end)
    if mgr and mgr:IsValid() then return mgr end
    return nil
end

-- ---------------------------------------------------------------- snapshots (rollback)

-- Persisted as executable Lua (simplest robust format without a JSON lib).
local snapshots = {}

local function loadSnapshots()
    local ok = pcall(function()
        local chunk = loadfile(STATE_FILE)
        if chunk then
            local data = chunk()
            if type(data) == "table" then snapshots = data end
        end
    end)
    if not ok then snapshots = {} end
end

local function saveSnapshots()
    local ok, err = pcall(function()
        local f = assert(io.open(STATE_FILE, "w"))
        f:write("return {\n")
        for _, s in ipairs(snapshots) do
            f:write(string.format(
                "  { key = %q, from = %q, to = %q, level = %d, nickname = %q, ivHP = %d, ivMelee = %d, ivShot = %d, ivDefense = %d },\n",
                s.key or "", s.from, s.to, s.level, s.nickname or "",
                s.ivHP or -1, s.ivMelee or -1, s.ivShot or -1, s.ivDefense or -1))
        end
        f:write("}\n")
        f:close()
    end)
    if not ok then Log("Snapshot file not writable: " .. tostring(err)) end
end

-- ---------------------------------------------------------------- sound

local function playFanfare(actor)
    pcall(function()
        local ake = StaticFindObject("/Game/Pal/Sound/Events/SE/UI/CampLevelUp/AKE_CampLevelUp.AKE_CampLevelUp")
        local aks = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics")
        if ake and ake:IsValid() and aks and aks:IsValid() then
            aks:PostEvent(ake, actor, 0, nil, false)
        end
    end)
end

local function setFrozen(palActor, frozen)
    pcall(function()
        local ctrl = palActor:GetController()
        if ctrl and ctrl:IsValid() then ctrl:SetActiveAI(not frozen) end
    end)
    pcall(function()
        local util = palUtility()
        if util then util:SetMoveDisableFlag(palActor, frozen, FName("PalvolveSeq")) end
    end)
end

-- The pooled actor grabbed after a teardown is still in the INACTIVE pal
-- state (bIsPalActiveActor=false): native code anchors inactive otomos to
-- their holder, which yanked revealed pals to the player and kept them
-- hovering there. Finish the activation the vanilla summon flow would have
-- done; MOVE_Falling lets the pal land naturally once it is unfrozen.
local function completeOtomoActivation(palActor)
    pcall(function() palActor.ActionComponent:CancelAllAction() end)
    pcall(function() palActor:SetActiveActor(true) end)
    pcall(function() palActor:SetActiveCollisionMovement(true) end)
    pcall(function() palActor.CharacterMovement:SetMovementMode(3, 0) end)
end

-- ---------------------------------------------------------------- item costs

local function inventoryData()
    local inv = nil
    pcall(function()
        local pc = FindFirstOf("PalPlayerController")
        if pc and pc:IsValid() then
            inv = pc:GetPalPlayerState():GetInventoryData()
        end
    end)
    if inv and inv:IsValid() then return inv end
    return nil
end

local function countItem(staticItemId)
    local n = 0
    pcall(function()
        local inv = inventoryData()
        if inv then n = inv:CountItemNum(FName(staticItemId)) end
    end)
    return n
end

-- Consumes `need` items; success is verified via the count difference
-- (RequestConsumeInventoryItem is the only BP-exposed consume path).
local function tryConsumeItems(staticItemId, need)
    local ok = false
    pcall(function()
        local inv = inventoryData()
        if not inv then return end
        local id = FName(staticItemId)
        local before = inv:CountItemNum(id)
        if before < need then return end
        local cdo = StaticFindObject("/Script/Pal.Default__PalIncidentBase")
        if cdo and cdo:IsValid() then
            cdo:RequestConsumeInventoryItem(inv, id, need)
        end
        local after = inv:CountItemNum(id)
        ok = (before - after) == need
    end)
    return ok
end

-- Checks the stone cost for a pair; returns ok, stoneId, displayName
local function stoneCheck(pair)
    if not Config.requireStone then return true, nil, nil end
    local stoneId = Config.stoneItemIds[pair.stone]
    local stoneName = Config.stoneNames[pair.stone] or pair.stone
    if not stoneId then return true, nil, nil end
    return countItem(stoneId) >= Config.stoneCount, stoneId, stoneName
end

-- ---------------------------------------------------------------- IV bonus

local TALENT_FIELDS = { "Talent_HP", "Talent_Melee", "Talent_Shot", "Talent_Defense" }

local function readTalents(param)
    local t = {}
    for _, field in ipairs(TALENT_FIELDS) do
        local v = -1
        pcall(function() v = param.SaveParameter[field] end)
        t[field] = v
    end
    return t
end

local function applyIvBonus(param)
    local applied = {}
    for _, field in ipairs(TALENT_FIELDS) do
        local ok = pcall(function()
            local cur = param.SaveParameter[field]
            local new = math.min(cur + Config.ivBonusPerStage, Config.ivCap)
            param.SaveParameter[field] = new
            param.SaveParameterMirror[field] = new
            table.insert(applied, string.format("%s %d->%d", field, cur, new))
        end)
        if not ok then
            Log("IV bonus: field " .. field .. " not writable (check field name)")
        end
    end
    if #applied > 0 then Log("IV bonus: " .. table.concat(applied, ", ")) end
end

-- ---------------------------------------------------------------- polling helper

-- Runs checkFn on the game thread every intervalMs until it returns true or
-- timeoutMs elapsed; calls doneFn(success) exactly once on the game thread.
local function pollUntil(intervalMs, timeoutMs, checkFn, doneFn)
    local elapsed = 0
    local finished = false
    LoopAsync(intervalMs, function()
        if finished then return true end
        elapsed = elapsed + intervalMs
        ExecuteInGameThread(function()
            if finished then return end
            local ok, res = pcall(checkFn)
            if ok and res then
                finished = true
                local okDone, errDone = pcall(doneFn, true)
                if not okDone then Log("pollUntil doneFn FAIL: " .. tostring(errDone)) end
            elseif elapsed >= timeoutMs then
                finished = true
                local okDone, errDone = pcall(doneFn, false)
                if not okDone then Log("pollUntil doneFn FAIL: " .. tostring(errDone)) end
            end
        end)
        return finished
    end)
end

-- ---------------------------------------------------------------- diagnostics

-- devMode telemetry: after a reveal, log for ~6s WHO moves the new actor where
-- (position, attach parent, movement mode, scale, height above the player)
local function startRevealDiagnostics(holderRef, label)
    if not Config.devMode then return end
    local ticks = 0
    LoopAsync(500, function()
        ticks = ticks + 1
        if ticks > 24 then return true end
        ExecuteInGameThread(function()
            pcall(function()
                local a = nil
                pcall(function() a = holderRef:TryGetSpawnedOtomo() end)
                if not (a and a:IsValid()) then
                    Log(string.format("[diag %s t=%d] no spawned otomo", label, ticks))
                    return
                end
                local loc = a:K2_GetActorLocation()
                local inst = "?"
                pcall(function() inst = a:GetFullName():match("([^%.]+)$") or "?" end)
                local mode = "?"
                pcall(function() mode = tostring(a.CharacterMovement.MovementMode) end)
                local scaleX = -1
                pcall(function() scaleX = a:GetActorScale3D().X end)
                local dz = 0
                pcall(function()
                    local p = FindFirstOf("PalPlayerCharacter")
                    if p and p:IsValid() then dz = loc.Z - p:K2_GetActorLocation().Z end
                end)
                local active = "?"
                pcall(function() active = tostring(a.bIsPalActiveActor) end)
                -- census: EVERY actor of the target class, to catch duplicate
                -- spawns (holder flipping between two actors)
                local census = ""
                pcall(function()
                    local all = FindAllOf("BP_" .. label .. "_C") or {}
                    census = string.format(" census=%d", #all)
                    for i, o in ipairs(all) do
                        pcall(function()
                            if o and o:IsValid() then
                                local oi = o:GetFullName():match("([^%.]+)$") or "?"
                                local ol = o:K2_GetActorLocation()
                                local hid = "?"
                                pcall(function() hid = tostring(o.bHidden) end)
                                census = census .. string.format(" [%s @(%.0f,%.0f,%.0f) hidden=%s]",
                                    oi, ol.X, ol.Y, ol.Z, hid)
                            end
                        end)
                    end
                end)
                Log(string.format("[diag %s t=%d] inst=%s pos=(%.0f,%.0f,%.0f) dzPlayer=%.0f scale=%.2f moveMode=%s active=%s%s",
                    label, ticks, inst, loc.X, loc.Y, loc.Z, dz, scaleX, mode, active, census))
            end)
        end)
        return ticks > 24
    end)
end

-- ---------------------------------------------------------------- core sequence

-- pending = { actor, param, pair, holder, armedAt, key }
local pending = nil
-- Global sequence lock: never two evolutions in parallel. A watchdog in check()
-- aborts a stuck sequence after 30s in case an error path ever leaks the lock.
local sequenceRunning = false
local sequenceStartedAt = 0
local currentAbort = nil

-- Only one own pal can be summoned at a time, so the otomo holder is the
-- authoritative source (a FindAllOf scan would also hit ghost actors).
local function findEligible()
    local holder = findHolder(nil)
    if not holder then return nil end
    local actor = nil
    pcall(function() actor = holder:TryGetSpawnedOtomo() end)
    if not (actor and actor:IsValid()) then return nil end
    local param = paramOf(actor)
    if not (param and isOwned(param)) then return nil end
    local id = param:GetCharacterID():ToString()
    local pair = Config.findPair(id)
    if not pair then
        return nil, string.format("%s has no evolution", id)
    end
    local level = 0
    pcall(function() level = param:GetLevel() end)
    if level < pair.minLevel then
        return nil, string.format("%s needs level %d to evolve (currently %d)",
            id, pair.minLevel, level)
    end
    return actor, param, pair, level, holder
end

local function performEvolution(p)
    local actor, param, pair, holder = p.actor, p.param, p.pair, p.holder
    pending = nil
    sequenceRunning = true
    sequenceStartedAt = os.clock()

    -- Capture starting state (diagnostics + snapshot data + in-place staging)
    local level, nickname = 0, ""
    pcall(function() level = param:GetLevel() end)
    pcall(function() nickname = param.SaveParameter.NickName and param.SaveParameter.NickName:ToString() or "" end)
    local key = individualKey(param)
    local talentsBefore = readTalents(param)
    local oldX, oldY, oldZ, oldYaw, oldHalf = nil, nil, nil, 0, 0
    pcall(function()
        local loc = actor:K2_GetActorLocation()
        oldX, oldY, oldZ = loc.X, loc.Y, loc.Z
    end)
    pcall(function() oldYaw = actor:K2_GetActorRotation().Yaw end)
    pcall(function() oldHalf = actor:GetSimpleCollisionHalfHeight() end)
    if not oldHalf or oldHalf <= 0 then
        pcall(function() oldHalf = actor.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    end

    -- The FX prototype is fixed for the whole sequence, even if switched mid-run
    local fx = FX.active()
    local ctx = {
        actor = actor, worldCtx = holder,
        oldX = oldX, oldY = oldY, oldZ = oldZ, oldYaw = oldYaw, oldHalf = oldHalf,
        unfreeze = function(a) setFrozen(a, false) end,
        freeze = function(a) setFrozen(a, true) end,
        fx = {},
    }

    -- Success: reveal animations finish on their own (prototypes clean up their
    -- placeholders in onReveal). Abort: cleanup must tear the staging down.
    -- Prototypes with keepsFrozenUntilDone end the sequence themselves through
    -- ctx.completeOk/completeAbort once their reveal animation is done.
    local function finishOk()
        currentAbort = nil
        sequenceRunning = false
    end
    local function finishAbort()
        currentAbort = nil
        pcall(function() fx.cleanup(ctx) end)
        sequenceRunning = false
    end
    ctx.completeOk = finishOk
    ctx.completeAbort = finishAbort
    currentAbort = finishAbort

    if not (actor:IsValid() and param:IsValid() and holder and holder:IsValid()) then
        Log("Evolution aborted: pal/holder no longer valid")
        finishAbort()
        return
    end

    local mgr = findManager(actor)
    if not mgr then
        Log("Evolution aborted: PalCharacterManager not found")
        finishAbort()
        return
    end
    local handle = nil
    pcall(function() handle = mgr:GetIndividualHandleFromCharacterParameter(param) end)
    if not (handle and handle:IsValid()) then
        Log("Evolution aborted: individual handle unavailable")
        finishAbort()
        return
    end

    -- Take the stone cost BEFORE the sequence (no TOCTOU: anything that fails
    -- before the swap refunds the stone; after the swap it is earned)
    local paidStoneId = nil
    if Config.requireStone then
        local _, stoneId, stoneName = stoneCheck(pair)
        if stoneId then
            if not tryConsumeItems(stoneId, Config.stoneCount) then
                Log(string.format("Evolution aborted: %dx %s not available/consumable",
                    Config.stoneCount, stoneName))
                finishAbort()
                return
            end
            paidStoneId = stoneId
            Log(string.format("%dx %s consumed", Config.stoneCount, stoneName))
        end
    end
    local function refundStone(reason)
        if not paidStoneId then return end
        pcall(function()
            local inv = inventoryData()
            if inv then
                inv:AddItem_ServerInternal(FName(paidStoneId), Config.stoneCount, false, 0.0, true)
                Log("Stone refunded (" .. reason .. ")")
            end
        end)
    end

    Log(string.format("Sequence start: %s Lv%d key=%s fx=%s", pair.from, level, key, FX.get()))
    if Config.devMode then
        local pz = "?"
        pcall(function()
            local p = FindFirstOf("PalPlayerCharacter")
            if p and p:IsValid() then
                local pl = p:K2_GetActorLocation()
                pz = string.format("(%.0f,%.0f,%.0f)", pl.X, pl.Y, pl.Z)
            end
        end)
        Log(string.format("[diag start] old=(%s,%s,%s) yaw=%.0f half=%.0f player=%s",
            tostring(oldX), tostring(oldY), tostring(oldZ), oldYaw or 0, oldHalf or 0, pz))
    end

    -- Phase 1: freeze + dissolve staging (white glow in place; the actor is
    -- hard-hidden right before the teardown so no recall visuals ever show)
    setFrozen(actor, true)
    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() fx.onDissolve(ctx) end)
    playFanfare(actor)

    -- Phase 2: teardown with per-strategy despawn verification. The direct
    -- manager teardown destroys the actor without the holder recall action
    -- (whose ball visuals run on a mesh clone that ignores a hidden actor).
    local recallStrategies = {
        { name = "DirectTeardown", fn = function()
            mgr:DespawnCharacterByHandle(handle, nil)
        end },
        { name = "InactivateCurrentOtomo", fn = function()
            holder:InactivateCurrentOtomo()
        end },
        { name = "PlayerController:InactiveOtomo", fn = function()
            local pc = FindFirstOf("PalPlayerController")
            if pc and pc:IsValid() then pc:InactiveOtomo() end
        end },
    }

    -- Authoritative view: the holder knows whether an otomo is out.
    -- (handle:TryGetIndividualActor stays "valid" after the recall - pooling.)
    local function isDespawned()
        local spawned = nil
        pcall(function() spawned = holder:TryGetSpawnedOtomo() end)
        return not (spawned and spawned:IsValid())
    end

    local proceedAfterDespawn -- forward declaration

    local function tryRecall(i)
        if i > #recallStrategies then
            Log("Despawn not confirmed (all strategies exhausted) - aborting WITHOUT swap")
            if actor:IsValid() then
                pcall(function() actor:SetActorHiddenInGame(false) end)
                pcall(function() actor:SetActorEnableCollision(true) end)
                setFrozen(actor, false)
            end
            refundStone("despawn failed")
            finishAbort()
            return
        end
        local strat = recallStrategies[i]
        local okCall, errCall = pcall(strat.fn)
        Log(string.format("Teardown attempt '%s' call=%s%s", strat.name, tostring(okCall),
            okCall and "" or (" err=" .. tostring(errCall))))
        pollUntil(200, 2000, isDespawned, function(despawned)
            if despawned then
                Log(string.format("Despawn confirmed via '%s'", strat.name))
                proceedAfterDespawn()
            else
                tryRecall(i + 1)
            end
        end)
    end

    proceedAfterDespawn = function()
        -- Phase 3: swap in the despawned state (safest write moment) + verify
        if not param:IsValid() then
            Log("Aborted: parameter invalid after despawn")
            refundStone("parameter invalid")
            finishAbort()
            return
        end
        local okSwap, errSwap = pcall(function()
            param.SaveParameter.CharacterID = FName(pair.to)
            param.SaveParameterMirror.CharacterID = FName(pair.to)
        end)
        local idNow = ""
        pcall(function() idNow = param:GetCharacterID():ToString() end)
        if not okSwap or idNow ~= pair.to then
            Log(string.format("SWAP FAILED (err=%s, id=%s) - no respawn attempt",
                tostring(errSwap), idNow))
            refundStone("swap failed")
            finishAbort()
            return
        end
        applyIvBonus(param)
        pcall(function() param:FullRecoveryHP() end)

        -- Snapshot only AFTER a successful swap (no phantom rollback entries)
        table.insert(snapshots, {
            key = key, from = pair.from, to = pair.to, level = level, nickname = nickname,
            ivHP = talentsBefore.Talent_HP, ivMelee = talentsBefore.Talent_Melee,
            ivShot = talentsBefore.Talent_Shot, ivDefense = talentsBefore.Talent_Defense,
        })
        saveSnapshots()

        -- Belt and braces: destroy the pooled actor even if a fallback strategy
        -- did the recall (idempotent, pcall-guarded)
        pcall(function() mgr:DespawnCharacterByHandle(handle, nil) end)

        -- Normalize the holder state: after a direct manager despawn the
        -- holder still counts the otomo as actively summoned. That half state
        -- makes ActivatePalByHandle a silent no-op and leaves the follow-up
        -- SpawnOtomoByLoad spawn in a broken placement loop (periodic warps
        -- to the trainer anchor at player Z +3000 - the exact state a manual
        -- recall+resummon heals). With the actor already gone this recall is
        -- pure bookkeeping and shows no ball visuals.
        local okInact = pcall(function() holder:InactivateCurrentOtomo() end)
        -- Re-select the slot right away: the inactivation also clears the
        -- current-otomo selection, and ActivateCurrentOtomo silently no-ops
        -- without one (community recipe: SetOtomoSlot + TrySwitchOtomo).
        local okSel = pcall(function()
            local idx = holder:GetSlotIndexByIndividualHandle(handle)
            local pc = FindFirstOf("PalPlayerController")
            pc:SetOtomoSlot(idx)
        end)
        Log(string.format("Holder state cleanup ok=%s reselect ok=%s", tostring(okInact), tostring(okSel)))

        -- Phase 4+5: activation pump with staged reveal
        local expectedClass = "BP_" .. pair.to .. "_C"
        local function isRespawned()
            local a = nil
            pcall(function() a = holder:TryGetSpawnedOtomo() end)
            if not (a and a:IsValid()) then return false end
            -- Hide instantly so the raw spawn is never visible (reveal is
            -- staged). Collision stays ON: the native landing flow needs it,
            -- and it is only switched off for the teleport itself.
            pcall(function() a:SetActorHiddenInGame(true) end)
            local cls = ""
            pcall(function() cls = a:GetClass():GetFullName() end)
            return cls:find(expectedClass, 1, true) ~= nil
        end

        local function revealActor(a)
            pcall(function() a:SetActorHiddenInGame(false) end)
            pcall(function() a:SetActorEnableCollision(true) end)
        end

        local function finishRespawn(success)
            local newActor = nil
            pcall(function() newActor = holder:TryGetSpawnedOtomo() end)
            if success and newActor and newActor:IsValid() then
                -- Move to the evolution spot WHILE still hidden and collision-free:
                -- with collision enabled K2_TeleportTo sweeps and refuses/shifts the
                -- landing when anything blocks. Collision comes back at reveal time.
                if oldX then
                    pcall(function()
                        pcall(function() newActor:K2_DetachFromActor(1, 1, 1) end)
                        pcall(function() newActor:SetActorEnableCollision(false) end)
                        -- The fresh pooled actor still sits at its parking spot far
                        -- under the world here, so its current Z is useless. Anchor
                        -- the new capsule so its feet end up where the old pal
                        -- stood; with unknown capsule sizes lift a bit instead and
                        -- let MOVE_Falling settle it after the unfreeze.
                        local newHalf = 0
                        pcall(function() newHalf = newActor:GetSimpleCollisionHalfHeight() end)
                        if not newHalf or newHalf <= 0 then
                            pcall(function() newHalf = newActor.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
                        end
                        local targetZ = oldZ + 40
                        if (oldHalf or 0) > 0 and newHalf > 0 then
                            targetZ = oldZ - oldHalf + newHalf + 10
                        end
                        local target = { X = oldX, Y = oldY, Z = targetZ }
                        -- pin target for prototypes that keep re-anchoring the actor
                        -- against the games summon/landing logic (see fx digimon)
                        ctx.fx.pin = { x = oldX, y = oldY, z = targetZ }
                        local moved = newActor:K2_TeleportTo(target, { Pitch = 0, Yaw = oldYaw or 0, Roll = 0 })
                        local after = newActor:K2_GetActorLocation()
                        local activeState = "?"
                        pcall(function() activeState = tostring(newActor.bIsPalActiveActor) end)
                        Log(string.format("Reveal teleport moved=%s target=(%.0f,%.0f,%.0f) actual=(%.0f,%.0f,%.0f) halves=%.0f/%.0f active=%s",
                            tostring(moved), oldX, oldY, targetZ, after.X, after.Y, after.Z, oldHalf or 0, newHalf, activeState))
                    end)
                end
                pcall(function() fx.onPreReveal(ctx, newActor) end)
                ExecuteWithDelay(fx.revealDelayMs(), function()
                    ExecuteInGameThread(function()
                        -- refetch: the reference may change after the spawn
                        local a = nil
                        pcall(function() a = holder:TryGetSpawnedOtomo() end)
                        if not (a and a:IsValid()) then a = newActor end
                        if not (a and a:IsValid()) then
                            Log(string.format("EVOLVED (data only): %s -> %s (level %d) - actor missing at reveal; please resummon manually",
                                pair.from, pair.to, level))
                            finishAbort()
                            return
                        end
                        revealActor(a)
                        -- Complete the interrupted activation now (collision back,
                        -- active state, falling): the freeze still holds the pal in
                        -- place until the staging is done, but once unfrozen the
                        -- game no longer treats it as a stuck inactive otomo.
                        completeOtomoActivation(a)
                        local okReveal = pcall(function() fx.onReveal(ctx, a) end)
                        playFanfare(a)
                        Log(string.format("EVOLVED: %s -> %s (level %d)%s - respawn with new model OK",
                            pair.from, pair.to, level,
                            nickname ~= "" and (" '" .. nickname .. "'") or ""))
                        startRevealDiagnostics(holder, pair.to)
                        if fx.keepsFrozenUntilDone and okReveal then
                            -- the prototype ends the sequence via ctx.completeOk/Abort
                            return
                        end
                        setFrozen(a, false)
                        if okReveal then
                            finishOk()
                        else
                            Log("Reveal staging failed - cleaning up")
                            finishAbort()
                        end
                    end)
                end)
            else
                -- failure path: never leave anything invisible behind
                if newActor and newActor:IsValid() then
                    revealActor(newActor)
                    completeOtomoActivation(newActor)
                    setFrozen(newActor, false)
                end
                local cls = ""
                pcall(function()
                    if newActor and newActor:IsValid() then cls = newActor:GetClass():GetFullName() end
                end)
                -- Summon rescue: the holder cleanup cleared the otomo
                -- selection, so without this the summon key stays dead for
                -- the player until a world reload.
                local okRescue = pcall(function()
                    local idx = holder:GetSlotIndexByIndividualHandle(handle)
                    local pc = FindFirstOf("PalPlayerController")
                    pc:SetOtomoSlot(idx)
                    pc:TrySwitchOtomo()
                end)
                Log(string.format("EVOLVED (data only): %s -> %s (level %d) - respawn not confirmed (class '%s' instead of %s); summon rescue ok=%s",
                    pair.from, pair.to, level, cls, expectedClass, tostring(okRescue)))
                finishAbort()
            end
        end

        -- The engine finishes its own placement flow (trainer anchor at
        -- player Z +3000, then adjust-to-floor) some time after the spawn.
        -- Touching the actor before that flow is done leaves a pending
        -- placement that warps the pal back to the anchor AFTER our reveal.
        -- Wait until it has landed (MOVE_Walking) or a cap, then stage.
        local function startLandingWatch()
            local watchStart = os.clock()
            local watchDone = false
            LoopAsync(200, function()
                if watchDone then return true end
                ExecuteInGameThread(function()
                    if watchDone then return end
                    local landed, activeFlag = false, false
                    pcall(function()
                        local a = holder:TryGetSpawnedOtomo()
                        activeFlag = (a.bIsPalActiveActor == true)
                        landed = (a.CharacterMovement.MovementMode == 1)
                    end)
                    local waited = os.clock() - watchStart
                    if (landed and activeFlag) or waited > 10 then
                        watchDone = true
                        Log(string.format("Landing %s after %.1fs (landed=%s active=%s)",
                            (landed and activeFlag) and "confirmed" or "timeout - proceeding",
                            waited, tostring(landed), tostring(activeFlag)))
                        finishRespawn(true)
                    end
                end)
                return watchDone
            end)
        end

        -- Activation pump. Root cause of the old hover bug: the holder BP
        -- keeps every spawned-but-not-activated pal in ReservePalLocationList
        -- and per-tick K2_SetActorLocation-warps it to the trainer anchor
        -- (owner + Z offset); only the ActivateOtomo path removes it from the
        -- list. SpawnOtomoByLoad only spawns (into the list), so the pal kept
        -- warping forever. ActivateCurrentOtomo with an explicit transform
        -- runs the full activate path at our position - the engine silently
        -- rejects it until an internal settle completes, so retry until the
        -- actor shows up. Verify every 100ms so the spawn is hidden instantly.
        local startedAt = os.clock()
        local lastNudge = startedAt - 1.2 -- first attempt after ~0.8s
        local nudgeCount = 0
        local pumpDone = false
        pcall(function() fx.onGap(ctx) end)
        LoopAsync(100, function()
            if pumpDone then return true end
            ExecuteInGameThread(function()
                if pumpDone then return end
                if isRespawned() then
                    pumpDone = true
                    startLandingWatch()
                    return
                end
                local now = os.clock()
                if (now - startedAt) > 25 then
                    pumpDone = true
                    finishRespawn(false)
                    return
                end
                if (now - lastNudge) >= 2.5 then
                    lastNudge = now
                    nudgeCount = nudgeCount + 1
                    -- Strategy ladder, cycled - this exact mix produced the
                    -- only healthy spawn so far (ActivateCurrentOtomo as
                    -- attempt #6, ~13s in, landing at our transform): some of
                    -- the other calls evidently prime holder state that the
                    -- activation needs, because pure ActivateCurrentOtomo
                    -- retries stay dead for 25s. Instrumented with return
                    -- value and holder state per attempt to nail down WHICH
                    -- precondition unblocks it.
                    local how, okNudge, ret
                    local step = ((nudgeCount - 1) % 4) + 1
                    if step == 1 and oldX then
                        how = "ActivatePalByHandle"
                        okNudge = pcall(function()
                            holder:ActivatePalByHandle(handle,
                                { X = oldX, Y = oldY, Z = (oldZ or 0) + 50 },
                                { Pitch = 0, Yaw = oldYaw or 0, Roll = 0 }, true)
                        end)
                    elseif step == 2 and oldX then
                        how = "ActivateCurrentOtomo"
                        okNudge = pcall(function()
                            ret = holder:ActivateCurrentOtomo({
                                Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                                Translation = { X = oldX, Y = oldY, Z = (oldZ or 0) + 50 },
                                Scale3D = { X = 1, Y = 1, Z = 1 },
                            })
                        end)
                    elseif step == 3 then
                        how = "ActivateCurrentOtomoNearThePlayer"
                        okNudge = pcall(function()
                            ret = holder:ActivateCurrentOtomoNearThePlayer()
                        end)
                    else
                        how = "SpawnOtomoByLoad"
                        okNudge = pcall(function()
                            local idx = holder:GetSlotIndexByIndividualHandle(handle)
                            holder:SpawnOtomoByLoad(idx)
                        end)
                    end
                    local st = ""
                    pcall(function()
                        st = string.format(" slot=%s actSel=%s",
                            tostring(holder:GetSlotIndexByIndividualHandle(handle)),
                            tostring(holder:IsActivatedSelectOtomo()))
                    end)
                    pcall(function() fx.onGap(ctx) end)
                    Log(string.format("Activation attempt #%d (%s) ok=%s ret=%s%s",
                        nudgeCount, how, tostring(okNudge), tostring(ret), st))
                end
            end)
            return pumpDone
        end)
    end

    -- Start the teardown only AFTER the dissolve staging; the actor is
    -- hard-hidden right before it so no despawn visuals are ever seen
    local dissolveMs = 1200
    pcall(function()
        if fx.dissolveDurationMs then dissolveMs = fx.dissolveDurationMs() end
    end)
    ExecuteWithDelay(dissolveMs, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                if actor:IsValid() then
                    pcall(function() fx.onHide(ctx) end)
                    pcall(function() actor:SetActorHiddenInGame(true) end)
                    pcall(function() actor:SetActorEnableCollision(false) end)
                end
                tryRecall(1)
            end)
            if not ok then
                Log("Teardown start FAIL: " .. tostring(err))
                refundStone("sequence error")
                finishAbort()
            end
        end)
    end)
end

-- ---------------------------------------------------------------- public API

function Evolution.check()
    if sequenceRunning then
        if (os.clock() - sequenceStartedAt) > 30 then
            Log("Sequence lock stuck (>30s) - watchdog aborting the sequence")
            if currentAbort then
                pcall(currentAbort)
            else
                sequenceRunning = false
            end
        else
            Log("An evolution is already running - please wait")
            return
        end
    end
    local actor, param, pair, level, holder = findEligible()
    if not actor then
        if not pending then
            -- second return value carries the reason message when present
            Log(param or "No own pal summoned")
        end
        return
    end

    -- Stone cost check (only active with requireStone=true)
    local stoneOk, _, stoneName = stoneCheck(pair)
    if not stoneOk then
        Log(string.format("%s (Lv %d) could evolve into %s, but missing: %dx %s",
            pair.from, level, pair.to, Config.stoneCount, stoneName))
        return
    end

    local now = os.clock()
    local key = individualKey(param)
    if pending and (now - pending.armedAt) <= Config.confirmWindowSeconds then
        if pending.key == key then
            -- use FRESH handles (the pal may have been resummoned since arming)
            performEvolution({ actor = actor, param = param, pair = pair, holder = holder, key = key })
            return
        else
            Log(string.format("Confirm target changed (was %s, now %s) - re-armed", pending.key, key))
        end
    end
    pending = { actor = actor, param = param, pair = pair, holder = holder, armedAt = now, key = key }
    playFanfare(actor)
    local costHint = ""
    if Config.requireStone and stoneName then
        costHint = string.format(" [cost: %dx %s]", Config.stoneCount, stoneName)
    end
    Log(string.format("%s (Lv %d) can evolve into %s%s - press %s again to confirm (%ds)",
        pair.from, level, pair.to, costHint, Config.confirmKey, Config.confirmWindowSeconds))
end

function Evolution.rollbackLast()
    if sequenceRunning then
        Log("Rollback blocked: an evolution is currently running")
        return
    end
    -- Remove the snapshot only AFTER a verified restore (no data loss on failure)
    local last = snapshots[#snapshots]
    if not last then
        Log("Rollback: no snapshot available")
        return
    end
    local reverted = false
    local all = FindAllOf("PalIndividualCharacterParameter") or {}
    local hasKey = last.key and last.key ~= ""
    for _, p in ipairs(all) do
        if p:IsValid() and isOwned(p) and p:GetCharacterID():ToString() == last.to then
            -- With a key only the exact match counts (a species fallback could
            -- hit the wrong individual, e.g. SmallYeti->Yeti vs MopKing->Yeti)
            local match = hasKey and (individualKey(p) == last.key) or (not hasKey)
            if match then
                pcall(function()
                    p.SaveParameter.CharacterID = FName(last.from)
                    p.SaveParameterMirror.CharacterID = FName(last.from)
                end)
                local idNow = ""
                pcall(function() idNow = p:GetCharacterID():ToString() end)
                if idNow == last.from then
                    local restore = {
                        Talent_HP = last.ivHP, Talent_Melee = last.ivMelee,
                        Talent_Shot = last.ivShot, Talent_Defense = last.ivDefense,
                    }
                    for field, v in pairs(restore) do
                        if v and v >= 0 then
                            pcall(function()
                                p.SaveParameter[field] = v
                                p.SaveParameterMirror[field] = v
                            end)
                        end
                    end
                    reverted = true
                end
                break
            end
        end
    end
    if reverted then
        table.remove(snapshots)
        saveSnapshots()
        Log(string.format("Rollback %s -> %s: restored including IVs (resummon to see the model)",
            last.to, last.from))
    else
        Log(string.format("Rollback %s -> %s: no matching pal found (snapshot kept; bring the pal nearby and retry)",
            last.to, last.from))
    end
end

function Evolution.init()
    loadSnapshots()
    FX.init(Config.fxPrototype)

    local lastPress = 0
    RegisterKeyBind(Key[Config.confirmKey], function()
        local now = os.clock()
        if (now - lastPress) < Config.debounceSeconds then return end
        lastPress = now
        ExecuteInGameThread(function()
            local ok, err = pcall(Evolution.check)
            if not ok then Log("check FAIL: " .. tostring(err)) end
        end)
    end)

    -- Level-up notification: fires ONCE per individual and target once the
    -- threshold is reached
    local notified = {}
    local hookRegistered = false
    local function tryHook()
        if hookRegistered then return true end
        local ok = pcall(RegisterHook,
            "/Game/Pal/Blueprint/Character/Monster/BP_MonsterBase.BP_MonsterBase_C:OnUpdateLevelDelegate_イベント_0",
            function(self, addLevel, nowLevel)
                pcall(function()
                    local actor = self:get()
                    local param = actor.CharacterParameterComponent:GetIndividualParameter()
                    if not isOwned(param) then return end
                    local id = param:GetCharacterID():ToString()
                    local pair = Config.findPair(id)
                    if not pair then return end
                    -- nowLevel is the level BEFORE the addition (verified live)
                    local newLevel = nowLevel:get() + addLevel:get()
                    if newLevel >= pair.minLevel then
                        -- key includes the target so the next chain stage
                        -- (e.g. MopKing->Yeti) notifies again after evolving
                        local key = individualKey(param) .. ">" .. pair.to
                        if notified[key] then return end
                        notified[key] = true
                        playFanfare(actor)
                        Log(string.format("%s reached level %d and can evolve into %s! (press %s)",
                            id, newLevel, pair.to, Config.confirmKey))
                    end
                end)
            end)
        hookRegistered = ok
        return ok
    end
    if not tryHook() then
        LoopAsync(5000, function()
            if hookRegistered then return true end
            ExecuteInGameThread(function() tryHook() end)
            return hookRegistered
        end)
    end

    -- Console: "palvolve check|rollback|fx <name>"
    pcall(function()
        RegisterConsoleCommandHandler("palvolve", function(fullCommand, parameters)
            local sub = parameters[1] or "check"
            local arg = parameters[2]
            ExecuteInGameThread(function()
                local ok, err = pcall(function()
                    if sub == "rollback" then
                        Evolution.rollbackLast()
                    elseif sub == "fx" then
                        if arg and FX.set(arg) then
                            Log("FX prototype set to '" .. arg .. "'")
                        else
                            Log(string.format("FX prototypes: %s (active: %s)",
                                table.concat(FX.list(), ", "), FX.get()))
                        end
                    else
                        Evolution.check()
                    end
                end)
                if not ok then Log("Console FAIL: " .. tostring(err)) end
            end)
            return true
        end)
    end)

    Log(string.format("Evolution core active: %s = check/confirm, console: palvolve check|rollback|fx <name> (FX: %s)",
        Config.confirmKey, FX.get()))
end

return Evolution
