-- Palvolve core: eligibility, two-stage confirm, transactional species swap,
-- snapshots/rollback, IV bonus and the staged evolution sequence.
-- API facts: Workspace/docs/Palvolve/RESEARCH.md. Sequence design: direct manager
-- teardown first (the holder recall animates a mesh clone that ignores a hidden
-- actor and is therefore only a fallback), species swap while despawned,
-- two-phase activation pump with class-verified respawn, staged reveal driven
-- by the FX staging (fx.lua).

local Config = require("config")
local FX = require("fx")
local Costs = require("costs")
local Elements = require("elements")

local Evolution = {}

local MOD_NAME = "Palvolve"

-- Snapshot file next to the mod (derived from this script's location so the
-- path works regardless of the game's working directory); falls back to the
-- manual-install layout relative to Win64.
local STATE_FILE = (function()
    local path = nil
    pcall(function()
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) == "@" then
            local dir = src:sub(2):match("^(.*)[/\\]")          -- .../Palvolve/scripts
            local root = dir and dir:match("^(.*)[/\\]") or nil -- .../Palvolve
            if root then path = root .. "\\palvolve_state.lua" end
        end
    end)
    return path or "ue4ss\\Mods\\Palvolve\\palvolve_state.lua"
end)()

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

-- Failure-path rescue ONLY: the success path gets a landed and active actor
-- from the two-phase SpawnOtomoByLoad + ActivateCurrentOtomo flow and must
-- not run this (forcing movement state made the revealed pal fight the
-- staged spin). An actor left behind by a FAILED respawn is of unknown
-- activation state though - finish the activation the vanilla summon flow
-- would have done so it does not linger as an inactive ghost.
local function completeOtomoActivation(palActor)
    pcall(function() palActor.ActionComponent:CancelAllAction() end)
    pcall(function() palActor:SetActiveActor(true) end)
    pcall(function() palActor:SetActiveCollisionMovement(true) end)
    pcall(function() palActor.CharacterMovement:SetMovementMode(3, 0) end)
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

local TALENT_LABELS = {
    Talent_HP = "HP", Talent_Melee = "Melee",
    Talent_Shot = "Shot", Talent_Defense = "Defense",
}

local function applyIvBonus(param)
    local parts = {}
    for _, field in ipairs(TALENT_FIELDS) do
        local ok = pcall(function()
            local cur = param.SaveParameter[field]
            local new = math.min(cur + Config.ivBonusPerStage, Config.ivCap)
            param.SaveParameter[field] = new
            param.SaveParameterMirror[field] = new
            table.insert(parts, string.format("%s +%d", TALENT_LABELS[field] or field, new - cur))
        end)
        if not ok then
            Log("IV bonus for " .. field .. " could not be applied - a game update may have changed this field")
        end
    end
    if #parts > 0 then Log("Evolution bonus (IVs): " .. table.concat(parts, ", ")) end
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

-- pending = { armedAt, key, pair } - the armed confirm state; the confirm
-- press always fetches FRESH handles via findEligible()
local pending = nil
-- Global sequence lock: never two evolutions in parallel. A watchdog aborts a
-- stuck sequence once its per-run budget (derived from the configured phase
-- timings) has elapsed, in case an error path ever leaks the lock.
local sequenceRunning = false
local sequenceStartedAt = 0
local sequenceBudgetS = 30
local currentAbort = nil

-- Frees a stuck lock (budget exceeded); returns true while the lock is busy.
local function lockBusy()
    if not sequenceRunning then return false end
    if (os.clock() - sequenceStartedAt) > sequenceBudgetS then
        Log("Sequence lock stuck - watchdog aborting the sequence")
        if currentAbort then pcall(currentAbort) else sequenceRunning = false end
        return sequenceRunning
    end
    return true
end

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

    -- Per-run cancellation token: once done is set (success, abort or
    -- watchdog), every still-pending async callback of THIS run bails out
    -- instead of mutating a finished or foreign sequence.
    local seq = { done = false }

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

    local fx = FX
    local ctx = {
        actor = actor, worldCtx = holder,
        oldX = oldX, oldY = oldY, oldZ = oldZ, oldYaw = oldYaw, oldHalf = oldHalf,
        unfreeze = function(a) setFrozen(a, false) end,
        freeze = function(a) setFrozen(a, true) end,
        -- element tints: dissolve/peak use the old form's color, the reveal
        -- uses the target's - for adaptations the ADAPTED element (Penking
        -- Lux reveals electric-yellow, not its water primary). nil =
        -- uncolored, the plain white look.
        colorFrom = Elements.colorFor(Elements.primary(pair.from, holder)),
        colorTo = Elements.colorFor(
            pair.stone == "adaptation" and Elements.adaptationElement(pair, holder)
            or Elements.primary(pair.to, holder)),
        fx = {},
    }

    -- Watchdog budget for this run: dissolve + teardown strategies + pump
    -- timeout + landing cap + reveal, plus the fx-driven post-reveal phase
    -- for keepsFrozenUntilDone prototypes, plus margin.
    pcall(function()
        local budget = (fx.dissolveDurationMs and fx.dissolveDurationMs() or 1200) / 1000
        budget = budget + 6 + 25 + 10 + (fx.revealDelayMs() / 1000)
        if fx.keepsFrozenUntilDone then
            local c = Config.digimon or {}
            budget = budget + ((c.growMs or 1600) + (c.finaleHoldMs or 3000)) / 1000
        end
        sequenceBudgetS = budget + 10
    end)

    -- Cost transaction: consumed upfront, refunded exactly once on any abort
    -- that happens before the verified species swap; earned afterwards.
    local txn = nil
    local swapDone = false
    local function refundCost(reason)
        if txn and not swapDone then txn.refund(reason) end
    end

    -- Success: reveal animations finish on their own (the staging cleans up
    -- in its own reveal driver). Abort: cleanup must tear the staging down
    -- and the cost is refunded unless the swap already committed. Both are
    -- idempotent; the first one to run wins. keepsFrozenUntilDone stagings
    -- end the sequence themselves through ctx.completeOk/completeAbort.
    local function finishOk()
        if seq.done then return end
        seq.done = true
        currentAbort = nil
        sequenceRunning = false
    end
    local function finishAbort()
        if seq.done then return end
        seq.done = true
        currentAbort = nil
        pcall(function() fx.cleanup(ctx) end)
        refundCost("evolution aborted")
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

    -- Take the full cost BEFORE the sequence (no TOCTOU: anything that fails
    -- before the swap refunds everything; after the swap it is earned)
    local costList = Costs.resolve(pair, level, holder)
    if #costList > 0 then
        local failedItem
        txn, failedItem = Costs.beginTransaction(costList)
        if not txn then
            Log(string.format("Evolution aborted: %dx %s not available/consumable",
                failedItem and failedItem.count or 0, failedItem and failedItem.label or "?"))
            finishAbort()
            return
        end
        Log("Cost taken: " .. Costs.describe(costList))
    end

    Log(string.format("Evolving %s (Lv %d)...", pair.from, level))
    if Config.devMode then
        local pz = "?"
        pcall(function()
            local p = FindFirstOf("PalPlayerCharacter")
            if p and p:IsValid() then
                local pl = p:K2_GetActorLocation()
                pz = string.format("(%.0f,%.0f,%.0f)", pl.X, pl.Y, pl.Z)
            end
        end)
        Log(string.format("[diag start] key=%s old=(%s,%s,%s) yaw=%.0f half=%.0f player=%s",
            key, tostring(oldX), tostring(oldY), tostring(oldZ), oldYaw or 0, oldHalf or 0, pz))
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
            refundCost("despawn failed")
            finishAbort()
            return
        end
        local strat = recallStrategies[i]
        local okCall, errCall = pcall(strat.fn)
        if Config.devMode or not okCall then
            Log(string.format("Teardown attempt '%s' call=%s%s", strat.name, tostring(okCall),
                okCall and "" or (" err=" .. tostring(errCall))))
        end
        pollUntil(200, 2000, isDespawned, function(despawned)
            if seq.done then return end
            if despawned then
                if Config.devMode then
                    Log(string.format("Despawn confirmed via '%s'", strat.name))
                end
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
            refundCost("parameter invalid")
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
            refundCost("swap failed")
            finishAbort()
            return
        end
        swapDone = true
        if txn then txn.commit() end
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
        -- makes the follow-up activation a silent no-op and leaves a forced
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
        if not (okInact and okSel) then
            Log(string.format("Holder state cleanup FAILED (inactivate=%s reselect=%s) - activation may stall",
                tostring(okInact), tostring(okSel)))
        elseif Config.devMode then
            Log(string.format("Holder state cleanup ok=%s reselect ok=%s", tostring(okInact), tostring(okSel)))
        end

        -- Phase 4+5: activation pump with staged reveal
        local expectedClass = "BP_" .. pair.to .. "_C"
        local function isRespawned()
            local a = nil
            pcall(function() a = holder:TryGetSpawnedOtomo() end)
            if not (a and a:IsValid()) then return false end
            local cls = ""
            pcall(function() cls = a:GetClass():GetFullName() end)
            if not cls:find(expectedClass, 1, true) then return false end
            -- Hide instantly so the raw spawn is never visible (reveal is
            -- staged). Collision stays ON: the native landing flow needs it,
            -- and it is only switched off for the teleport itself.
            pcall(function() a:SetActorHiddenInGame(true) end)
            return true
        end

        local function revealActor(a)
            pcall(function() a:SetActorHiddenInGame(false) end)
            pcall(function() a:SetActorEnableCollision(true) end)
        end

        local function finishRespawn(success)
            if seq.done then return end
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
                        -- Anchor the new capsule so its feet end up where the
                        -- old pal stood; with unknown capsule sizes lift a bit
                        -- instead and let gravity settle it after the unfreeze.
                        local newHalf = 0
                        pcall(function() newHalf = newActor:GetSimpleCollisionHalfHeight() end)
                        if not newHalf or newHalf <= 0 then
                            pcall(function() newHalf = newActor.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
                        end
                        local targetZ = oldZ + 40
                        if (oldHalf or 0) > 0 and newHalf > 0 then
                            targetZ = oldZ - oldHalf + newHalf + 10
                            ctx.newHalf = newHalf
                        end
                        local target = { X = oldX, Y = oldY, Z = targetZ }
                        local moved = newActor:K2_TeleportTo(target, { Pitch = 0, Yaw = oldYaw or 0, Roll = 0 })
                        if Config.devMode then
                            local after = newActor:K2_GetActorLocation()
                            local activeState = "?"
                            pcall(function() activeState = tostring(newActor.bIsPalActiveActor) end)
                            Log(string.format("Reveal teleport moved=%s target=(%.0f,%.0f,%.0f) actual=(%.0f,%.0f,%.0f) halves=%.0f/%.0f active=%s",
                                tostring(moved), oldX, oldY, targetZ, after.X, after.Y, after.Z, oldHalf or 0, newHalf, activeState))
                        end
                    end)
                end
                pcall(function() fx.onPreReveal(ctx, newActor) end)
                ExecuteWithDelay(fx.revealDelayMs(), function()
                    ExecuteInGameThread(function()
                        if seq.done then return end
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
                        -- No activation fixup here: the pal arrives landed
                        -- and active through the clean two-phase activation,
                        -- and forcing movement state made the character
                        -- visibly fight the staged reveal spin.
                        local okReveal = pcall(function() fx.onReveal(ctx, a) end)
                        playFanfare(a)
                        Log(string.format("EVOLVED: %s -> %s (level %d)%s",
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

        -- The pump has already activated the pal at our position; the engine's
        -- brief settle finishes moments later (grounded or flying, active).
        -- Wait for that state (or a 10s cap) so the hidden teleport and staged
        -- reveal never race the in-flight settle, then stage.
        local function startLandingWatch()
            local watchStart = os.clock()
            local watchDone = false
            LoopAsync(200, function()
                if watchDone then return true end
                ExecuteInGameThread(function()
                    if watchDone then return end
                    if seq.done then
                        watchDone = true
                        return
                    end
                    local landed, activeFlag = false, false
                    pcall(function()
                        local a = holder:TryGetSpawnedOtomo()
                        activeFlag = (a.bIsPalActiveActor == true)
                        local mode = a.CharacterMovement.MovementMode
                        landed = (mode == 1 or mode == 5) -- Walking or Flying (hoverers)
                    end)
                    local waited = os.clock() - watchStart
                    if (landed and activeFlag) or waited > 10 then
                        watchDone = true
                        if Config.devMode or not (landed and activeFlag) then
                            Log(string.format("Landing %s after %.1fs (landed=%s active=%s)",
                                (landed and activeFlag) and "confirmed" or "timeout - proceeding",
                                waited, tostring(landed), tostring(activeFlag)))
                        end
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
        local lastNudge = startedAt - 1.2 -- first attempt after ~0.3s
        local nudgeCount = 0
        local pumpDone = false
        pcall(function() fx.onGap(ctx) end)
        LoopAsync(100, function()
            if pumpDone then return true end
            ExecuteInGameThread(function()
                if pumpDone then return end
                if seq.done then
                    pumpDone = true
                    return
                end
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
                if (now - lastNudge) >= 1.5 then
                    lastNudge = now
                    nudgeCount = nudgeCount + 1
                    -- Two-phase respawn (proven via return-value telemetry):
                    -- 1. SpawnOtomoByLoad CREATES the fresh actor - it sits in
                    --    the holders ReservePalLocationList, invisible to
                    --    TryGetSpawnedOtomo, so no spawn is "seen" yet.
                    -- 2. ActivateCurrentOtomo(transform) returns false while
                    --    no actor exists and true once it activates the
                    --    reserve actor AT OUR POSITION (landed+active 0.2s
                    --    later, no trainer-anchor placement).
                    -- Re-fire the load every 5th attempt in case the first
                    -- one raced the engines teardown settle.
                    local how, okNudge, ret
                    if nudgeCount == 1 or (nudgeCount % 5 == 0) then
                        how = "SpawnOtomoByLoad"
                        okNudge = pcall(function()
                            local idx = holder:GetSlotIndexByIndividualHandle(handle)
                            holder:SpawnOtomoByLoad(idx)
                        end)
                    else
                        how = "ActivateCurrentOtomo"
                        okNudge = pcall(function()
                            ret = holder:ActivateCurrentOtomo({
                                Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                                Translation = { X = oldX or 0, Y = oldY or 0, Z = (oldZ or 0) + 50 },
                                Scale3D = { X = 1, Y = 1, Z = 1 },
                            })
                        end)
                        -- Hide in the SAME game-thread tick: the activation
                        -- places the pal full-size at our spot, and waiting
                        -- for the next verify poll (100ms) shows it as a
                        -- brief flash before the staged tiny-grow reveal.
                        if ret == true then
                            pcall(function()
                                local a = holder:TryGetSpawnedOtomo()
                                a:SetActorHiddenInGame(true)
                            end)
                        end
                    end
                    pcall(function() fx.onGap(ctx) end)
                    if Config.devMode then
                        Log(string.format("Activation attempt #%d (%s) ok=%s ret=%s",
                            nudgeCount, how, tostring(okNudge), tostring(ret)))
                    end
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
            if seq.done then return end
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
                refundCost("sequence error")
                finishAbort()
            end
        end)
    end)
end

-- ---------------------------------------------------------------- public API

function Evolution.check()
    if lockBusy() then
        Log("An evolution is already running - please wait")
        return
    end
    local actor, param, pair, level, holder = findEligible()
    if not actor then
        if not pending then
            -- second return value carries the reason message when present
            Log(param or "No own pal summoned")
        end
        return
    end

    -- Full cost check (stone + materials); lists every missing item
    local costList = Costs.resolve(pair, level, holder)
    local costOk, missing = Costs.check(costList)
    if not costOk then
        Log(string.format("%s (Lv %d) could evolve into %s, but missing: %s",
            pair.from, level, pair.to, Costs.describeMissing(missing)))
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
            Log(string.format("Confirm target changed (was %s, now %s) - re-armed",
                pending.pair and pending.pair.from or "?", pair.from))
        end
    end
    pending = { armedAt = now, key = key, pair = pair }
    playFanfare(actor)
    local costHint = ""
    if #costList > 0 then
        costHint = string.format(" [cost: %s]", Costs.describe(costList))
    end
    Log(string.format("%s (Lv %d) can evolve into %s%s - press %s again to confirm (%ds)",
        pair.from, level, pair.to, costHint, Config.confirmKey, Config.confirmWindowSeconds))
end

function Evolution.rollbackLast()
    if lockBusy() then
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
                    -- mirror the forward path: normalize HP after the
                    -- species/IV change (current HP may exceed the smaller
                    -- form's maximum otherwise)
                    pcall(function() p:FullRecoveryHP() end)
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

    -- One-time runtime capability probes once a world is loaded: they pin the
    -- baked-table fallbacks when the out-param marshaling of the database
    -- accessors is unusable in this UE4SS build ([probe-dropdata] /
    -- [probe-elementtype]).
    local probed = false
    LoopAsync(3000, function()
        if probed then return true end
        ExecuteInGameThread(function()
            if probed then return end
            local holder = findHolder(nil)
            if holder then
                probed = true
                pcall(function() Elements.probeRuntime(holder) end)
                pcall(function() Costs.probeRuntime(holder) end)
            end
        end)
        return probed
    end)

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
                    -- nowLevel is the level BEFORE the addition
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

    -- Console: "palvolve check|rollback|radial"
    pcall(function()
        RegisterConsoleCommandHandler("palvolve", function(fullCommand, parameters)
            local sub = parameters[1] or "check"
            ExecuteInGameThread(function()
                local ok, err = pcall(function()
                    if sub == "rollback" then
                        Evolution.rollbackLast()
                    elseif sub == "radial" and Config.devMode then
                        require("probes").armRadialProbes()
                    else
                        Evolution.check()
                    end
                end)
                if not ok then Log("Console FAIL: " .. tostring(err)) end
            end)
            return true
        end)
    end)

    Log(string.format("Evolution core active: %s = check/confirm, console: palvolve check|rollback",
        Config.confirmKey))
end

return Evolution
