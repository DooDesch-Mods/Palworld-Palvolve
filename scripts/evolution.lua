-- Palvolve core: eligibility, two-stage confirm, transactional species swap,
-- snapshots/rollback, IV bonus and the staged evolution sequence.
-- Sequence design: direct manager teardown first (the holder recall animates
-- a mesh clone that ignores a hidden actor and is therefore only a fallback),
-- species swap while despawned, two-phase activation pump with a
-- species-id-checked respawn, staged reveal driven by the FX staging (fx.lua).
-- Helpers, per-Pal state, the wheel entries, the sequence lock, the remote
-- replay and the auto-evolve watcher live in the evo_*.lua modules.

local Config = require("config")
local FX = require("fx")
local Costs = require("costs")
local Elements = require("elements")
local Conditions = require("conditions")
local I18n = require("i18n")
local RemotePresentation = require("remote_presentation")
local Role = require("role")
local Authority = require("authority")
local NetChannel = require("netchannel")
local ServerCheck = require("servercheck")
local PalPassives = require("palpassives")
local PrestigeRecipes = require("prestige_recipes")
local Timing = require("sequence_timing")
local WazaInherit = require("wazainherit")
local PalSlots = require("palslots")
local Prestige = require("prestige")
local Sound = require("sound")
local GameLoop = require("gameloop")
local Ride = require("ride")
local FusionRules = require("fusionrules")
local EvoUtil = require("evo_util")
local EvoNames = require("evo_names")
local EvoSnap = require("evo_snap")
local EvoPresent = require("evo_present")
local EvoState = require("evo_state")
local EvoLock = require("evo_lock")
local EvoWheel = require("evo_wheel")
local EvoRemote = require("evo_remote")
local EvoAuto = require("evo_auto")

local Evolution = {}

local MOD_NAME = "Palvolve"

local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- ---------------------------------------------------------------- utilities

-- Exported for the guide pages, which name every species in the configured
-- tree and must use the same localized names the wheel shows.
Evolution.displayName = EvoNames.palDisplayName

-- ---------------------------------------------------------------- snapshots (rollback)

-- ---------------------------------------------------------------- sound

-- ---------------------------------------------------------------- IV bonus

-- ---------------------------------------------------------------- polling helper

-- ---------------------------------------------------------------- diagnostics

-- ---------------------------------------------------------------- core sequence

-- pending = { armedAt, key, pair } - the armed confirm state; the confirm
-- press always fetches FRESH handles via findEligibleFor()
local pending = nil
-- the pair a connected client last requested over the net channel, so the
-- host's success ack can drive the local reveal (Evolution.playRemoteReveal)
local lastRemotePair = nil

--- True while the mod's timed steps are still being delivered.
function Evolution.timersAlive()
    return not EvoLock.timersDead()
end

-- Only one own pal can be summoned at a time, so the otomo holder is the
-- authoritative source (a FindAllOf scan would also hit ghost actors).
local function findEligibleFor(playerCtx)
    local holder = EvoUtil.findHolderFor(playerCtx, nil)
    if not holder then return nil end
    local actor = nil
    pcall(function() actor = holder:TryGetSpawnedOtomo() end)
    if not (actor and actor:IsValid()) then return nil end
    local param = EvoUtil.paramOf(actor)
    if not (param and EvoUtil.isOwnedBy(param, playerCtx and playerCtx.playerUId)) then return nil end
    local id, isAlpha = EvoUtil.baseCharacterId(param:GetCharacterID():ToString())
    -- pick the first pair that passes EVERY gate (alpha form, level,
    -- conditions), so a branched species whose first target is blocked
    -- still reaches its other options
    local pairList, isPrestige, prestigeErr = EvoState.optionPairsFor(id, param)
    if isPrestige and EvoState.prestigeAtMax(param) then
        return nil, I18n.msg("prestigeAtMax", EvoNames.palDisplayName(id))
    end
    if not pairList or #pairList == 0 then
        if prestigeErr then Log("Prestige targets unavailable: " .. tostring(prestigeErr)) end
        if isPrestige then return nil, I18n.msg("hasNoPrestige", EvoNames.palDisplayName(id)) end
        return nil, I18n.msg("hasNoEvolution", EvoNames.palDisplayName(id))
    end
    local level = 0
    pcall(function() level = param:GetLevel() end)
    if Config.devMode then
        -- Which Pal the authority actually looked at. A rejection that names a
        -- level the player does not recognise is usually a different Pal than
        -- the one they had in mind, and the id alone does not say which.
        local nick, uid = "", ""
        pcall(function() nick = tostring(param:GetNickname():ToString()) end)
        pcall(function() uid = tostring(param.IndividualId.InstanceId):sub(1, 8) end)
        Log(string.format("[evolve] evaluating %s lv %d (nick '%s', uid %s)",
            tostring(id), level, nick, uid))
    end
    local condCtx = { actor = actor, param = param, playerCtx = playerCtx, holder = holder }
    local pair, pairIndex, firstReason, alphaBlockedTo = nil, nil, nil, nil
    local pairConditionCount = -1
    -- First target that only lacks materials, kept as the fallback: if nothing
    -- is affordable, its missing list is the useful thing to report.
    local unpaid, unpaidIndex = nil, nil
    for i, cand in ipairs(pairList) do
        local unknownReason = EvoUtil.unknownConditionReason(cand)
        if unknownReason then
            firstReason = firstReason or unknownReason
        elseif isAlpha and not EvoUtil.swapTargetId(cand, true) then
            alphaBlockedTo = alphaBlockedTo or cand.to
        elseif level < EvoState.requiredLevelFor(cand, param) then
            firstReason = firstReason or I18n.msg(
                EvoState.isPrestigePair(cand) and "needsLevelPrestige" or "needsLevel",
                EvoNames.palDisplayName(id), EvoState.requiredLevelFor(cand, param), level)
        else
            local condOk, unmet = Conditions.evaluate(cand, condCtx)
            if not condOk and EvoState.AutoUnlock.has(param, cand.to) then condOk = true end
            if condOk then
                -- The cost belongs in this loop. Checked only afterwards, a
                -- species whose first target lacks a stone reported that stone
                -- and never mentioned the target the player could pay for.
                -- A cost check that throws leaves the target open: the
                -- transaction in performEvolution is the authoritative consume
                -- and refuses what cannot be paid.
                local affordable = true
                local okCost, costErr = pcall(function()
                    affordable = (Costs.check(playerCtx, Costs.resolve(cand, level, holder)))
                end)
                if not okCost then
                    Log(string.format("[WARN] cost check for %s -> %s failed, the transaction decides: %s",
                        tostring(cand.from), tostring(cand.to), tostring(costErr)))
                end
                if affordable then
                    local count = EvoUtil.conditionCount(cand)
                    if Config.evolutionMode ~= "conditioned" or count > pairConditionCount then
                        pair = cand
                        pairIndex = EvoState.pairIndexFor(cand, i)
                        pairConditionCount = count
                    end
                    if Config.evolutionMode ~= "conditioned" then break end
                end
                if not unpaid or (Config.evolutionMode == "conditioned"
                    and EvoUtil.conditionCount(cand) > EvoUtil.conditionCount(unpaid)) then
                    unpaid, unpaidIndex = cand, i
                end
            else
                firstReason = firstReason or I18n.msg("needsConditions",
                    EvoNames.palDisplayName(cand.to), EvoUtil.disclosedConditions(cand, unmet))
            end
        end
    end
    if not pair and unpaid then
        pair = unpaid
        pairIndex = EvoState.pairIndexFor(unpaid, unpaidIndex)
    end
    if not pair then
        return nil, firstReason
            or I18n.msg("noAlphaForm", EvoNames.palDisplayName(alphaBlockedTo))
    end
    -- pairIndex is the position in Config.findPairs(id), or a prestige pair's
    -- own prestigeIndex - the token a connected client sends over the net channel
    return actor, param, pair, level, holder, isAlpha, pairIndex, EvoState.isPrestigePair(pair)
end

local function performEvolutionNow(p)
    local actor, param, pair, holder = p.actor, p.param, p.pair, p.holder
    local isAlpha = p.isAlpha == true
    local isPrestige = pair.category == "prestige"
    -- the requesting player's context: every controller/pawn access below
    -- must stay scoped to this player (multiplayer hosts serve many)
    local playerCtx = p.playerCtx
    -- On a dedicated server the pal has no locally rendered actor: the reveal
    -- staging (teleport, scale, FX, the respawn pump) operates on actor/physics
    -- state that is unsafe headless and crashed the process. The headless path
    -- does only the authoritative data mutation (swap + IV + snapshot + cost)
    -- and a clean recall; the client re-summons to see the new species.
    local headless = Role.isDedicated()
    pending = nil
    EvoLock.sequenceRunning = true
    EvoLock.sequenceStartedAt = os.clock()

    -- Per-run cancellation token: once done is set (success, abort or
    -- watchdog), every still-pending async callback of THIS run bails out
    -- instead of mutating a finished or foreign sequence.
    local seq = { done = false }

    -- Capture starting state (diagnostics + snapshot data + in-place staging)
    local level, nickname = 0, ""
    pcall(function() level = param:GetLevel() end)
    pcall(function() nickname = param.SaveParameter.NickName and param.SaveParameter.NickName:ToString() or "" end)
    local key = EvoUtil.individualKey(param)
    local talentsBefore = EvoPresent.readTalents(param)
    local oldX, oldY, oldZ, oldYaw, oldHalf = nil, nil, nil, 0, 0
    pcall(function()
        local loc = actor:K2_GetActorLocation()
        oldX, oldY, oldZ = loc.X, loc.Y, loc.Z
    end)
    pcall(function() oldYaw = actor:K2_GetActorRotation().Yaw end)
    -- The engine grounds pals with the SCALED COLLISION capsule (~30 for
    -- most species), NOT with the much larger MeshCapsuleHalfHeight from
    -- the static parameter component (a mesh-space body measure -
    -- LilyQueen: mesh 150 vs collision ~29).
    -- Deriving ground from the mesh value sank targets up to 235 units
    -- into the floor. Collision capsule first; mesh value only as the
    -- last-resort fallback. (GetSimpleCollisionHalfHeight is NOT a
    -- UFunction in this build - never call it.)
    pcall(function()
        local cap = actor.CapsuleComponent
        if cap and cap:IsValid() then
            local h = cap:GetScaledCapsuleHalfHeight()
            if h and h > 0 then oldHalf = h end
        end
    end)
    if not oldHalf or oldHalf <= 0 then
        oldHalf = EvoUtil.staticCapsuleHalf(actor)
    end
    -- Ground truth at the evolution spot: the standing old pal's feet
    -- (center minus scaled collision capsule), refined by the engine's own
    -- floor query when it returns a plausible value (handles hovering
    -- pals). Everything downstream (teleport, grow driver, FX anchors)
    -- hangs off this instead of capsule guesswork.
    local groundZ = nil
    if oldZ and oldHalf and oldHalf > 0 then
        groundZ = oldZ - oldHalf
    end
    pcall(function()
        local u = EvoUtil.palUtility()
        if not u then return end
        local floorLoc = u:GetFloorHitLocationByActor(actor)
        if floorLoc and floorLoc.Z and groundZ
            and math.abs(floorLoc.Z - groundZ) <= 300 then
            groundZ = floorLoc.Z
        end
    end)

    local fx = FX
    local ctx = {
        actor = actor, worldCtx = holder,
        playerPawn = playerCtx and playerCtx.pawn or nil,
        oldX = oldX, oldY = oldY, oldZ = oldZ, oldYaw = oldYaw, oldHalf = oldHalf,
        groundZ = groundZ,
        unfreeze = function(a) EvoPresent.setFrozen(a, false) end,
        freeze = function(a) EvoPresent.setFrozen(a, true) end,
        fx = {},
    }
    if Config.devMode then
        Log(string.format("[diag ground] oldZ=%s oldHalfColl=%.0f groundZ=%s",
            tostring(oldZ), oldHalf or 0, tostring(groundZ)))
    end
    -- element staging: dissolve/peak cycle through ALL of the old form's
    -- elements, the reveal uses the target's - for adaptations only the
    -- ADAPTED element (Penking Lux reveals electric, not its water
    -- primary). The fx layer spawns the matching vanilla element effects;
    -- empty lists = plain look.
    ctx.elemsFrom = Elements.of(pair.from, holder) or {}
    if pair.stone == "adaptation" then
        local adapted = Elements.adaptationElement(pair, holder)
        ctx.elemsTo = adapted and { adapted } or (Elements.of(pair.to, holder) or {})
    else
        ctx.elemsTo = Elements.of(pair.to, holder) or {}
    end
    ctx.colorFrom = Elements.colorFor(ctx.elemsFrom[1])
    ctx.colorTo = Elements.colorFor(ctx.elemsTo[1])
    -- The finale picks its base layer from this. Read off the pair rather than
    -- passed in, so the client side gets the same answer from the synced tree
    -- without another field on the wire.
    ctx.isPrestige = (pair and pair.category == "prestige") or false
    -- A fusion runs the same swap. p.fusion carries what differs: how the Pal is
    -- rewritten, how that is undone, and what happens once it stands.
    ctx.fusionKind = p.fusion and p.fusion.kind or nil
    -- Which prestige programme plays: the Pal's own stage, so the Nth prestige
    -- outdoes the N-1th. Unknown reads as 1 rather than as nothing.
    -- The host's number wins where it is available: the local passive list can
    -- still be the pre-prestige one when this runs on a client.
    ctx.prestigeStage = (pair and tonumber(pair.prestigeStage)) or 1
    if ctx.isPrestige and not (pair and pair.prestigeStage) then
        local probeParam = EvoUtil.paramOf(ctx.actor)
        if probeParam then
            local okStages, stages = pcall(PalPassives.resolve, probeParam)
            if okStages and type(stages) == "table" and stages.prestige
                and (stages.prestige.stage or 0) > 0 then
                ctx.prestigeStage = stages.prestige.stage
            end
        end
    end

    -- Watchdog budget for this run: dissolve + teardown strategies + pump
    -- timeout + landing cap + reveal, plus the fx-driven post-reveal phase
    -- for keepsFrozenUntilDone prototypes, plus margin.
    pcall(function()
        local budget = (fx.dissolveDurationMs and fx.dissolveDurationMs(ctx) or 1200) / 1000
        budget = budget + 6 + 25 + 10 + (fx.revealDelayMs() / 1000)
        if fx.keepsFrozenUntilDone then
            -- the reveal half of THIS run: a stage 10 prestige is twice as long
            -- as an evolution and would otherwise trip its own watchdog
            local t = Timing.forContext(ctx)
            budget = budget + t.revealTotalMs / 1000
        end
        EvoLock.sequenceBudgetS = budget + 10
    end)

    -- Cost transaction: consumed upfront, refunded exactly once on any abort
    -- that happens before the species swap is confirmed; earned afterwards.
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
        EvoLock.currentAbort = nil
        EvoLock.sequenceRunning = false
    end
    local function finishAbort()
        if seq.done then return end
        seq.done = true
        EvoLock.currentAbort = nil
        pcall(function() fx.cleanup(ctx) end)
        refundCost("evolution aborted")
        EvoLock.sequenceRunning = false
    end
    ctx.completeOk = finishOk
    ctx.completeAbort = finishAbort
    EvoLock.currentAbort = finishAbort

    if not (actor:IsValid() and param:IsValid() and holder and holder:IsValid()) then
        Log("Evolution aborted: pal/holder no longer valid")
        finishAbort()
        return
    end

    local mgr = EvoUtil.findManager(actor)
    if not mgr then
        Log("Evolution aborted: PalCharacterManager not found")
        finishAbort()
        return false, "Evolution aborted: PalCharacterManager not found"
    end
    local handle = nil
    pcall(function() handle = mgr:GetIndividualHandleFromCharacterParameter(param) end)
    if not (handle and handle:IsValid()) then
        Log("Evolution aborted: individual handle unavailable")
        finishAbort()
        return false, "Evolution aborted: individual handle unavailable"
    end

    -- Prestige changes three independent save surfaces. Refuse before taking a
    -- cost or hiding the actor unless every one can be captured for an exact
    -- rollback; a partial reset is worse than no prestige at all.
    local prestigeState = nil
    if isPrestige then
        local captureErr
        prestigeState, captureErr = EvoState.capturePrestigeState(param)
        if not prestigeState then
            Log("Prestige aborted before mutation: " .. tostring(captureErr))
            finishAbort()
            return false, I18n.msg("prestigeSnapshotFailed")
        end
    end

    -- These fields are about to be rewritten beside CharacterID. Capture both
    -- save halves before cost or presentation work so every started swap has a
    -- complete rollback point.
    local skinBefore = nil
    if Config.clearIncompatibleSkins then
        local skinErr
        skinBefore, skinErr = EvoState.captureSkinState(param)
        if not skinBefore then
            Log("Evolution aborted before mutation: skin snapshot failed: " .. tostring(skinErr))
            finishAbort()
            return false, I18n.msg("swapStateSnapshotFailed")
        end
    end
    local wazaBefore = nil
    if Config.moveInheritance ~= "off" then
        local wazaErr
        wazaBefore, wazaErr = WazaInherit.capture(param)
        if not wazaBefore then
            Log("Evolution aborted before mutation: move snapshot failed: " .. tostring(wazaErr))
            finishAbort()
            return false, I18n.msg("swapStateSnapshotFailed")
        end
    end
    local passivesBefore = isPrestige and prestigeState.passives or nil
    if not passivesBefore then
        local passiveErr
        passivesBefore, passiveErr = PalPassives.capture(param)
        if not passivesBefore then
            Log("Evolution aborted before mutation: passive snapshot failed: " .. tostring(passiveErr))
            finishAbort()
            return false, I18n.msg("swapStateSnapshotFailed")
        end
    end

    -- Take the full cost BEFORE the sequence (no TOCTOU: anything that fails
    -- before the swap refunds everything; after the swap it is earned)
    local costList = Costs.resolve(pair, level, holder)
    if #costList > 0 then
        local failedItem
        txn, failedItem = Costs.beginTransaction(playerCtx, costList)
        if not txn then
            local msg = string.format("Evolution aborted: %dx %s not available/consumable",
                failedItem and failedItem.count or 0, Costs.labelOf(failedItem))
            Log(msg)
            finishAbort()
            return false, msg
        end
        Log("Cost taken: " .. Costs.describe(costList))
    end

    Log(string.format("Evolving %s (Lv %d)...", pair.from, level))
    if Config.devMode then
        local pz = "?"
        pcall(function()
            local pawn = playerCtx and playerCtx.pawn
            if pawn and pawn:IsValid() then
                local pl = pawn:K2_GetActorLocation()
                pz = string.format("(%.0f,%.0f,%.0f)", pl.X, pl.Y, pl.Z)
            end
        end)
        Log(string.format("[diag start] key=%s old=(%s,%s,%s) yaw=%.0f half=%.0f player=%s",
            key, tostring(oldX), tostring(oldY), tostring(oldZ), oldYaw or 0, oldHalf or 0, pz))
    end

    -- Freeze + dissolve staging (white glow in place; the actor is
    -- hard-hidden right before the teardown so no recall visuals ever show).
    -- Skipped headless - pure presentation on the local player's actor.
    if not headless then
        EvoPresent.setFrozen(actor, true)
        pcall(function() actor:SetActorEnableCollision(false) end)
        pcall(function() fx.onDissolve(ctx) end)
    end
    if not ctx.fusionKind then EvoPresent.playFanfare(actor) end

    -- Teardown with per-strategy despawn verification. The direct manager
    -- teardown destroys the actor without the holder recall action (whose
    -- ball visuals run on a mesh clone that ignores a hidden actor).
    -- Every stage below is queued in UE4SS's own scheduler, whose lifetime the
    -- world does NOT bound: leaving for the title screen mid-evolution frees the
    -- character manager, holder and actor while these callbacks are still
    -- pending. A UFunction call on a freed UObject faults natively, past any
    -- pcall, so each deferred stage re-checks its handles before touching them.
    local function handlesAlive()
        return mgr and mgr:IsValid() and holder and holder:IsValid()
    end

    -- Teardown exit: end the sequence without touching anything the dying world
    -- owns. Deliberately no refund - the inventory goes away with the world, and
    -- writing to it would fault exactly like the call we are avoiding here.
    local function abandonOnTeardown()
        if seq.done then return end
        seq.done = true
        EvoLock.currentAbort = nil
        pcall(function() fx.cleanup(ctx) end)
        EvoLock.sequenceRunning = false
        Log("Left the world mid-evolution - sequence abandoned")
    end

    local recallStrategies = {
        { name = "DirectTeardown", fn = function()
            if mgr and mgr:IsValid() then mgr:DespawnCharacterByHandle(handle, nil) end
        end },
        { name = "InactivateCurrentOtomo", fn = function()
            if holder and holder:IsValid() then holder:InactivateCurrentOtomo() end
        end },
        { name = "PlayerController:InactiveOtomo", fn = function()
            local pc = playerCtx and playerCtx.pc
            if pc and pc:IsValid() then pc:InactiveOtomo() end
        end },
    }

    -- Authoritative view: the holder knows whether an otomo is out.
    -- (handle:TryGetIndividualActor stays "valid" after the recall - pooling.)
    local function isDespawned()
        if not (holder and holder:IsValid()) then return false end
        local spawned = nil
        pcall(function() spawned = holder:TryGetSpawnedOtomo() end)
        return not (spawned and spawned:IsValid())
    end

    local proceedAfterDespawn -- forward declaration

    local function tryRecall(i)
        if not handlesAlive() then
            abandonOnTeardown()
            return
        end
        if i > #recallStrategies then
            Log("Despawn not confirmed (all strategies exhausted) - aborting WITHOUT swap")
            if actor:IsValid() then
                pcall(function() actor:SetActorHiddenInGame(false) end)
                pcall(function() actor:SetActorEnableCollision(true) end)
                EvoPresent.setFrozen(actor, false)
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
        EvoPresent.pollUntil(200, 2000, isDespawned, function(despawned)
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
        if not handlesAlive() then
            abandonOnTeardown()
            return
        end
        -- A fusion names its target itself: which of the two Pals was an
        -- Alpha decides the fused form, not only the summoned one.
        local targetId = p.targetId or EvoUtil.swapTargetId(pair, isAlpha) or pair.to

        -- Swap in the despawned state (safest write moment) + verify
        if not param:IsValid() then
            Log("Aborted: parameter invalid after despawn")
            refundCost("parameter invalid")
            finishAbort()
            return
        end
        -- Revalidate at the mutation boundary: the id (and alpha state) must
        -- still match what was selected - another mod or a dev probe could
        -- have changed the pal during the dissolve/despawn window
        local curId, curAlpha = EvoUtil.baseCharacterId(param:GetCharacterID():ToString())
        if curId ~= pair.from or curAlpha ~= isAlpha then
            Log(string.format("Aborted: pal changed during the sequence (now %s%s, expected %s%s)",
                curAlpha and EvoUtil.BOSS_PREFIX or "", curId, isAlpha and EvoUtil.BOSS_PREFIX or "", pair.from))
            refundCost("pal changed mid-sequence")
            finishAbort()
            return
        end
        local originalId = isAlpha and (EvoUtil.BOSS_PREFIX .. pair.from) or pair.from
        local function restoreFailedMutation(reason)
            local stateOk, stateErr
            if isPrestige then
                stateOk, stateErr = EvoState.restorePrestigeState(param, prestigeState)
            else
                local okSpecies, speciesErr = pcall(EvoState.writeSpeciesUnsafe, param, originalId)
                local okId, restoredId = pcall(EvoUtil.characterIdUnsafe, param)
                stateOk = okSpecies and okId
                    and Config.canonicalId(restoredId) == Config.canonicalId(originalId)
                stateErr = speciesErr
            end
            local survivorOk, survivorErr = EvoState.restoreSwapSurvivors(param, skinBefore, wazaBefore)
            if stateOk and survivorOk then
                Log("Swap mutation failed and was rolled back: " .. tostring(reason))
            else
                Log("SWAP ROLLBACK FAILED after mutation error: " .. tostring(reason)
                    .. "; state=" .. tostring(stateErr) .. "; survivors=" .. tostring(survivorErr))
            end
            Role.chat(playerCtx, I18n.msg("swapStateMutationFailed"), "reply")
            refundCost("swap mutation failed")
            finishAbort()
        end

        if p.fusion then
            local okMutate, mutateErr = pcall(p.fusion.mutate, param, targetId)
            if not okMutate or mutateErr then
                local reason = okMutate and mutateErr or ("fusion mutate raised: " .. tostring(mutateErr))
                local okRestore, restoreErr = pcall(p.fusion.restore, param)
                if okRestore and not restoreErr then
                    Log("Fusion mutation failed and was rolled back: " .. tostring(reason))
                else
                    Log("FUSION ROLLBACK FAILED after mutation error: " .. tostring(reason)
                        .. "; restore=" .. tostring(restoreErr))
                end
                Role.chat(playerCtx, I18n.msg("swapStateMutationFailed"), "reply")
                refundCost("fusion mutation failed")
                finishAbort()
                return
            end
            swapDone = true
            if txn then txn.commit() end
        elseif isPrestige then
            local mutationOk, passiveResult = EvoState.applyPrestigeMutation(param, targetId, playerCtx)
            if not mutationOk then
                restoreFailedMutation(passiveResult)
                return
            end
            local survivorOk, survivorErr = EvoState.applySwapSurvivors(param, skinBefore, wazaBefore)
            -- Read back what actually landed. apply() reports the write as
            -- successful and the repertoire is empty in game, so the question is
            -- whether the write does not take or whether the reload behind the
            -- MP sequence overwrites it from the species default.
            if wazaBefore then
                local readBack = WazaInherit.capture(param)
                if readBack then
                    Log(string.format("[waza] after write: equip %d, mastered %d (before: equip %d, mastered %d)",
                        #(readBack.save.equip or {}), #(readBack.save.mastered or {}),
                        #(wazaBefore.save.equip or {}), #(wazaBefore.save.mastered or {})))
                else
                    Log("[waza] after write: read-back failed")
                end
            end
            if not survivorOk then
                restoreFailedMutation(survivorErr)
                return
            end
            swapDone = true
            if txn then txn.commit() end
            Log(string.format("Prestige bonus (passive): %s", passiveResult.id))
            -- the ladder just moved on an actor that stays alive here, so the
            -- init hook will not fire again for it
            pcall(function() require("prestigemark").reconcile(actor) end)
        else
            local okSwap, errSwap = pcall(EvoState.writeSpeciesUnsafe, param, targetId)
            local idNow = ""
            local okId, readId = pcall(EvoUtil.characterIdUnsafe, param)
            if okId then idNow = readId end
            -- Compare the read-back through the canonicalizer: the name just
            -- written can come back under a spelling the engine registered
            -- earlier, and a raw comparison would treat a swap that worked as a
            -- failure and refund it.
            if not okSwap or Config.canonicalId(idNow) ~= Config.canonicalId(targetId) then
                Log(string.format("SWAP FAILED (err=%s, id=%s) - no respawn attempt",
                    tostring(errSwap), idNow))
                restoreFailedMutation(errSwap or "species read-back differs")
                return
            end
            local survivorOk, survivorErr = EvoState.applySwapSurvivors(param, skinBefore, wazaBefore)
            -- Read back what actually landed. apply() reports the write as
            -- successful and the repertoire is empty in game, so the question is
            -- whether the write does not take or whether the reload behind the
            -- MP sequence overwrites it from the species default.
            if wazaBefore then
                local readBack = WazaInherit.capture(param)
                if readBack then
                    Log(string.format("[waza] after write: equip %d, mastered %d (before: equip %d, mastered %d)",
                        #(readBack.save.equip or {}), #(readBack.save.mastered or {}),
                        #(wazaBefore.save.equip or {}), #(wazaBefore.save.mastered or {})))
                else
                    Log("[waza] after write: read-back failed")
                end
            end
            if not survivorOk then
                restoreFailedMutation(survivorErr)
                return
            end
            swapDone = true
            if txn then txn.commit() end
            -- An adaptation is the same Pal in another element, not a step up,
            -- so it earns none of the evolution rewards. Paying them out made a
            -- back-and-forth pair of adaptations a way to farm the Evolved
            -- passive, the IV bonus and the extra slot.
            if pair.category == "adaptation" then
                Log(string.format("Adaptation %s -> %s: no evolution reward, the Pal stays at its stage",
                    tostring(pair.from), tostring(pair.to)))
            else
                EvoPresent.applyIvBonus(param)
                local passiveOk, passiveResult = PalPassives.grantEvolved(param)
                if passiveOk then
                    Log(string.format("Evolution bonus (passive): %s", passiveResult.id))
                    -- Optional and off by default: an extra slot on top of the ladder
                    -- reward, which a server owner turns on. It fails loudly and
                    -- changes nothing else, because the swap is already committed.
                    local slotOk, slotResult = PalSlots.grantEvolution(param, playerCtx)
                    EvoState.reportBonusSlot(playerCtx, slotOk, slotResult, "Evolution")
                else
                    -- The cost is already committed. Continuing keeps the successful
                    -- species swap at the tradeoff that this reward is not refunded alone.
                    Log("EVOLVED PASSIVE WRITE FAILED after cost commit: "
                        .. tostring(passiveResult) .. " - evolution remains committed")
                end
            end
        end
        -- The split at the end of a fusion hands both Pals their share of the
        -- fused Pal's HP; healing here would undo exactly that.
        if not (p.fusion and p.fusion.keepHp) then
            pcall(function() param:FullRecoveryHP() end)
        end
        EvoPresent.refreshWorkSuitability(param, playerCtx, actor, pair.from)

        -- A fusion keeps its own record (fusion.lua): an evolution rollback must
        -- never turn a fused Pal back into one of its two halves.
        if p.fusion then
            local okCommitted, committedErr = pcall(p.fusion.onCommitted, param, actor)
            if not okCommitted then
                Log("[ERROR] fusion commit hook failed: " .. tostring(committedErr))
            end
        else
            -- Snapshot only AFTER a successful swap (no phantom rollback entries);
            -- stores the RAW ids (BOSS_ included) so a rollback restores the alpha
            table.insert(EvoSnap.snapshots, {
                kind = isPrestige and "prestige" or "evolution",
                key = key, from = isAlpha and (EvoUtil.BOSS_PREFIX .. pair.from) or pair.from,
                to = targetId, level = level,
                exp = isPrestige and prestigeState.exp or nil,
                mirrorLevel = isPrestige and prestigeState.mirrorLevel or nil,
                mirrorExp = isPrestige and prestigeState.mirrorExp or nil,
                nickname = nickname,
                ivHP = talentsBefore.Talent_HP, ivMelee = talentsBefore.Talent_Melee,
                ivShot = talentsBefore.Talent_Shot, ivDefense = talentsBefore.Talent_Defense,
                passives = passivesBefore,
                skin = skinBefore,
                waza = wazaBefore,
                -- owning player (additive; multiplayer rollback needs to know
                -- whose pal the snapshot belongs to)
                uid = playerCtx and playerCtx.playerUId
                    and EvoUtil.guidString(playerCtx.playerUId) or nil,
                -- what this evolution actually cost, so a rollback can hand it
                -- back. Recorded here rather than re-derived later: material costs
                -- depend on the pal's level at the time, which has since moved on.
                cost = (function()
                    local paid = {}
                    for _, c in ipairs(costList or {}) do
                        if c.id and c.count then
                            table.insert(paid, { id = c.id, count = c.count })
                        end
                    end
                    return paid
                end)(),
            })
            -- Always the unprefixed id: the capture record is keyed by EPalTribeID, which has one
            -- entry per species and none for the BOSS_ (alpha) rows, exactly like the Palpedia.
            EvoPresent.unlockCatchTech(pair.to, playerCtx)
        end

        -- Headless (dedicated server): the authoritative param swap is done.
        -- Do NOT touch the otomo lifecycle - on this path the pal was never
        -- despawned (the teardown is skipped headless), so it is still summoned
        -- as its old actor while its param is already the new species. Any
        -- despawn/InactivateCurrentOtomo/respawn-pump here either crashes
        -- headless or leaves the otomo un-summonable. The client recalls and
        -- re-summons through the normal game path to get the new form.
        if headless then
            -- Server-authoritative MP presentation state machine. The pal is
            -- still summoned as its old actor (teardown skipped headless) with
            -- its param already the target species. We freeze it in place and
            -- drive the client's cosmetic re-play through phase signals, doing
            -- the parts only the authority can: the pool break (so the re-summon
            -- spawns the NEW species, not a pooled old body) and the teleport
            -- back to the saved spot.
            local savedX, savedY, savedZ, savedYaw, savedHalf = oldX, oldY, oldZ, oldYaw, oldHalf
            local pcSender = playerCtx.pc
            local oldActor = actor
            local savedSlot = -1
            pcall(function() savedSlot = holder:GetSlotIndexByIndividualHandle(handle) end)
            EvoPresent.setRevealFrozen(actor, true)
            local phaseSequence = nil
            pcall(function()
                -- The client draws the sequence, so the mode it is told IS the
                -- look. Anything not named here falls back to the evolution
                -- presentation rather than reaching the wire as an unknown word.
                local presentationMode = pair.category
                if presentationMode ~= "adaptation" and presentationMode ~= "prestige"
                    and presentationMode ~= "fusion" then
                    presentationMode = "evolution"
                end
                -- the stage rides along, because the client cannot read it off
                -- the passives: those may replicate after this frame arrives
                local presentationStage = nil
                if presentationMode == "prestige" then
                    presentationStage = 1
                    local okStages, stages = pcall(PalPassives.resolve, param)
                    if okStages and type(stages) == "table" and stages.prestige
                        and (stages.prestige.stage or 0) > 0 then
                        presentationStage = stages.prestige.stage
                    end
                end
                phaseSequence = NetChannel.sendPhaseStart(pcSender,
                    presentationMode, pair.from, pair.to, pair.stone or "evolution",
                    presentationStage)
            end)
            Log(string.format("EVOLVED (server): %s -> %s (level %d) - MP sequence", pair.from, pair.to, level))

            -- Server-authoritative reload. The client recalls (dissolve done),
            -- then the SERVER does what only the authority can and what the
            -- client's activate RPC does NOT: destroy the pooled old body and
            -- SpawnOtomoByLoad, which REBUILDS the actor from the swapped param
            -- (new species mesh). ActivateCurrentOtomo then removes it from the
            -- reserve list (no trainer-anchor float). The new actor is proven by
            -- POINTER inequality (its param id alone reads new even on the old
            -- pooled body). Only then teleport/freeze and signal the reveal.
            local phase = "await_recall"
            local startedAt = os.clock()
            local watcherDone = false
            local spawnedAt = nil
            local nhTries = 0
            local nhBest = 0
            local function watcherStep()
                if watcherDone then return end
                if seq.done then watcherDone = true; return end
                -- Disconnect guard: on a dedicated server the requesting
                -- player's controller (and its otomo holder) are destroyed
                -- when they leave. Calling a UFunction on a torn-down UObject
                -- raises a native "Pure virtual not implemented" assert that
                -- pcall does NOT catch, so gate every deferred touch on
                -- :IsValid() and end the presentation (the data mutation is
                -- already committed, but the sequence lock is still ours).
                if not (holder and holder:IsValid() and pcSender and pcSender:IsValid()) then
                    Log("[mpseq] requester left mid-sequence - aborting server presentation")
                    watcherDone = true
                    finishOk()
                    return
                end
                if phase == "await_recall" then
                    local out = nil
                    pcall(function() out = holder:TryGetSpawnedOtomo() end)
                    if not (out and out:IsValid()) then
                        pcall(function() mgr:DespawnCharacterByHandle(handle, nil) end)
                        pcall(function() holder:InactivateCurrentOtomo() end)
                        pcall(function() pcSender:SetOtomoSlot(savedSlot) end)
                        pcall(function() holder:SpawnOtomoByLoad(savedSlot) end)
                        spawnedAt = os.clock()
                        phase = "await_actor"
                        Log("[mpseq] recall done -> reload (SpawnOtomoByLoad)")
                    end
                elseif phase == "await_actor" then
                    -- wait for the freshly loaded reserve actor (must be a
                    -- DIFFERENT UObject than the old pooled body)
                    local cand = nil
                    pcall(function() cand = handle:TryGetIndividualActor() end)
                    if cand and cand:IsValid() and cand ~= oldActor then
                        phase = "activate"
                        Log("[mpseq] fresh actor -> activate")
                    elseif (os.clock() - (spawnedAt or 0)) > 5 then
                        Log("[mpseq] reload produced no new actor (timeout)")
                        watcherDone = true
                        if oldActor and oldActor:IsValid() then EvoPresent.setRevealFrozen(oldActor, false) end
                        finishOk()
                    end
                elseif phase == "activate" then
                    local cand = nil
                    pcall(function() cand = handle:TryGetIndividualActor() end)
                    if not (cand and cand:IsValid()) then
                        watcherDone = true
                        finishOk()
                        return
                    end
                    -- Read the new pal's SCALED COLLISION capsule - the
                    -- engine's grounding measure (~30 for most
                    -- species). The mesh-space
                    -- MeshCapsuleHalfHeight must never feed physics Z
                    -- (deriving ground from it sank targets into the
                    -- floor); it stays only as the last resort when no
                    -- capsule is readable. Poll a few frames only while
                    -- the capsule is not readable yet.
                    local nh = nil
                    pcall(function()
                        local cap = cand.CapsuleComponent
                        if cap and cap:IsValid() then
                            nh = cap:GetScaledCapsuleHalfHeight()
                        end
                    end)
                    if not (nh and nh > 0) then
                        nh = EvoUtil.staticCapsuleHalf(cand)
                    end
                    nh = nh or 0
                    if nh > nhBest then nhBest = nh end
                    if nhBest <= 0 and nhTries < 8 then
                        nhTries = nhTries + 1
                        return -- stay in "activate"; capsule not readable yet
                    end
                    nh = (nhBest > 0) and nhBest or nh
                    -- feet-on-ground plus a small lift so the new pal
                    -- never spawns sunk into the ground
                    local destZ = (savedZ or 0) + 40
                    if groundZ and nh > 0 then
                        destZ = groundZ + nh + 40
                    elseif savedZ and savedHalf and savedHalf > 0 and nh > 0 then
                        destZ = savedZ - savedHalf + nh + 40
                    end
                    Log(string.format("[mpseq] place nh=%.0f destZ=%.0f", nh or 0, destZ))
                    local activated = false
                    pcall(function()
                        activated = holder:ActivateCurrentOtomo({
                            Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                            Translation = { X = savedX or 0, Y = savedY or 0, Z = destZ },
                            Scale3D = { X = 1, Y = 1, Z = 1 },
                        })
                    end)
                    if activated then
                        local newActor = nil
                        pcall(function() newActor = holder:TryGetSpawnedOtomo() end)
                        if newActor and newActor:IsValid() and newActor ~= oldActor then
                            -- Re-read the scaled collision half from the
                            -- activated actor and recompute destZ from the
                            -- best value (belt and braces).
                            local nh2 = nil
                            pcall(function()
                                local cap = newActor.CapsuleComponent
                                if cap and cap:IsValid() then
                                    nh2 = cap:GetScaledCapsuleHalfHeight()
                                end
                            end)
                            if not (nh2 and nh2 > 0) then
                                nh2 = EvoUtil.staticCapsuleHalf(newActor) or 0
                            end
                            local nhUse = math.max(nhBest or 0, nh2 or 0)
                            if groundZ and nhUse > 0 then
                                destZ = groundZ + nhUse + 40
                            elseif savedZ and savedHalf and savedHalf > 0 and nhUse > 0 then
                                destZ = savedZ - savedHalf + nhUse + 40
                            end
                            -- hard transform-safe freeze (suppresses the
                            -- movement tick + AI + actions, leaves rotation
                            -- writable for the client spin), then place once
                            EvoPresent.setRevealFrozen(newActor, true)
                            pcall(function()
                                newActor:K2_TeleportTo({ X = savedX or 0, Y = savedY or 0, Z = destZ },
                                    { Pitch = 0, Yaw = savedYaw or 0, Roll = 0 })
                            end)
                            pcall(function() newActor:ForceNetUpdate() end)
                            -- fresh actor now carries the new species; refresh
                            -- work suitability HERE (the swap-time call ran on
                            -- the old actor and could not re-derive the base)
                            EvoPresent.refreshWorkSuitability(param, playerCtx, newActor, pair.from)
                            Log("[mpseq] activated fresh " .. targetId .. " -> reveal")
                            -- Second read, on the far side of the reload. The
                            -- write before the swap reports success, so what
                            -- is left to learn is whether SpawnOtomoByLoad
                            -- rebuilds the move lists from the new species and
                            -- drops what was written into them.
                            local probeParam = EvoUtil.paramOf(newActor)
                            if probeParam then
                                local afterReload = WazaInherit.capture(probeParam)
                                if afterReload then
                                    Log(string.format("[waza] after reload: equip %d, mastered %d",
                                        #(afterReload.save.equip or {}),
                                        #(afterReload.save.mastered or {})))
                                else
                                    Log("[waza] after reload: read-back failed")
                                end
                            end
                            pcall(NetChannel.sendPhaseReveal, pcSender, phaseSequence)
                            -- The evolution flash VFX (VisualEffectComponent:
                            -- AddVisualEffect) is a LOCAL call - on a client
                            -- proxy it does not render (the component is
                            -- server-authoritative), so the SP "grand finale"
                            -- flash was missing in MP. Broadcast it from the
                            -- authority via the replicated multicast so every
                            -- client sees it (issuerID 0 = play for all).
                            -- Delay it so it lands after the client's
                            -- onPreReveal has shrunk the actor to 0.02 and the
                            -- grow-reveal has begun - the flash then grows with
                            -- the pal exactly as in SP, no full-size pop.
                            GameLoop.after(250, function()
                                -- disconnect guard (see the main loop above)
                                if not (holder and holder:IsValid()) then
                                    Log("[mpseq] requester left before the evolve flash")
                                    return
                                end
                                local okFlash, errFlash = pcall(function()
                                    local na = holder:TryGetSpawnedOtomo()
                                    if na and na:IsValid() then
                                        local vec = na.VisualEffectComponent
                                        if vec and vec:IsValid() then
                                            vec:AddVisualEffect_ToALL(2, { FloatValues = {} }, 0)
                                        end
                                    end
                                end)
                                if not okFlash then
                                    Log("[mpseq] evolve flash failed: " .. tostring(errFlash))
                                end
                            end, "mp evolve flash")
                            watcherDone = true
                            -- Keep it pinned for the reveal. The named flags
                            -- are persistent, so only re-assert if the AI
                            -- flips back on (init race). NO transform writes -
                            -- re-teleporting jittered the pal and reset the
                            -- client spin. Release at the end.
                            local holdStart = os.clock()
                            local digimon = Config.digimon or {}
                            local holdSeconds = ((tonumber(digimon.growMs) or 0)
                                + (tonumber(digimon.finaleHoldMs) or 0)) / 1000
                            local held = false
                            GameLoop.start(300, function()
                                if held then return true end
                                if seq.done then held = true; return true end
                                -- disconnect guard: never touch a dead holder,
                                -- and do not attempt an unfreeze on it
                                if not (holder and holder:IsValid()) then
                                    Log("[mpseq] requester left during reveal hold - releasing")
                                    held = true
                                    finishOk()
                                    return true
                                end
                                local na = nil
                                pcall(function() na = holder:TryGetSpawnedOtomo() end)
                                if not (na and na:IsValid()) then
                                    held = true
                                    finishOk()
                                    return true
                                end
                                if (os.clock() - holdStart) < holdSeconds then
                                    if EvoPresent.isAiActive(na) then EvoPresent.setRevealFrozen(na, true) end
                                    return false
                                end
                                held = true
                                EvoPresent.setRevealFrozen(na, false)
                                finishOk()
                                return true
                            end, "mp reveal hold")
                        end
                    end
                end
                -- hard deadline: never leave a pal frozen on a lost packet
                if (not watcherDone) and (os.clock() - startedAt) > 20 then
                    watcherDone = true
                    pcall(function()
                        local na = holder:TryGetSpawnedOtomo()
                        if na and na:IsValid() then EvoPresent.setRevealFrozen(na, false) end
                    end)
                    finishOk()
                end
            end
            GameLoop.start(150, function()
                if watcherDone then return true end
                local okStep, errStep = pcall(watcherStep)
                if not okStep then Log("[mpseq] watcher step failed: " .. tostring(errStep)) end
                return watcherDone
            end, "mp reveal watcher")
            return
        end

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
            local pc = playerCtx.pc
            pc:SetOtomoSlot(idx)
        end)
        if not (okInact and okSel) then
            Log(string.format("Holder state cleanup FAILED (inactivate=%s reselect=%s) - activation may stall",
                tostring(okInact), tostring(okSel)))
        elseif Config.devMode then
            Log(string.format("Holder state cleanup ok=%s reselect ok=%s", tostring(okInact), tostring(okSel)))
        end

        -- Activation pump with staged reveal. The respawn check compares the
        -- actor's individual CharacterID against the raw target id instead of
        -- synthesizing a BP class name: boss blueprints are named
        -- BP_<species>_BOSS_C (via DT_PalBPClass), NOT BP_BOSS_<species>_C,
        -- so name synthesis breaks for alphas while the id is always exact.
        local function isRespawned()
            local a = nil
            pcall(function() a = holder:TryGetSpawnedOtomo() end)
            if not (a and a:IsValid()) then return false end
            local idSpawned = ""
            pcall(function()
                local p = EvoUtil.paramOf(a)
                if p and p:IsValid() then idSpawned = p:GetCharacterID():ToString() end
            end)
            -- Same spelling trap: this comparison is how the mod picks its own
            -- freshly spawned actor out of the world, so a missed match means
            -- never finding it at all.
            if Config.canonicalId(idSpawned) ~= Config.canonicalId(targetId) then return false end
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
                        -- Anchor the new COLLISION capsule so its feet end up
                        -- on the measured ground; with unknown capsule sizes
                        -- lift a bit instead and let gravity settle it after
                        -- the unfreeze.
                        local newHalf = 0
                        pcall(function()
                            local cap = newActor.CapsuleComponent
                            if cap and cap:IsValid() then
                                newHalf = cap:GetScaledCapsuleHalfHeight()
                            end
                        end)
                        -- mesh-space body half of the TARGET species: the FX
                        -- framing measure (NEVER used for physics Z)
                        pcall(function()
                            local mh = EvoUtil.staticCapsuleHalf(newActor)
                            if mh and mh > 0 then ctx.meshHalfTo = mh end
                        end)
                        local targetZ = oldZ + 40
                        if ctx.groundZ and newHalf > 0 then
                            targetZ = ctx.groundZ + newHalf + 10
                            ctx.newHalf = newHalf
                        elseif (oldHalf or 0) > 0 and newHalf > 0 then
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
                -- game-thread one-shot (gameloop.lua) instead of
                -- ExecuteWithDelay: the delay API's transient callback refs get
                -- freed by UE4SS's callback GC under load ("Ref was not
                -- function"), killing every deferred callback of the mod at once
                GameLoop.after(fx.revealDelayMs(), function()
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
                    local okReveal, errReveal = pcall(function() fx.onReveal(ctx, a) end)
                    if playerCtx and playerCtx.isLocal then EvoPresent.refreshPartyHud(holder) end
                    EvoPresent.playFanfare(a)
                    Log(string.format("EVOLVED: %s -> %s (level %d)%s",
                        pair.from, pair.to, level,
                        nickname ~= "" and (" '" .. nickname .. "'") or ""))
                    EvoPresent.startRevealDiagnostics(holder, pair.to, playerCtx)
                    if fx.keepsFrozenUntilDone and okReveal then
                        -- the prototype ends the sequence via ctx.completeOk/Abort
                        return
                    end
                    EvoPresent.setFrozen(a, false)
                    if okReveal then
                        finishOk()
                    else
                        Log("Reveal staging failed - cleaning up: " .. tostring(errReveal))
                        finishAbort()
                    end
                end, "evolution reveal")
            else
                -- failure path: never leave anything invisible behind
                if newActor and newActor:IsValid() then
                    revealActor(newActor)
                    EvoPresent.completeOtomoActivation(newActor)
                    EvoPresent.setFrozen(newActor, false)
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
                    local pc = playerCtx.pc
                    pc:SetOtomoSlot(idx)
                    pc:TrySwitchOtomo()
                end)
                Log(string.format("EVOLVED (data only): %s -> %s (level %d) - respawn not confirmed (got class '%s', expected id %s); summon rescue ok=%s",
                    pair.from, pair.to, level, cls, targetId, tostring(okRescue)))
                -- The rescue call raising nothing says nothing about the Pal:
                -- look again once it had time to arrive, and tell the player
                -- when it did not.
                GameLoop.after(1500, function()
                    if not (holder and holder:IsValid()) then
                        Log("[WARN] summon rescue check skipped: the world is gone")
                        return
                    end
                    local back = nil
                    local okBack, backErr = pcall(function() back = holder:TryGetSpawnedOtomo() end)
                    if not okBack then Log("[WARN] summon rescue check: summoned Pal unreadable: " .. tostring(backErr)) end
                    if back and back:IsValid() then
                        Log("summon rescue brought a Pal back out")
                    else
                        Log("[ERROR] summon rescue: no Pal is out; the player has to summon it again")
                        Role.chat(playerCtx, I18n.msg("summonAgain", EvoNames.palDisplayName(pair.to)), "reply")
                    end
                end, "summon rescue check")
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
            local function landingStep()
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
            end
            GameLoop.start(200, function()
                if watchDone then return true end
                local okStep, errStep = pcall(landingStep)
                if not okStep then Log("[ERROR] landing watch step failed: " .. tostring(errStep)) end
                return watchDone
            end, "landing watch")
        end

        -- Activation pump. The holder BP
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
        local function pumpStep()
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
                -- Two-phase respawn:
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
        end
        GameLoop.start(100, function()
            if pumpDone then return true end
            local okStep, errStep = pcall(pumpStep)
            if not okStep then Log("[ERROR] activation pump step failed: " .. tostring(errStep)) end
            return pumpDone
        end, "activation pump")
    end

    -- Headless (dedicated server): skip the whole teardown/reveal machinery.
    -- The pal stays summoned as its old actor; proceedAfterDespawn only writes
    -- the new save state onto the param (safe while summoned) and the headless
    -- branch there finishes. The client recalls + re-summons to render it.
    if headless then
        proceedAfterDespawn()
        return true
    end

    -- Start the teardown only AFTER the dissolve staging; the actor is
    -- hard-hidden right before it so no despawn visuals are ever seen
    local dissolveMs = 1200
    pcall(function()
        if fx.dissolveDurationMs then dissolveMs = fx.dissolveDurationMs(ctx) end
    end)
    -- game-thread one-shot (gameloop.lua) instead of ExecuteWithDelay: the
    -- delay API's transient callback refs get freed by UE4SS's callback GC
    -- under load ("Ref was not function"), killing every deferred callback of
    -- the mod
    GameLoop.after(dissolveMs, function()
        if seq.done then return end
        -- the world can be gone by now: this fires a full dissolve after it
        -- was armed, which is ample time to hit ESC and leave
        if not handlesAlive() then
            abandonOnTeardown()
            return
        end
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
    end, "evolution teardown start")
    -- the sequence is started; asynchronous stages report their outcome
    -- through the sequence's own logging/abort paths
    return true
end

--- Every evolution, prestige and battle fusion goes through here. A Pal with
--- a rider on its back is never taken away: the rider would stay attached to a
--- mount that no longer exists, and the game would ignore every input except
--- the camera. The rider gets off first, then the sequence starts.
local function performEvolution(p)
    if EvoLock.lockBusy() then return false, I18n.msg("evolutionRunning") end
    if not Ride.riderOf(p.actor) then return performEvolutionNow(p) end
    -- The lock covers the wait, so nothing else starts on this Pal meanwhile.
    EvoLock.sequenceRunning = true
    EvoLock.sequenceStartedAt = os.clock()
    EvoLock.sequenceBudgetS = 15
    EvoLock.currentAbort = nil
    Ride.dismount(p.actor, function(off, why)
        EvoLock.sequenceRunning = false
        if not off then
            Log("Evolution not started: the rider could not get off (" .. tostring(why) .. ")")
            Role.chat(p.playerCtx, I18n.msg("dismountFailed"), "reply")
            return
        end
        if not (p.actor and p.actor:IsValid()) then
            Log("Evolution not started: the Pal was gone after the rider got off")
            return
        end
        local started, reason = performEvolutionNow(p)
        if not started then
            Log("Evolution not started after the rider got off: " .. tostring(reason))
            if reason then Role.chat(p.playerCtx, reason, "reply") end
        end
    end, "evolution of " .. tostring(p.pair and p.pair.from))
    return true
end

-- Guard for the connected-client transmit path: only hand an evolve request to a
-- host we have confirmed runs Palvolve. In the short window right after joining
-- the host's greet may not have arrived yet, and on a vanilla host the carrier
-- RPC would be interpreted as a plain otomo selection instead.
local function remoteTransmitReady(playerCtx)
    if ServerCheck.remoteReady() then return true end
    -- The old line asked the player to try again in a moment and then said
    -- nothing more, so the answer only arrived if they happened to retry at the
    -- right time. On a server without Palvolve it never resolved at all. The
    -- check now tells them itself, whichever way it settles.
    if ServerCheck.answerWhenSettled then ServerCheck.answerWhenSettled() end
    local msg = I18n.msg("serverCheckPending")
    Log(msg)
    Role.chat(playerCtx, msg, "reply")
    return false
end

-- ---------------------------------------------------------------- public API

function Evolution.check()
    if ServerCheck.blocked() then
        Role.chat(Role.localPlayerCtx(), I18n.msg("serverNoPalvolve"), "reply")
        return
    end
    -- Said here because F2 runs off a key bind rather than a timer, so this is
    -- the one place that still speaks once the tick hook is gone. Rate limited:
    -- the state does not heal on its own and the player would otherwise get the
    -- same line on every press.
    -- Past the long threshold the answer is certain, and starting anyway would
    -- charge the player for an evolution that stops after its first step. The
    -- short threshold only warns, so a stalled async thread costs a line in the
    -- chat rather than the use of the key.
    if EvoLock.timersDead() then
        EvoLock.reportDeadTimers(nil)
        if EvoLock.timersGone() then return end
    end
    if EvoLock.lockBusy() then
        Log(I18n.msg("evolutionRunning"))
        return
    end
    local playerCtx = Role.localPlayerCtx()
    if not playerCtx then
        Log(I18n.msg("noLocalPlayer"))
        return
    end
    -- drop an expired confirm: a stale pending otherwise suppresses the
    -- eligibility reason messages below
    if pending and (os.clock() - pending.armedAt) > Config.confirmWindowSeconds then
        pending = nil
    end
    local actor, param, pair, level, holder, isAlpha, pairIndex, isPrestige = findEligibleFor(playerCtx)
    if not actor then
        if not pending then
            -- second return value carries the reason message when present
            local reason = param or I18n.msg("noPalSummoned")
            Log(reason)
            Role.chat(playerCtx, reason, "reply")
        end
        return
    end

    -- Full cost check (stone + materials); lists every missing item. On a
    -- connected client this reads the client's own (replicated) inventory
    -- for a readable message; the host re-checks authoritatively.
    local costList = Costs.resolve(pair, level, holder)
    local costOk, missing = Costs.check(playerCtx, costList)
    if not costOk then
        local reason
        if isPrestige then
            reason = I18n.msg("couldPrestigeMissing",
                EvoNames.palDisplayName(pair.from), level, EvoNames.palDisplayName(pair.to), Costs.describeMissing(missing))
        else
            reason = I18n.msg("couldEvolveMissing",
                EvoNames.palDisplayName(pair.from), level, EvoNames.palDisplayName(pair.to), Costs.describeMissing(missing))
        end
        Log(reason)
        if Role.hasWorldAuthority() then
            -- authority (single player / host): this check is final, show it here
            Role.chat(playerCtx, reason, "reply")
        elseif remoteTransmitReady(playerCtx) then
            -- pure client: emitting the reason locally would attribute it to the
            -- player ("[Name]: ..."). Send the request instead so the host rejects
            -- it and delivers the reason as a private [SYSTEM] line; the host
            -- re-checks and consumes nothing on a rejected evolve.
            if isPrestige then
                NetChannel.sendPrestige(playerCtx, pairIndex or 0)
            else
                NetChannel.sendEvolve(playerCtx, pairIndex or 0)
            end
        end
        return
    end

    local now = os.clock()
    local key = EvoUtil.individualKey(param)
    if pending and (now - pending.armedAt) <= Config.confirmWindowSeconds then
        if pending.key == key then
            if Role.hasWorldAuthority() then
                -- Run the same indexed revalidation as the wheel, network and
                -- watcher. The pal or a same-target variant may have changed
                -- since this confirmation was armed.
                local ok, msg
                if isPrestige then
                    ok, msg = EvoAuto.handlePrestigeByIndex(playerCtx, pairIndex)
                else
                    ok, msg = EvoAuto.handleEvolveByIndex(playerCtx, pairIndex)
                end
                if not ok and msg then
                    Log(msg)
                    Role.chat(playerCtx, msg, "reply")
                end
            else
                -- connected client: the confirm travels to the host, which
                -- re-derives and consumes authoritatively
                if not remoteTransmitReady(playerCtx) then return end
                pending = nil
                if isPrestige then
                    NetChannel.sendPrestige(playerCtx, pairIndex or 0)
                else
                    NetChannel.sendEvolve(playerCtx, pairIndex or 0)
                end
            end
            return
        else
            Log(I18n.msg("confirmChanged",
                pending.pair and EvoNames.palDisplayName(pending.pair.from) or "?", EvoNames.palDisplayName(pair.from)))
        end
    end
    pending = { armedAt = now, key = key, pair = pair }
    EvoPresent.playFanfare(actor)
    local costHint = ""
    if #costList > 0 then
        costHint = I18n.msg("costHint", Costs.describe(costList))
    end
    if isPrestige then
        Log(I18n.msg("canPrestigeConfirm",
            EvoNames.palDisplayName(pair.from), level, EvoNames.palDisplayName(pair.to), costHint,
            Config.confirmKey, Config.confirmWindowSeconds))
    else
        Log(I18n.msg("canEvolveConfirm",
            EvoNames.palDisplayName(pair.from), level, EvoNames.palDisplayName(pair.to), costHint,
            Config.confirmKey, Config.confirmWindowSeconds))
    end
end

-- true while a confirm is armed; the radial menu label switches to
-- "confirm" in that window
function Evolution.isArmed()
    return pending ~= nil and (os.clock() - pending.armedAt) <= Config.confirmWindowSeconds
end

-- Reason the radial entry was last greyed, or nil while it was offered. canOffer
-- runs on every wheel rebuild, so the reason is written only when it CHANGES -
-- logging every call would put one line per frame in the file. Logging nothing
-- is worse: "not your pal", "nothing configured for this species" and "host not
-- confirmed" produce the same grey entry and are otherwise indistinguishable.
local lastOfferPlayerMsg = nil
local lastOfferReason = nil
local lastOfferPrestige = false
-- The wheel labels itself from lastOfferPrestige, and a prestige connection
-- that reads as an ordinary evolution looks identical to a missing one. This
-- records which of the two lists answered, deduped the way the verdict is.
local lastOfferShape = nil

-- Player-facing half of the verdict. The log line names the cause for support;
-- this names it for the person looking at a grey entry, who otherwise gets
-- nothing to act on. One line per distinct cause per session: canOffer runs on
-- every wheel rebuild, so anything less selective would be chat spam.
local toldReasons = {}
--- Says it once, and only where it can be said properly.
---
--- A client cannot set a chat sender, so anything it writes arrives under the
--- PLAYER's own name: "[DooDesch]: [Palvolve] No Pal summoned" reads as if the
--- player had typed it. This line is not even an answer to something the player
--- did - it fires while the wheel is being built - so on a connected client it
--- stays out of the chat entirely and goes to the wheel instead, where
--- Evolution.offerReason puts it in the middle of the ring under the entry it
--- is about. The host has a real sender and keeps the line.
local function tellPlayer(msg)
    if not msg or toldReasons[msg] then return end
    toldReasons[msg] = true
    if not Role.hasWorldAuthority() then return end
    local playerCtx = Role.localPlayerCtx()
    if not playerCtx then return end
    pcall(Role.chat, playerCtx, "[Palvolve] " .. msg)
end

local function offerVerdict(reason, playerMsg)
    if reason ~= lastOfferReason then
        lastOfferReason = reason
        Log(reason and ("Evolve unavailable: " .. reason) or "Evolve available")
        if reason then tellPlayer(playerMsg) end
    end
    lastOfferPlayerMsg = reason and playerMsg or nil
    return reason
end

--- True when the last canOffer offered the entry for fusions alone, so the
--- wheel can name it for what it opens.
local lastOfferFusionOnly = false
function Evolution.offerIsFusionOnly()
    return lastOfferFusionOnly
end

--- True when the last canOffer found fusions next to evolutions: the wheel then
--- gets a second entry, "Fusion", instead of hiding them in the Evolve list.
local lastOfferFusionEntry = false
function Evolution.offerHasFusionEntry()
    return lastOfferFusionEntry
end

--- Why the wheel entry is greyed, in the player's language, or nil when it is
--- not. Set by the last canOffer, which the wheel calls on every rebuild.
function Evolution.offerReason()
    return lastOfferPlayerMsg
end

-- Light-weight availability for the radial label: an owned pal is
-- summoned and has at least one configured option. Level and costs are
-- only checked in the submenu - this runs on every wheel rebuild.
function Evolution.canOffer()
    lastOfferPrestige = false
    -- grey the radial entry while the host is unconfirmed as a Palvolve host; the
    -- reason is surfaced when the player opens it (listOptions) or presses F2, not
    -- as a preemptive banner
    if ServerCheck.blocked() then
        offerVerdict("this host is not confirmed as a Palvolve host",
            I18n.msg("serverNoPalvolveShort"))
        return false
    end
    -- returns nil when the entry may be offered, otherwise the log reason and
    -- the line the player gets to see
    local ok, reason, playerMsg = pcall(function()
        local playerCtx = Role.localPlayerCtx()
        local holder = EvoUtil.findHolderFor(playerCtx, nil)
        if not holder then
            return "no otomo holder for the local player", I18n.msg("noPalSummoned")
        end
        local actor = nil
        pcall(function() actor = holder:TryGetSpawnedOtomo() end)
        if not (actor and actor:IsValid()) then
            return "no pal summoned", I18n.msg("noPalSummoned")
        end
        local param = EvoUtil.paramOf(actor)
        if not param then
            return "the summoned pal has no individual parameter", I18n.msg("noPalSummoned")
        end
        local id = EvoUtil.baseCharacterId(param:GetCharacterID():ToString())
        if not EvoUtil.isOwnedBy(param, playerCtx and playerCtx.playerUId) then
            -- a traded or gifted pal keeps the original catcher in its save
            -- record, so it reads as someone else's while sitting in this
            -- player's own party
            return string.format("pal '%s' is not owned by this player", id),
                I18n.msg("greyNotYours")
        end
        local pairList, isPrestige, prestigeErr = EvoState.optionPairsFor(id, param)
        -- Before any of the refusals below, not after them. The entry names
        -- itself from this, and every early return left it on the value the
        -- last Pal set - so a Pal whose only step is a prestige was refused
        -- under the word "Evolve", while the reason beside it talked about
        -- prestige. A greyed entry still has to say what it is greyed FOR.
        lastOfferPrestige = isPrestige
        if isPrestige and EvoState.prestigeAtMax(param) then
            return string.format("pal '%s' is already at the last prestige rank", id),
                I18n.msg("prestigeAtMax", EvoNames.palDisplayName(id))
        end
        local n = #pairList
        if n == 0 then
            if prestigeErr then Log("Prestige targets unavailable: " .. tostring(prestigeErr)) end
            -- The wheel already carries the Pal: its portrait is in the ring
            -- and the entry sits on it, so repeating the species name here
            -- spends the width that the reason needs. The chat paths keep the
            -- named wording, where there is no wheel to read it from.
            local playerMessage = I18n.msg("hasNoEvolutionShort")
            if isPrestige then
                -- Two different answers wearing the same words. "This Pal
                -- cannot prestige" is about the Pal; a host that switched
                -- prestige off is about the world, and every Pal in it reads
                -- the same. Blaming the Pal for the setting sends the player
                -- looking for a fault in their Pal.
                if Config.prestigeEnabled == false then
                    playerMessage = I18n.msg("prestigeOffHere")
                else
                    playerMessage = I18n.msg("hasNoPrestigeShort")
                end
            end
            return string.format("no enabled pair configured for '%s'", id),
                playerMessage
        end
        local shape = string.format("%s:%d:%s", id, n, tostring(isPrestige))
        if shape ~= lastOfferShape then
            lastOfferShape = shape
            Log(string.format("Offer: %s has %d option(s), prestige=%s",
                id, n, tostring(isPrestige)))
        end
        EvoNames.prewarmNames(id)
        return nil
    end)
    if not ok then
        offerVerdict("availability check failed: " .. tostring(reason))
        return false
    end
    -- No evolution, or no Pal out at all, still leaves a fusion: a party
    -- partner or the altar next to the player. With evolutions on offer as
    -- well, the fusions get an entry of their own.
    lastOfferFusionOnly = false
    lastOfferFusionEntry = false
    local okFuse, fusions = pcall(EvoWheel.fusionOptions, Role.localPlayerCtx())
    if not okFuse then
        Log("[WARN] fusion entries unreadable for the wheel: " .. tostring(fusions))
        fusions = {}
    end
    if #fusions > 0 then
        if reason ~= nil then
            reason, playerMsg = nil, nil
            lastOfferFusionOnly = true
        else
            lastOfferFusionEntry = true
        end
    end
    offerVerdict(reason, playerMsg)
    return reason == nil
end

-- Chat command: PREVIEW a prestige stage on the summoned Pal.
--
-- It changes nothing. No species swap, no save write, no cost, no gate - the
-- point is to watch a stage while it is being authored, on whatever Pal happens
-- to be out, including one that could never prestige.
--
-- The split exists because the chat hook fires on the AUTHORITY (a connected
-- client never sees its own line through it) while the effects are drawn on the
-- CLIENT. The host resolves the sender and freezes the Pal, the client plays.
--
-- Dev tool: gated on devMode like the other probe commands.
local PREVIEW_MODE = "prestigepreview"
-- Same split as the preview: the chat hook fires on the authority, the shimmer
-- is drawn on the client, so the name has to travel.
local GLOW_MODE = "prestigeglow"
-- Long enough for the whole schedule (grow plus hold is 3.4 s by default) with
-- room to spare, short enough that a forgotten Pal is free again quickly.
-- Replaced by a per-run lease below; kept as the floor for a single beat.
local PREVIEW_MIN_FREEZE_SECONDS = 4.0

local function previewReply(playerCtx, text)
    Log("prestige preview: " .. text)
    Role.chat(playerCtx, text, "reply")
end

function Evolution.runPrestigeCommand(senderCtx, args)
    if not Config.devMode then return end
    args = args or {}
    local playerCtx = senderCtx or Role.localPlayerCtx()
    if not playerCtx then
        Log("prestige preview: no player context for the sender")
        return
    end

    if args[1] == "list" then
        previewReply(playerCtx, PrestigeRecipes.describe())
        return
    end

    local stage = tonumber(args[1])
    local beatName = args[2]

    local holder = EvoUtil.findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then
        previewReply(playerCtx, I18n.msg("noPalSummoned"))
        return
    end

    local id = ""
    local param = EvoUtil.paramOf(actor)
    if param then
        local okId, raw = pcall(function() return param:GetCharacterID():ToString() end)
        if okId then id = EvoUtil.baseCharacterId(raw) end
    end

    -- No stage given: the Pal's own, so the command shows what THIS Pal would
    -- get. Falls back to 1 for a Pal that has never prestiged.
    if not stage then
        stage = 1
        local okStages, stages = pcall(PalPassives.resolve, param)
        if okStages and type(stages) == "table" and stages.prestige
            and (stages.prestige.stage or 0) > 0 then
            stage = stages.prestige.stage
        end
    end

    if beatName and not PrestigeRecipes.beatNamed(stage, beatName) then
        previewReply(playerCtx, string.format("stage %d has no beat '%s'", stage, beatName))
        return
    end

    -- The Pal has to stand still or it walks out of its own preview. Movement is
    -- server-authoritative, so this only works here, on the authority, and it is
    -- the same flag the real sequence uses.
    --
    -- The release runs off a DEADLINE rather than a single tick, so a missed
    -- callback cannot leave a Pal rooted to the ground. It is a preview: a stuck
    -- Pal would be a worse bug than the one it is testing.
    -- The lease is the run's own length plus a margin. A stage 10 preview is
    -- twenty seconds; a constant would release the Pal in the middle of it.
    local lease = PREVIEW_MIN_FREEZE_SECONDS
    if not beatName then
        lease = Timing.resolve(true, stage).fullPresentationMs / 1000 + 1.5
    end
    EvoPresent.setRevealFrozen(actor, true)
    local frozenActor = actor
    local until_ = os.clock() + lease
    GameLoop.start(250, function()
        if os.clock() < until_ then return false end
        if frozenActor and frozenActor:IsValid() then
            EvoPresent.setRevealFrozen(frozenActor, false)
        end
        Log("prestige preview: pal released")
        return true
    end, "prestige preview release")

    Log(string.format("prestige preview: %s stage %d%s", id, stage,
        beatName and (" beat " .. beatName) or ""))

    if not Role.isDedicated() then
        Evolution.playPrestigePreview(holder, actor, stage, beatName)
        return
    end

    local sent = false
    pcall(function()
        sent = NetChannel.sendPhaseStart(playerCtx.pc, PREVIEW_MODE,
            tostring(stage), beatName or "-", "evolution") ~= nil
    end)
    if not sent then Log("prestige preview: the signal to the sender FAILED") end
end

-- Chat command: swap the permanent prestige shimmer. The host owns the chat
-- line, every client owns its own effects, so the name goes over the wire and
-- each client re-marks what it can see.
function Evolution.runGlowCommand(senderCtx, args)
    if not Config.devMode then return end
    local playerCtx = senderCtx or Role.localPlayerCtx()
    if not playerCtx then return end
    local name = (args or {})[1] or ""

    if not Role.isDedicated() then
        local okMark, mark = pcall(require, "prestigemark")
        if not okMark then return end
        local ok, info = mark.setGlow(name)
        Role.chat(playerCtx, ok and ("glow: " .. tostring(info))
            or ("glow names: " .. tostring(info)), "reply")
        return
    end

    -- The host cannot answer whether the name is known: its own marker never
    -- ran. The client says so instead, in its log.
    local sent = false
    pcall(function()
        sent = NetChannel.sendPhaseStart(playerCtx.pc, GLOW_MODE,
            name ~= "" and name or "-", "-", "evolution") ~= nil
    end)
    Log(string.format("glow command: '%s' to the sender: %s", name,
        sent and "sent" or "FAILED"))
end

-- Client side of the preview. Runs the schedule at the summoned Pal without
-- touching it.
function Evolution.playPrestigePreview(holder, actor, stage, beatName)
    local target = actor
    if not (target and target:IsValid()) then
        pcall(function() target = holder:TryGetSpawnedOtomo() end)
    end
    if not (target and target:IsValid()) then
        Log("prestige preview: no pal to play it on")
        return
    end

    local loc = nil
    pcall(function() loc = target:K2_GetActorLocation() end)
    if not loc then
        Log("prestige preview: the pal has no location")
        return
    end

    local half, meshHalf = nil, nil
    pcall(function()
        local cap = target.CapsuleComponent
        if cap and cap:IsValid() then half = cap:GetScaledCapsuleHalfHeight() end
    end)
    pcall(function()
        local spc = target.StaticCharacterParameterComponent
        if spc and spc:IsValid() and spc.MeshCapsuleHalfHeight > 0 then
            meshHalf = spc.MeshCapsuleHalfHeight
        end
    end)

    local beats = nil
    if beatName and beatName ~= "-" then
        beats = PrestigeRecipes.beatNamed(stage, beatName)
    end

    Log(string.format("prestige preview: playing stage %s%s (collHalf=%s meshHalf=%s)",
        tostring(stage), beatName and beatName ~= "-" and (" beat " .. beatName) or "",
        tostring(half), tostring(meshHalf)))

    -- required here rather than at the top: fx.lua already owns the finale for
    -- the real sequence, and this file has no other use for it
    local okFinale, Finale = pcall(require, "finale")
    if not okFinale then
        Log("prestige preview: the finale module failed to load: " .. tostring(Finale))
        return
    end

    -- The wind-up effects belong to the preview as much as the finale does. A
    -- single beat is played bare: it is meant to be judged on its own.
    local intro = nil
    if not beats then
        local okFx, FX = pcall(require, "fx")
        if okFx and FX.previewIntro then
            local pawn = Role.localPlayerCtx() and Role.localPlayerCtx().pawn or nil
            intro = FX.previewIntro(holder, pawn, loc.X, loc.Y, loc.Z, half)
            local doneAt = os.clock() + Timing.resolve(true, stage).fullPresentationMs / 1000 + 1.5
            GameLoop.start(250, function()
                if os.clock() < doneAt then return false end
                FX.previewOutro(intro)
                return true
            end, "prestige preview outro")
        end
    end

    Finale.playStandalone(holder, loc.X, loc.Y, loc.Z, {}, half, meshHalf,
        { isPrestige = true, stage = stage, beats = beats })
end

function Evolution.offerIsPrestige()
    return lastOfferPrestige == true
end

--- kind "fusion": only the fusions (the wheel's own Fusion entry); kind
--- "evolve": only the evolutions while that entry exists; otherwise both.
function Evolution.listOptions(kind)
    if kind == "fusion" then
        if ServerCheck.blocked() then return {}, I18n.msg("serverNoPalvolveShort") end
        if EvoLock.lockBusy() then return {}, I18n.msg("evolutionRunning") end
        local fusions = EvoWheel.fusionOptions(Role.localPlayerCtx())
        if #fusions == 0 then return {}, I18n.msg("optionUnavailable") end
        return fusions
    end
    local options, reason = EvoWheel.evolutionOptions()
    if ServerCheck.blocked() or EvoLock.lockBusy() then return options, reason end
    if kind == "evolve" and lastOfferFusionEntry then return options, reason end
    local extras = EvoWheel.fusionOptions(Role.localPlayerCtx())
    if #extras == 0 then return options, reason end
    local merged = {}
    for _, o in ipairs(options or {}) do merged[#merged + 1] = o end
    for _, o in ipairs(extras) do merged[#merged + 1] = o end
    return merged
end

-- Authoritative evolve request: re-derives and re-validates EVERYTHING from
-- the requesting player's context; caller-supplied data is only the pair
-- NAMES, never handles. Serves the in-process path (standalone/listen host)
-- and decoded network requests. Returns ok, message.
local function handleEvolveRequest(playerCtx, fromId, toId, exactPairIndex, prestigeRequest)
    if EvoLock.lockBusy() then
        return false, I18n.msg("evolutionRunning")
    end
    if not (playerCtx and playerCtx.pc and playerCtx.pc:IsValid()) then
        return false, "Requesting player unavailable"
    end
    local okAuthority, hasAuthority = pcall(EvoUtil.controllerHasAuthority, playerCtx.pc)
    if not okAuthority or not hasAuthority then
        return false, "Evolution requires host authority"
    end
    local holder = EvoUtil.findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return false, I18n.msg("noPalSummoned") end
    local param = EvoUtil.paramOf(actor)
    if not (param and EvoUtil.isOwnedBy(param, playerCtx.playerUId)) then
        return false, I18n.msg("noPalSummoned")
    end
    -- A fused Pal is two Pals for as long as the fusion lasts; evolving or
    -- prestiging it would write over the species the split has to restore.
    local okFusion, Fusion = pcall(require, "fusion")
    if okFusion and Fusion.isFused(param) then
        return false, I18n.msg("fusionBusy")
    end
    -- On the ground the rider is taken off first; in the air that would drop them.
    if Ride.ridingInAir(actor) then
        return false, I18n.msg("landFirst")
    end
    local id, isAlpha = EvoUtil.baseCharacterId(param:GetCharacterID():ToString())
    if id ~= fromId then
return false, I18n.msg("selectionOutdated", EvoNames.palDisplayName(id), EvoNames.palDisplayName(fromId))
    end
    -- The pair is re-resolved from the mod config, never taken from the
    -- request. Several same-target variants may exist (either/or conditions):
    -- the first candidate that passes every gate wins, so a stale client pick
    -- still lands on whichever variant currently holds.
    local pairList = nil
    if prestigeRequest then
        -- An enabled evolution or funchain is an absolute precedence gate. Its
        -- level or conditions may be unmet, but prestige cannot bypass it. An
        -- adaptation is no such gate: it is the same Pal in another element.
        if Config.hasProgressPair(id) then return false, I18n.msg("optionUnavailable") end
        pairList = Prestige.forSpecies(Config, id)
    else
        pairList = Config.findPairs(id)
    end
    local candidates = {}
    if exactPairIndex ~= nil then
        local indexed = nil
        if prestigeRequest then
            for _, candidate in ipairs(pairList) do
                if candidate.prestigeIndex == tonumber(exactPairIndex) then
                    indexed = candidate
                    break
                end
            end
        else
            indexed = pairList[tonumber(exactPairIndex)]
        end
        if indexed and indexed.to == toId then candidates[1] = indexed end
    else
        for _, cand in ipairs(pairList) do
            if cand.to == toId then table.insert(candidates, cand) end
        end
    end
    if #candidates == 0 then
        return false, I18n.msg("noConfiguredEvolution",
            EvoNames.palDisplayName(id), EvoNames.palDisplayName(tostring(toId)))
    end
    local level = 0
    pcall(function() level = param:GetLevel() end)
    local condCtx = { actor = actor, param = param, playerCtx = playerCtx, holder = holder }
    local pair, failReason = nil, nil
    local bestConditionCount = -1
    for _, cand in ipairs(candidates) do
        local unknownReason = EvoUtil.unknownConditionReason(cand)
        if unknownReason then
            failReason = failReason or unknownReason
        elseif isAlpha and not EvoUtil.swapTargetId(cand, true) then
            failReason = failReason or I18n.msg("noAlphaForm", EvoNames.palDisplayName(cand.to))
        elseif level < EvoState.requiredLevelFor(cand, param) then
            failReason = failReason or I18n.msg(
                prestigeRequest and "needsLevelPrestige" or "needsLevel",
                EvoNames.palDisplayName(id), EvoState.requiredLevelFor(cand, param), level)
        else
            local condOk, unmet = Conditions.evaluate(cand, condCtx)
            -- The same relaxation listOptions applies when it draws the wheel.
            -- Without it here the entry is offered ungreyed, marked as unlocked,
            -- and then refused on the way in - which is the one situation the
            -- unlock exists to prevent.
            if not condOk and EvoState.AutoUnlock.has(param, cand.to) then condOk = true end
            if condOk then
                local count = EvoUtil.conditionCount(cand)
                if exactPairIndex ~= nil or Config.evolutionMode ~= "conditioned"
                    or count > bestConditionCount then
                    pair = cand
                    bestConditionCount = count
                end
                if exactPairIndex ~= nil or Config.evolutionMode ~= "conditioned" then break end
            end
            failReason = failReason or I18n.msg("needsConditions",
                EvoNames.palDisplayName(cand.to), EvoUtil.disclosedConditions(cand, unmet))
        end
    end
    if not pair then
        return false, failReason or I18n.msg("optionUnavailable")
    end
    -- fresh cost pre-check for a readable message; the transaction inside
    -- performEvolution is the authoritative consume
    local costList = Costs.resolve(pair, level, holder)
    local costOk, missing = Costs.check(playerCtx, costList)
    if not costOk then
        if prestigeRequest then
            return false, I18n.msg("couldPrestigeMissing",
                EvoNames.palDisplayName(id), level, EvoNames.palDisplayName(pair.to), Costs.describeMissing(missing))
        end
        return false, I18n.msg("couldEvolveMissing",
            EvoNames.palDisplayName(id), level, EvoNames.palDisplayName(pair.to), Costs.describeMissing(missing))
    end
    -- ok = the sequence STARTED; asynchronous stage failures surface via
    -- the sequence's own logging/abort handling (the network layer sends
    -- no completion acknowledgements)
    local started, reason = performEvolution({ actor = actor, param = param, pair = pair,
        holder = holder, key = EvoUtil.individualKey(param), isAlpha = isAlpha,
        playerCtx = playerCtx })
    if not started then
        return false, reason or I18n.msg("optionUnavailable")
    end
    return true
end

-- Host entry for a decoded network request: the client only sent WHICH
-- radial option it picked (an index into the sender's evolution pairs). The
-- host re-derives the pair from ITS OWN config at that index and hands off
-- to the fully-revalidating handleEvolveRequest. Returns ok, message (the
-- message is chatted back to the requester).
local function handleByIndex(playerCtx, pairIndex, prestigeRequest)
    local holder = EvoUtil.findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return false, I18n.msg("noPalSummoned") end
    local param = EvoUtil.paramOf(actor)
    if not (param and EvoUtil.isOwnedBy(param, playerCtx and playerCtx.playerUId)) then
        return false, I18n.msg("noPalSummoned")
    end
    local numericIndex = tonumber(pairIndex)
    if not numericIndex or numericIndex % 1 ~= 0 or numericIndex < 1 or numericIndex > 255 then
        return false, I18n.msg("optionUnavailable")
    end
    local okId, rawId = pcall(EvoUtil.characterIdUnsafe, param)
    if not okId then return false, I18n.msg("optionUnavailable") end
    local baseId = EvoUtil.baseCharacterId(rawId)
    local pair = nil
    if prestigeRequest then
        -- Global prestige indices address the host's complete target list.
        -- The source check below prevents an index for another Pal from being
        -- replayed against the one the requester currently has summoned.
        if Config.hasProgressPair(baseId) then return false, I18n.msg("optionUnavailable") end
        local targets = Prestige.targets(Config)
        pair = targets and targets[numericIndex]
        if pair and pair.from ~= baseId then pair = nil end
    else
        local pairList = Config.findPairs(baseId)
        pair = pairList and pairList[numericIndex]
    end
    if not pair then
        return false, I18n.msg("optionUnavailable")
    end
    local ok, msg = handleEvolveRequest(playerCtx, baseId, pair.to, numericIndex, prestigeRequest)
    if ok then
        if prestigeRequest then return true, I18n.msg("prestigingInto", EvoNames.palDisplayName(pair.to)) end
        return true, I18n.msg("evolvingInto", EvoNames.palDisplayName(pair.to))
    end
    return false, msg
end

EvoAuto.handleEvolveByIndex = function(playerCtx, pairIndex)
    return handleByIndex(playerCtx, pairIndex, false)
end

EvoAuto.handlePrestigeByIndex = function(playerCtx, targetIndex)
    return handleByIndex(playerCtx, targetIndex, true)
end

--- Opens the pick window for the altar next to the local player; its confirm
--- starts the fusion (on a client: asks the host). Returns true when it opened.
function Evolution.openAltarPick()
    local fuseCtx = Role.localPlayerCtx()
    if not fuseCtx then
        Log(I18n.msg("noLocalPlayer"))
        return false
    end
    local authority = Role.hasWorldAuthority()
    local Altar = require("altar")
    local info, why = Altar.pickInfo(fuseCtx)
    if not info then
        Log("altar pick not offered: " .. tostring(why))
        Role.chat(fuseCtx, why, "reply")
        return false
    end
    local opened = require("fusepick").open(info, function(choice)
        if authority then
            Altar.start(fuseCtx, choice, { allowCage = Config.devMode })
        elseif not remoteTransmitReady(fuseCtx) then
            Log("[WARN] altar pick confirmed, but the host is not reachable")
        elseif not NetChannel.sendFuseAltarChoice(fuseCtx, choice.passiveIndexes, choice.gender) then
            local msg = I18n.msg("serverUnreachable")
            Log(msg)
            Role.chat(fuseCtx, msg, "reply")
        end
    end)
    if not opened then Log("[WARN] the altar pick window did not open") end
    return opened
end

-- Executes one option from listOptions - the submenu selection IS the
-- confirmation. Only the pair names travel; the authority re-derives
-- fresh handles and re-validates.
function Evolution.executeOption(opt)
    if opt and opt.fusion then
        local fuseCtx = Role.localPlayerCtx()
        if not fuseCtx then
            Log(I18n.msg("noLocalPlayer"))
            return
        end
        local authority = Role.hasWorldAuthority()
        if opt.fusion == "altar" then
            Evolution.openAltarPick()
            return
        end
        if authority then
            if opt.fusion == "altar" then
                require("altar").start(fuseCtx, nil, { allowCage = Config.devMode })
            else
                require("fusion").startBattle(fuseCtx, opt.partnerSlot)
            end
            return
        end
        if not remoteTransmitReady(fuseCtx) then return end
        local sent
        if opt.fusion == "altar" then
            sent = NetChannel.sendFuseAltar(fuseCtx)
        else
            sent = NetChannel.sendFuseBattle(fuseCtx, opt.partnerSlot)
        end
        if not sent then
            local msg = I18n.msg("serverUnreachable")
            Log(msg)
            Role.chat(fuseCtx, msg, "reply")
        end
        return
    end
    -- The lock entry is not an evolution and carries no pair, so it is answered
    -- before the pair check that every other path relies on. It still takes the
    -- same role split as every other path: the passive lives on the Pal, and a
    -- client writing it touches a replica the host never reads, so the Pal would
    -- go on auto-evolving while the player watched the passive appear.
    if opt and opt.autoLock then
        local lockCtx = Role.localPlayerCtx()
        if not lockCtx then
            Log(I18n.msg("noLocalPlayer"))
            return
        end
        if Role.hasWorldAuthority() then
            Evolution.toggleAutoLock(lockCtx)
        else
            if not NetChannel.sendAutoLock(lockCtx) then
                Log("auto-lock request could not be sent to the host")
                Role.chat(lockCtx, I18n.msg("autoLockFailed", ""), "reply")
            end
        end
        return
    end
    if not (opt and opt.pair) then return end
    local playerCtx = Role.localPlayerCtx()
    -- The wheel is the path everyone has: F2 is off unless a player turns it
    -- on, so the timer warning cannot live on the key alone. Same two
    -- thresholds as there, warn early and refuse once it is certain.
    if EvoLock.timersDead() then
        EvoLock.reportDeadTimers(playerCtx)
        if EvoLock.timersGone() then return end
    end
    -- the option was greyed out in the wheel (missing materials, too low a
    -- level, no Alpha form): the reason goes to the player chat, not
    -- only to the log
    if opt.blocked then
        Log(opt.blocked)
        if Role.hasWorldAuthority() then
            Role.chat(playerCtx, opt.blocked, "reply")
        elseif remoteTransmitReady(playerCtx) then
            -- pure client: don't attribute the reason locally ("[Name]: ..."). Send
            -- the picked option so the host re-validates and rejects it with a
            -- private [SYSTEM] line; the host consumes nothing on a rejected evolve.
            if opt.prestige then
                NetChannel.sendPrestige(playerCtx, opt.index or 0)
            else
                NetChannel.sendEvolve(playerCtx, opt.index or 0)
            end
        end
        return
    end
    if not playerCtx then
        Log(I18n.msg("noLocalPlayer"))
        return
    end
    if Role.hasWorldAuthority() then
        -- re-validation can still fail (state changed since the wheel was
        -- built); surface that reason in chat too
        local ok, msg
        if opt.prestige then
            ok, msg = EvoAuto.handlePrestigeByIndex(playerCtx, opt.index)
        else
            ok, msg = EvoAuto.handleEvolveByIndex(playerCtx, opt.index)
        end
        if not ok and msg then
            Log(msg)
            Role.chat(playerCtx, msg, "reply")
        end
    else
        -- connected client: send the picked option index to the host over
        -- the net channel. The host does the authoritative swap and, on
        -- success, signals this client to re-play the transformation locally
        -- (Evolution.playRemoteReveal, via the net channel client hook).
        if not remoteTransmitReady(playerCtx) then return end
        lastRemotePair = opt.pair
        local sent
        if opt.prestige then
            sent = NetChannel.sendPrestige(playerCtx, opt.index or 0)
        else
            sent = NetChannel.sendEvolve(playerCtx, opt.index or 0)
        end
        if not sent then
            local msg = I18n.msg("serverUnreachable")
            Log(msg)
            Role.chat(playerCtx, msg, "reply")
        end
    end
end

-- Dev-only entry for the probes' full-run cycle: evolve the summoned pal
-- into toId with NO gates - no level/alpha/condition/cost checks and no
-- configured pair needed. The synthetic pair exists only inside this call;
-- costs still resolve, so the probe keeps free mode forced.
function Evolution.debugEvolveTo(toId)
    if not Config.devMode then return false, "devMode off" end
    -- HARD authority gate: performEvolution manipulates the actor
    -- (freeze, collision, despawn/respawn). On a client connected to a
    -- server the pal is a replicated proxy - local writes are ghosts at
    -- best and native crashes at worst (see fx.lua remoteBurst). The dev
    -- full-run is therefore ModDev/host only.
    if not Role.hasWorldAuthority() then
        return false, "debug evolve needs world authority - use the ModDev world (SP), not a server connection"
    end
    if EvoLock.lockBusy() then return false, I18n.msg("evolutionRunning") end
    local playerCtx = Role.localPlayerCtx()
    if not playerCtx then return false, I18n.msg("noLocalPlayer") end
    local holder = EvoUtil.findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return false, I18n.msg("noPalSummoned") end
    local param = EvoUtil.paramOf(actor)
    if not (param and EvoUtil.isOwnedBy(param, playerCtx.playerUId)) then
        return false, I18n.msg("noPalSummoned")
    end
    local id = EvoUtil.baseCharacterId(param:GetCharacterID():ToString())
    local pair = { from = id, to = toId, category = "evolution",
        minLevel = 1, stone = "evolution", enabled = true }
    return performEvolution({ actor = actor, param = param, pair = pair,
        holder = holder, key = EvoUtil.individualKey(param), isAlpha = false,
        playerCtx = playerCtx })
end

-- CLIENT presentation, driven by the host's phase signals. Reuses the EXACT
-- singleplayer fx staging (dissolve/hide/gap/preReveal/reveal - timing, glow,
-- element bursts, peak loop, finale) so the look is 1:1; the lifecycle
-- (recall/re-summon) goes through the vanilla client-facing controller RPCs,
-- and the host owns freeze + position + the pool break.
--   start  = host froze + swapped the pal -> dissolve, then recall
--   ready  = host destroyed the old pooled body -> re-summon the new form
--   reveal = host teleported + froze the fresh pal at the old spot -> grow/finale
function Evolution.onNetSignal(kind, phaseInfo)
    local playerCtx = Role.localPlayerCtx()
    if not playerCtx then return end
    local holder = EvoUtil.findHolderFor(playerCtx, nil)
    if not holder then return end

    Log("[mpseq-c] signal: " .. tostring(kind))
    -- The preview is not a sequence: nothing is swapped, so it never enters the
    -- remote reveal state machine and never claims the busy lock.
    if kind == "start" and phaseInfo and phaseInfo.mode == GLOW_MODE then
        local okMark, mark = pcall(require, "prestigemark")
        if okMark then
            local ok, info = mark.setGlow(phaseInfo.from or "")
            if not ok then Log("glow names: " .. tostring(info)) end
        end
        return
    end
    if kind == "start" and phaseInfo and phaseInfo.mode == PREVIEW_MODE then
        -- the descriptor rides in the two id fields of the phase frame: stage
        -- in `from`, beat name in `to`
        Evolution.playPrestigePreview(holder, nil,
            tonumber(phaseInfo.from) or 1, phaseInfo.to)
        return
    end
    if RemotePresentation.consume(kind, phaseInfo, function()
        local pc = playerCtx and playerCtx.pc
        if pc and pc:IsValid() then pc:InactiveOtomo() end
    end) then
        Log("[mpseq-c] safe presentation: normal recall used; unstable cinematic skipped")
        return
    end
    if kind == "start" then
        if EvoRemote.remoteRevealBusy and (os.clock() - EvoRemote.remoteRevealStart) < 20 then return end
        if phaseInfo and phaseInfo.from and phaseInfo.to then
            -- A host-started automatic evolution has no preceding wheel click,
            -- so the v3 start frame is the only presentation identity the
            -- client owns. Legacy clients still use lastRemotePair from their
            -- manual request.
            lastRemotePair = {
                from = phaseInfo.from,
                to = phaseInfo.to,
                stone = phaseInfo.stone,
                category = phaseInfo.mode,
                prestigeStage = phaseInfo.stage,
            }
        end
        local actor = nil
        pcall(function() actor = holder:TryGetSpawnedOtomo() end)
        if not (actor and actor:IsValid()) then return end
        EvoRemote.remoteRevealBusy = true
        EvoRemote.remoteRevealStart = os.clock()
        EvoRemote.remoteCtx = EvoRemote.buildRemoteCtx(actor, holder, playerCtx, lastRemotePair)
        local toName = lastRemotePair and EvoNames.palDisplayName(lastRemotePair.to) or "its new form"
        -- The same step by its own name. This line is the only one a client
        -- gets for a host-run step, and it said "evolving" for a prestige too -
        -- the one word the player uses to tell the two apart.
        -- A fusion has its own line from the host and its own impact sound.
        if not EvoRemote.remoteCtx.fusionKind then
            local startKey = (lastRemotePair and lastRemotePair.category == "prestige")
                and "prestigingInto" or "evolvingInto"
            Role.chat(playerCtx, I18n.msg(startKey, toName))
            pcall(function() EvoPresent.playFanfare(actor) end)
        end
        pcall(function() FX.onDissolve(EvoRemote.remoteCtx) end)
        -- after the dissolve, start the hold loop and recall the pal
        local dur = 1200
        pcall(function() if FX.dissolveDurationMs then dur = FX.dissolveDurationMs(EvoRemote.remoteCtx) end end)
        GameLoop.after(dur, function()
            -- Teardown guard, same reason as the server watcher above:
            -- leaving for the main menu destroys the controller while this
            -- deferred callback is still scheduled, and a UFunction call on
            -- a freed UObject is a native fault that pcall does NOT catch.
            -- Re-resolve instead of trusting the handle captured a full
            -- dissolve ago, and abort the presentation if the world is gone.
            local livePc = Role.getLocalPlayerController()
            if not (livePc and livePc:IsValid()) then
                Log("remote reveal: player controller gone after the dissolve, cleaning up")
                if EvoRemote.remoteCtx then pcall(function() FX.cleanup(EvoRemote.remoteCtx) end) end
                EvoRemote.remoteRevealBusy = false
                EvoRemote.remoteCtx = nil
                return
            end
            if EvoRemote.remoteCtx then pcall(function() FX.onHide(EvoRemote.remoteCtx) end) end
            local okRecall, errRecall = pcall(function() livePc:InactiveOtomo() end)
            if not okRecall then Log("remote reveal: recall failed: " .. tostring(errRecall)) end
        end, "remote reveal recall")

    elseif kind == "reveal" then
        if not EvoRemote.remoteCtx then return end
        local a = nil
        pcall(function() a = holder:TryGetSpawnedOtomo() end)
        if not (a and a:IsValid()) then EvoRemote.remoteRevealBusy = false; return end
        EvoRemote.remoteCtx.worldCtx = holder
        -- The server now places the pal at the correct height (it reads the
        -- absolute capsule half from the static parameter component), so
        -- anchor the finale to where the pal actually stands and size the beam
        -- spread to the species. Height comes from the same static source (also
        -- available on the client), falling back to the capsule accessor.
        -- scaled COLLISION capsule for the physics anchor; the mesh-space
        -- body half goes to the FX framing separately
        local nh = nil
        pcall(function()
            local cap = a.CapsuleComponent
            if cap and cap:IsValid() then nh = cap:GetScaledCapsuleHalfHeight() end
        end)
        if not (nh and nh > 0) then nh = 30 end
        pcall(function()
            local mh = EvoUtil.staticCapsuleHalf(a)
            if mh and mh > 0 then EvoRemote.remoteCtx.meshHalfTo = mh end
        end)
        -- Anchor the finale to where the pal actually stands; leaving
        -- finaleRadius/Za/Zb unset keeps the tight singleplayer default spread.
        pcall(function()
            local loc = a:K2_GetActorLocation()
            EvoRemote.remoteCtx.newHalf = nh
            EvoRemote.remoteCtx.oldX, EvoRemote.remoteCtx.oldY, EvoRemote.remoteCtx.oldZ = loc.X, loc.Y, loc.Z
            -- oldZ is now the NEW pal's center - the finale derives its
            -- ground/grown-center anchors from that instead of old-half math
            EvoRemote.remoteCtx.centerAnchored = true
        end)
        pcall(function() FX.onPreReveal(EvoRemote.remoteCtx, a) end)
        GameLoop.after((FX.revealDelayMs and FX.revealDelayMs()) or 100, function()
            local okReveal, errReveal = pcall(function() FX.onReveal(EvoRemote.remoteCtx, a) end)
            if not okReveal then Log("remote reveal: staging failed: " .. tostring(errReveal)) end
            pcall(function() EvoPresent.playFanfare(a) end)
            EvoPresent.refreshPartyHud(EvoUtil.findHolderFor(Role.localPlayerCtx(), nil))
        end, "remote reveal")
        -- safety: never leave the busy flag stuck if the reveal driver stalls
        GameLoop.after(9000, function()
            EvoRemote.remoteRevealBusy = false
        end, "remote reveal busy reset")
    end
end

--- Sets or clears the auto-evolve veto on the Pal the player has out.
---
--- Reached from the wheel and from chat, because one is how it gets found and
--- the other is how somebody locks six Pals without opening a menu six times.
--- Flips the veto on the summoned Pal and says which way it went.
---
--- The wheel entry cannot label itself with the current state, because the wheel
--- is built without knowing which Pal is out. So the answer arrives in chat.
--- Is the Pal the player has out left alone by auto-evolve?
---
--- The wheel asks this to put the state in the middle of the ring, the way a
--- target puts its requirements there. It answers for the SUMMONED Pal, which
--- is the one the wheel is about, and false for "no Pal out" - the entry then
--- reads as off, which is what acting on it would produce.
function Evolution.isAutoLocked(senderCtx)
    local playerCtx = senderCtx or Role.localPlayerCtx()
    if not playerCtx then return false end
    local holder = EvoUtil.findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return false end
    local param = EvoUtil.paramOf(actor)
    if not param then return false end
    return EvoState.AutoLock.isLocked(param)
end

function Evolution.toggleAutoLock(senderCtx)
    local playerCtx = senderCtx or Role.localPlayerCtx()
    local holder = EvoUtil.findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then
        Role.ack(playerCtx, I18n.msg("noPalSummoned"))
        return false
    end
    local param = EvoUtil.paramOf(actor)
    if not (param and EvoUtil.isOwnedBy(param, playerCtx and playerCtx.playerUId)) then
        Role.ack(playerCtx, I18n.msg("greyNotYours"))
        return false
    end
    return Evolution.runAutoLockCommand(playerCtx, not EvoState.AutoLock.isLocked(param))
end

function Evolution.runAutoLockCommand(senderCtx, wanted)
    local playerCtx = senderCtx or Role.localPlayerCtx()
    local holder = EvoUtil.findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then
        Role.ack(playerCtx, I18n.msg("noPalSummoned"))
        return false
    end
    local param = EvoUtil.paramOf(actor)
    if not (param and EvoUtil.isOwnedBy(param, playerCtx and playerCtx.playerUId)) then
        Role.ack(playerCtx, I18n.msg("greyNotYours"))
        return false
    end
    local id = EvoUtil.baseCharacterId(param:GetCharacterID():ToString())
    local ok = EvoState.AutoLock.set(param, wanted)
    if not ok then
        Role.ack(playerCtx, I18n.msg("autoLockFailed", EvoNames.palDisplayName(id)))
        return false
    end
    Role.ack(playerCtx, I18n.msg(wanted and "autoLocked" or "autoUnlocked",
        EvoNames.palDisplayName(id)))
    return true
end

function Evolution.rollbackLast(playerCtx)
    -- Role.ack, not Role.chat: the EnterChat hook fires on the sender's client
    -- AND on the authority, so on a dedicated server this function runs twice.
    -- The client run works against an empty local snapshot list and would
    -- answer "no snapshot available" moments before the server's real reply
    -- lands, leaving two contradicting lines on screen.
    local function say(msg)
        if playerCtx then return Role.ack(playerCtx, msg) end
        Log(msg)
    end
    if EvoLock.lockBusy() then
        say(I18n.msg("rollbackBlocked"))
        return
    end
    -- Remove the snapshot only after the restore succeeded (no data loss on
    -- failure). A requester rolls back THEIR latest evolution: the stack is
    -- searched from the top for a snapshot owned by them; entries without an
    -- owner uid stay reachable from the authority console path only.
    local snapIdx = nil
    local requesterUid = nil
    pcall(function()
        local u = playerCtx and playerCtx.playerUId
        if u then requesterUid = string.format("%08X-%08X-%08X-%08X", u.A, u.B, u.C, u.D) end
    end)
    for i = #EvoSnap.snapshots, 1, -1 do
        local s = EvoSnap.snapshots[i]
        if not requesterUid then
            snapIdx = i
            break
        end
        if s.uid and s.uid == requesterUid then
            snapIdx = i
            break
        end
    end
    local last = snapIdx and EvoSnap.snapshots[snapIdx]
    if not last then
        say(I18n.msg("rollbackNoSnapshot"))
        return
    end
    local reverted = false
    local restoreFailed = false
    local all = FindAllOf("PalIndividualCharacterParameter") or {}
    local hasKey = last.key and last.key ~= ""
    -- owner isolation: a snapshot with a stored owner uid may only ever
    -- restore a pal of that same player (legacy snapshots have no uid)
    local function ownerMatches(p)
        if not (last.uid and last.uid ~= "") then return true end
        local m = false
        pcall(function()
            m = EvoUtil.guidString(p.SaveParameter.OwnerPlayerUId) == last.uid
        end)
        return m
    end
    for _, p in ipairs(all) do
        if p:IsValid() and EvoUtil.isOwned(p) and ownerMatches(p)
            and Config.canonicalId(p:GetCharacterID():ToString()) == Config.canonicalId(last.to) then
            -- With a key only the exact match counts (a species fallback could
            -- hit the wrong individual, e.g. SmallYeti->Yeti vs MopKing->Yeti)
            local match = hasKey and (EvoUtil.individualKey(p) == last.key) or (not hasKey)
            if match then
                local prestigeAfter = nil
                if last.kind == "prestige" then
                    local prestigeAfterErr
                    prestigeAfter, prestigeAfterErr = EvoState.capturePrestigeState(p)
                    if not prestigeAfter then
                        Log("ROLLBACK CURRENT PRESTIGE SNAPSHOT FAILED: "
                            .. tostring(prestigeAfterErr))
                        break
                    end
                end
                local passivesAfter, passiveAfterErr = PalPassives.capture(p)
                if not passivesAfter then
                    Log("ROLLBACK CURRENT PASSIVE CAPTURE FAILED: " .. tostring(passiveAfterErr))
                    restoreFailed = true
                    break
                end
                local skinAfter = nil
                if last.skin then
                    local skinAfterErr
                    skinAfter, skinAfterErr = EvoState.captureSkinState(p)
                    if not skinAfter then
                        Log("ROLLBACK CURRENT SKIN CAPTURE FAILED: " .. tostring(skinAfterErr))
                        restoreFailed = true
                        break
                    end
                end
                local wazaAfter = nil
                if last.waza then
                    local wazaAfterErr
                    wazaAfter, wazaAfterErr = WazaInherit.capture(p)
                    if not wazaAfter then
                        Log("ROLLBACK CURRENT MOVE CAPTURE FAILED: " .. tostring(wazaAfterErr))
                        restoreFailed = true
                        break
                    end
                end
                local passivesRestored, passiveRestoreErr = PalPassives.restore(p, last.passives)
                if not passivesRestored then
                    Log("ROLLBACK PASSIVE RESTORE FAILED: " .. tostring(passiveRestoreErr))
                    restoreFailed = true
                    break
                end
                pcall(function()
                    p.SaveParameter.CharacterID = FName(last.from)
                    p.SaveParameterMirror.CharacterID = FName(last.from)
                end)
                local idNow = ""
                pcall(function() idNow = p:GetCharacterID():ToString() end)
                if Config.canonicalId(idNow) == Config.canonicalId(last.from) then
                    local survivorsRestored, survivorRestoreErr =
                        EvoState.restoreSwapSurvivors(p, last.skin, last.waza)
                    if not survivorsRestored then
                        Log("ROLLBACK SKIN/MOVE RESTORE FAILED: " .. tostring(survivorRestoreErr))
                        local undoOk, undoErr
                        if prestigeAfter then
                            undoOk, undoErr = EvoState.restorePrestigeState(p, prestigeAfter)
                        else
                            local speciesOk, speciesErr = pcall(EvoState.writeSpeciesUnsafe, p, last.to)
                            local passiveOk, passiveErr = PalPassives.restore(p, passivesAfter)
                            undoOk = speciesOk and passiveOk
                            undoErr = tostring(speciesErr) .. "; " .. tostring(passiveErr)
                        end
                        local survivorUndoOk, survivorUndoErr =
                            EvoState.restoreSwapSurvivors(p, skinAfter, wazaAfter)
                        if not undoOk or not survivorUndoOk then
                            Log("ROLLBACK REAPPLY FAILED after skin/move restore failed: "
                                .. tostring(undoErr) .. "; " .. tostring(survivorUndoErr))
                        end
                        restoreFailed = true
                        break
                    end
                    local restore = {
                        Talent_HP = last.ivHP, Talent_Melee = last.ivMelee,
                        Talent_Shot = last.ivShot, Talent_Defense = last.ivDefense,
                    }
                    for field, v in pairs(restore) do
                        if v and v >= 0 then
                            local ok, err = pcall(function()
                                p.SaveParameter[field] = v
                                p.SaveParameterMirror[field] = v
                            end)
                            if not ok then
                                Log("Rollback: " .. field .. " could not be restored: " .. tostring(err))
                            end
                        end
                    end
                    local levelRestored = true
                    if last.kind == "prestige" then
                        local mirrorLevel = last.mirrorLevel
                        if mirrorLevel == nil then mirrorLevel = last.level end
                        local mirrorExp = last.mirrorExp
                        if mirrorExp == nil then mirrorExp = last.exp end
                        local okLevel = pcall(EvoState.writePrestigeLevelUnsafe, p,
                            last.level, last.exp, mirrorLevel, mirrorExp)
                        local expected = {
                            characterId = last.from,
                            level = last.level,
                            exp = last.exp,
                            mirrorLevel = mirrorLevel,
                            mirrorExp = mirrorExp,
                        }
                        local okFields, fieldsMatch = pcall(EvoState.prestigeFieldsMatchUnsafe, p, expected)
                        levelRestored = okLevel and okFields and fieldsMatch
                    end
                    if levelRestored then
                        -- mirror the forward path: normalize HP after the
                        -- species/IV/level change (current HP may exceed the
                        -- restored form's maximum otherwise)
                        pcall(function() p:FullRecoveryHP() end)
                        EvoPresent.refreshWorkSuitability(p, nil)
                        reverted = true
                        pcall(function() EvoPresent.resummonAfterRollback(playerCtx, p) end)
                    elseif prestigeAfter then
                        local undoOk, undoErr = EvoState.restorePrestigeState(p, prestigeAfter)
                        local survivorUndoOk, survivorUndoErr =
                            EvoState.restoreSwapSurvivors(p, skinAfter, wazaAfter)
                        if not undoOk then
                            Log("ROLLBACK PRESTIGE REAPPLY FAILED after level restore failed: "
                                .. tostring(undoErr))
                        end
                        if not survivorUndoOk then
                            Log("ROLLBACK SKIN/MOVE REAPPLY FAILED after level restore failed: "
                                .. tostring(survivorUndoErr))
                        end
                        restoreFailed = true
                    end
                elseif prestigeAfter then
                    local undoOk, undoErr = EvoState.restorePrestigeState(p, prestigeAfter)
                    if not undoOk then
                        Log("ROLLBACK PRESTIGE REAPPLY FAILED after species restore failed: "
                            .. tostring(undoErr))
                    end
                elseif passivesAfter then
                    local passiveUndoOk, passiveUndoErr = PalPassives.restore(p, passivesAfter)
                    if not passiveUndoOk then
                        Log("ROLLBACK PASSIVE REAPPLY FAILED after species restore failed: "
                            .. tostring(passiveUndoErr))
                    end
                end
                break
            end
        end
    end
    if reverted then
        -- Give the price back: the evolution is undone, so keeping the stones
        -- would charge for something that no longer happened. Only after the
        -- restore actually succeeded, and only what this evolution recorded.
        -- Three outcomes, three messages. A refund that could not be paid out
        -- must not read like a rollback that had nothing to pay back: there the
        -- stones and the restore point are both gone, and one shared line would
        -- report that as an ordinary rollback.
        local hadCost = last.cost and #last.cost > 0
        local refunded = false
        if hadCost then
            pcall(function()
                refunded = Costs.refund(playerCtx, last.cost)
                Log(refunded and ("Rollback refunded: " .. Costs.describe(last.cost))
                    or "Rollback refund FAILED (inventory full?) - "
                       .. Costs.describe(last.cost) .. " not returned")
            end)
        end
        -- The snapshot goes either way: the species is already reverted, so
        -- keeping it would offer a second rollback of something that has
        -- already been rolled back.
        table.remove(EvoSnap.snapshots, snapIdx)
        local key = "rollbackDone"
        if hadCost then key = refunded and "rollbackDoneRefunded" or "rollbackDoneRefundFailed" end
        say(I18n.msg(key, EvoNames.palDisplayName(last.to), EvoNames.palDisplayName(last.from)))
    elseif restoreFailed then
        say(I18n.msg("rollbackStateRestoreFailed"))
    else
        say(I18n.msg("rollbackNoMatch", EvoNames.palDisplayName(last.to)))
    end
end

-- ---------------------------------------------------------------- auto evolve

function Evolution.init()
    EvoSnap.loadSnapshots()
    local conditionsOk, conditionsErr = pcall(Conditions.init)
    if not conditionsOk then Log("condition hooks failed to initialize: " .. tostring(conditionsErr)) end
    EvoAuto.startAutoWatcher()

    -- authority entry for in-process and network requests
    Authority.bind({ evolve = handleEvolveRequest })

    -- host side of the net channel: decode connected-client evolve requests
    -- and run them through the fully-revalidating index handler. The hook
    -- fires only where the game routes _ToServer RPCs (the authority); on a
    -- pure client it registers but never fires.
    -- altar picks a client sent ahead of its altar request, by player
    local fusePicks = {}
    local function fusePickKey(ctx)
        local g = ctx and ctx.playerUId
        return g and string.format("%s-%s-%s-%s", tostring(g.A), tostring(g.B), tostring(g.C), tostring(g.D)) or "?"
    end
    NetChannel.initHost(function(senderCtx, request)
        local pairIndex = type(request) == "table" and request.index or request
        local opcode = type(request) == "table" and request.opcode or NetChannel.OP_EVOLVE_LEGACY
        if opcode == NetChannel.OP_PRESTIGE then
            return EvoAuto.handlePrestigeByIndex(senderCtx, pairIndex)
        end
        if opcode == NetChannel.OP_AUTOLOCK then
            -- senderCtx is the requesting player resolved on this side, so the
            -- lock is written on the host's own Pal, by the player who owns it.
            -- toggleAutoLock reads the current state here, where it is true.
            return Evolution.toggleAutoLock(senderCtx)
        end
        -- The fusion modules answer the player themselves, so a refusal is only
        -- logged here; passing it on would put the same line in the chat twice.
        if opcode == NetChannel.OP_FUSE_PICK then
            -- held for the altar request that follows it
            fusePicks[fusePickKey(senderCtx)] = { mask = pairIndex, at = os.clock() }
            Log(string.format("Fusion pick received (mask %d)", pairIndex))
            return true
        end
        if opcode == NetChannel.OP_FUSE_BATTLE or opcode == NetChannel.OP_FUSE_ALTAR then
            local ok, msg
            if opcode == NetChannel.OP_FUSE_BATTLE then
                local Fusion = package.loaded["fusion"]
                if not Fusion then return false, "fusion is not loaded" end
                ok, msg = Fusion.startBattle(senderCtx, pairIndex - 1)
            else
                local Altar = package.loaded["altar"]
                if not Altar then return false, "the fusion altar is not loaded" end
                local choice = nil
                if pairIndex == 2 or pairIndex == 3 then
                    choice = { gender = pairIndex - 1, passiveIndexes = {} }
                    local key = fusePickKey(senderCtx)
                    local pick = fusePicks[key]
                    fusePicks[key] = nil
                    if pick and os.clock() - pick.at < 30 then
                        for i = 1, 8 do
                            if pick.mask & (1 << (i - 1)) ~= 0 then
                                choice.passiveIndexes[#choice.passiveIndexes + 1] = i
                            end
                        end
                    elseif pick then
                        Log("[WARN] fusion pick expired, the altar keeps no passives from it")
                    end
                end
                ok, msg = Altar.start(senderCtx, choice, { allowCage = Config.devMode })
            end
            if not ok then Log("Fusion request refused: " .. tostring(msg or "no reason given")) end
            return true
        end
        return EvoAuto.handleEvolveByIndex(senderCtx, pairIndex)
    end)

    -- client side of the net channel: the host drives the presentation with
    -- phase signals (start/ready/reveal) which we play locally (no local
    -- player = no-op, so this is harmless on a dedicated server)
    NetChannel.initClient(function(kind, phaseInfo)
        Evolution.onNetSignal(kind, phaseInfo)
    end, ServerCheck.onPong)

    -- keybinds are player input - meaningless on a dedicated server
    local confirmKeyBound = false
    if not Role.isDedicated() and Config.confirmKeyEnabled ~= false then
        -- config.lua only lets confirmKey through as one of a fixed list, so a
        -- miss here means UE4SS spells that name differently or offers no key
        -- table at all. Binding nil takes the whole registration down, and with
        -- it everything after it in this function.
        local keyCode = Key and Key[Config.confirmKey]
        if keyCode == nil then
            Log("confirmKey '" .. tostring(Config.confirmKey) .. "' is unknown to UE4SS - no key bound")
        else
            confirmKeyBound = true
            local lastPress = 0
            RegisterKeyBind(keyCode, function()
                local now = os.clock()
                if (now - lastPress) < Config.debounceSeconds then return end
                lastPress = now
                ExecuteInGameThread(function()
                    local ok, err = pcall(Evolution.check)
                    if not ok then Log("check FAIL: " .. tostring(err)) end
                end)
            end)
        end
    end

    -- Level-up notification: fires ONCE per individual and target once the
    -- threshold is reached.
    -- The hook may ONLY be registered once the player pawn exists: the 1.0
    -- title screen already loads BP_MonsterBase_C (menu pals), and a script
    -- hook attached before/while a world loads lives through the actor
    -- restore storm, which aborts the whole process inside UE4SS.
    -- The pawn alone is not enough: when joining a server it spawns while
    -- actors are still streaming in, so require it to survive two polls
    -- (5 s apart) before attaching the hook.
    local notified = {}
    local hookRegistered = false
    local stablePolls = 0
    local function tryHook()
        if hookRegistered then return true end
        local player = FindFirstOf("PalPlayerCharacter")
        if not (player and player:IsValid()) then
            stablePolls = 0
            return false
        end
        stablePolls = stablePolls + 1
        if stablePolls < 2 then return false end
        local ok = pcall(RegisterHook,
            "/Game/Pal/Blueprint/Character/Monster/BP_MonsterBase.BP_MonsterBase_C:OnUpdateLevelDelegate_イベント_0",
            function(self, addLevel, nowLevel)
                pcall(function()
                    -- no player pawn = a world is loading or being torn down;
                    -- never touch game state from the load path
                    local pc = FindFirstOf("PalPlayerCharacter")
                    if not (pc and pc:IsValid()) then return end
                    -- Before the actor is touched, not after. Without a uid
                    -- isOwnedBy falls through to the any-owner check, which
                    -- matches every owned pal in the world: on a listen host
                    -- that turns a private notification into one about somebody
                    -- else's pal, and it reads the actor to find that out.
                    local localCtx = Role.localPlayerCtx()
                    if not (localCtx and localCtx.playerUId) then return end
                    local actor = self:get()
                    local param = actor.CharacterParameterComponent:GetIndividualParameter()
                    -- the notification is local UX: only this machine's
                    -- player should hear about their own pals
                    if not EvoUtil.isOwnedBy(param, localCtx.playerUId) then return end
                    local id, isAlpha = EvoUtil.baseCharacterId(param:GetCharacterID():ToString())
                    local pair = nil
                    for _, cand in ipairs(Config.findPairs(id)) do
                        if not EvoUtil.unknownConditionReason(cand)
                            and not (isAlpha and not EvoUtil.swapTargetId(cand, true)) then
                            pair = cand
                            break
                        end
                    end
                    if not pair then return end
                    -- nowLevel is the level BEFORE the addition
                    local newLevel = nowLevel:get() + addLevel:get()
                    if newLevel >= pair.minLevel then
                        -- key includes the target so the next chain stage
                        -- (e.g. MopKing->Yeti) notifies again after evolving
                        local key = EvoUtil.individualKey(param) .. ">" .. pair.to
                        if notified[key] then return end
                        notified[key] = true
                        EvoPresent.playFanfare(actor)
                        -- conditions are transient, so the reached-level hint
                        -- still fires and lists the remaining conditions
                        local condHint = ""
                        local conds = Conditions.describe(pair, Config.conditionDisclosure)
                        if conds then condHint = I18n.msg("whenSuffix", conds) end
                        Log(I18n.msg("reachedLevel",
                            EvoNames.palDisplayName(id), newLevel, EvoNames.palDisplayName(pair.to), condHint,
                            Config.confirmKey))
                    end
                end)
            end)
        hookRegistered = ok
        return ok
    end
    -- The notification is client-side UX (fanfare + on-screen hint); on a
    -- dedicated server the poll would run forever (no local player pawn ever
    -- exists), so it must not run there.
    if not Role.isDedicated() then
        if not tryHook() then
            -- tryHook returns true once the hook is in, which ends the loop
            GameLoop.start(5000, tryHook, "level-up hook")
        end
    end

    -- Console: "palvolve check|rollback|radial"
    pcall(function()
        RegisterConsoleCommandHandler("palvolve", function(fullCommand, parameters)
            local sub = parameters[1] or "check"
            ExecuteInGameThread(function()
                local ok, err = pcall(function()
                    if sub == "rollback" then
                        Evolution.rollbackLast(Role.localPlayerCtx())
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

    -- A prestiged pal shimmers, permanently. Registered here with the other
    -- native hooks, not on a timer.
    local okMark, errMark = pcall(function()
        require("prestigemark").init()
    end)
    if not okMark then Log("prestige marker failed to load: " .. tostring(errMark)) end

    -- chat commands: the retail build ships without an in-game console
    pcall(function()
        local ChatCommands = require("chatcommands")
        local okCmd = ChatCommands.init({
            rollback = function(senderCtx) Evolution.rollbackLast(senderCtx) end,
            -- The player's veto on the summoned Pal. Also sits in the wheel;
            -- this is the one that lets somebody lock several Pals quickly.
            lock = function(senderCtx) Evolution.runAutoLockCommand(senderCtx, true) end,
            unlock = function(senderCtx) Evolution.runAutoLockCommand(senderCtx, false) end,
            -- Same path the wheel takes, so it grants nothing the wheel would
            -- not. It only saves the trip through the menu while the
            -- presentation is being tuned.
            prestige = function(senderCtx, args) Evolution.runPrestigeCommand(senderCtx, args) end,
            -- swaps the permanent prestige shimmer without a restart
            glow = function(senderCtx, args) Evolution.runGlowCommand(senderCtx, args) end,
            -- dev-only aliases for probe keys that compact keyboards lack
            -- (END/INSERT); silent no-ops outside devMode
            free = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if okProbes and probes.toggleFreeMode then probes.toggleFreeMode() end
            end,
            kit = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if okProbes and probes.giveTestKit then probes.giveTestKit() end
            end,
            fx = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if okProbes and probes.playFinaleSample then probes.playFinaleSample() end
            end,
            xcond = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if okProbes and probes.worldProbe then probes.worldProbe() end
                Role.ack(senderCtx, "condition probe done - see log")
            end,
            -- evaluates the player and boss conditions for the sender's summoned
            -- Pal where the authority checks them, so a server answers for a
            -- remote player exactly as an evolve request would
            xcheck = function(senderCtx)
                if not Config.devMode then return end
                local holder = EvoUtil.findHolderFor(senderCtx, nil)
                local actor = nil
                if holder then
                    local okSpawned, spawned = pcall(function() return holder:TryGetSpawnedOtomo() end)
                    if okSpawned then actor = spawned else Log("[WARN] xcheck: summoned Pal unreadable: " .. tostring(spawned)) end
                end
                local param = actor and actor:IsValid() and EvoUtil.paramOf(actor) or nil
                if not param and holder then
                    -- no Pal out: the first party Pal still answers every
                    -- condition that does not need the Pal's actor
                    local okParam, first = pcall(function()
                        return holder:GetOtomoIndividualHandle(0):TryGetIndividualParameter()
                    end)
                    if okParam then param = first else Log("[WARN] xcheck: party Pal unreadable: " .. tostring(first)) end
                end
                if not (param and param:IsValid()) then
                    Role.ack(senderCtx, "xcheck: no Pal in the party")
                    return
                end
                local ctx = { actor = actor, param = param, playerCtx = senderCtx, holder = holder }
                local parts = {}
                for _, id in ipairs({ "isAlpha", "palLevel:1", "playerLevel:1", "playerHp:50", "playerHungry",
                    "playerBurning", "faintedAgo:1", "workRank:Mining:1", "defeatedTower:GrassBoss",
                    "defeatedAlpha:GrassMammoth", "alphasDefeated:1" }) do
                    local met = Conditions.evaluate({ conditions = { id } }, ctx)
                    table.insert(parts, id .. "=" .. tostring(met))
                end
                local line = "xcheck " .. table.concat(parts, " ")
                Log(line)
                Role.ack(senderCtx, line)
            end,
            -- writes an add-rank on the summoned pal and reports whether the
            -- getters the Team and Palbox screens read move with it. Run right
            -- after an evolution.
            worksuit = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeWorkSuitability) then return end
                probes.probeWorkSuitability()
                Role.ack(senderCtx, "work suitability probe done - see log")
            end,
            -- 1.9.0 planning probes. Each answers one question the plan
            -- cannot settle from static data; the abort criteria are in
            -- Workspace/docs/Palvolve/RELEASE-1.9.0.md. xaddpassive and
            -- xaddwaza CHANGE the summoned pal and do not undo it.
            xlevel = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeLevelWrite) then return end
                probes.probeLevelWrite()
                Role.ack(senderCtx, "P4 level write probe done - see log")
            end,
            xrank = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeSoulRanks) then return end
                probes.probeSoulRanks()
                Role.ack(senderCtx, "P5 soul rank probe done - see log")
            end,
            xpassive = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probePassiveRead) then return end
                probes.probePassiveRead()
                Role.ack(senderCtx, "P6 passive read probe done - see log")
            end,
            xaddpassive = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeAddPassive) then return end
                probes.probeAddPassive()
                Role.ack(senderCtx, "P2 add-passive probe done - check the pal status screen")
            end,
            xaddwaza = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeAddWaza) then return end
                probes.probeAddWaza()
                Role.ack(senderCtx, "P3 add-waza probe done - check the pal status screen")
            end,
            xarraygrow = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeArrayGrow) then return end
                probes.probeArrayGrow()
                Role.ack(senderCtx, "P8 direct array append probe done - see log")
            end,
            xschema = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeSchemaPassive) then return end
                probes.probeSchemaPassive()
                Role.ack(senderCtx, "P7 part 1 done - recall and re-summon, then !palvolve xschemacheck")
            end,
            xschemacheck = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeSchemaPassiveCheck) then return end
                probes.probeSchemaPassiveCheck()
                Role.ack(senderCtx, "P7 part 2 done - see log")
            end,
            xschemaclear = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeSchemaPassiveClear) then return end
                probes.probeSchemaPassiveClear()
                Role.ack(senderCtx, "test passive removed")
            end,
            xcontrol = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeVanillaControl) then return end
                probes.probeVanillaControl()
                Role.ack(senderCtx, "control part 1 - recall, re-summon, then !palvolve xcontrolcheck")
            end,
            xcontrolcheck = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeVanillaControlCheck) then return end
                probes.probeVanillaControlCheck()
                Role.ack(senderCtx, "control part 2 done - see log")
            end,
            xall = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeRunAll) then return end
                probes.probeRunAll()
                Role.ack(senderCtx, "batch done - recall, re-summon, then !palvolve xallcheck")
            end,
            xallcheck = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeRunAllCheck) then return end
                probes.probeRunAllCheck()
                Role.ack(senderCtx, "batch check done - see log")
            end,
            xladders = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeLadders) then return end
                probes.probeLadders()
                Role.ack(senderCtx, "ladders staged - recall, re-summon, then !palvolve xladderscheck")
            end,
            xladderscheck = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeLaddersCheck) then return end
                probes.probeLaddersCheck()
                Role.ack(senderCtx, "ladder check done - see log")
            end,
            -- one command per set: the chat dispatcher hands the handler a
            -- sender and nothing else, so the choice cannot ride in an argument
            bands = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeBands) then return end
                probes.probeBands("prestige")
                Role.ack(senderCtx, "prestige bands - recall, re-summon, open the status screen")
            end,
            bandsev = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeBands) then return end
                probes.probeBands("evolved")
                Role.ack(senderCtx, "evolved bands - recall, re-summon, open the status screen")
            end,
            bandsmix = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeBands) then return end
                probes.probeBands("mixed")
                Role.ack(senderCtx, "mixed bands - recall, re-summon, open the status screen")
            end,
            looks = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeBands) then return end
                probes.probeBands("looks")
                Role.ack(senderCtx, "look probe - recall, re-summon, open the status screen")
            end,
            bandsoff = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeBandsOff) then return end
                probes.probeBandsOff()
                Role.ack(senderCtx, "pal restored")
            end,
            xeat = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeEatHook) then return end
                probes.probeEatHook()
                Role.ack(senderCtx, "P1 eat hooks armed - feed a summoned pal, then a worker")
            end,
            -- 1.6.0 abort test: can a mod put a window on the game's own UI
            -- stack. Run it twice - the first call opens, the second closes.
            browser = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeBrowserWindow) then return end
                probes.probeBrowserWindow()
                Role.ack(senderCtx, "browser window probe - see log")
            end,
            -- The evolution tree window. Arrow keys walk it while it is open;
            -- clicking a Pal comes once a UMG button delegate is proven to
            -- reach Lua, and the keys work either way.
            -- Can a click leave the browser without JavaScript? A plain anchor
            -- is followed by CEF itself, and the address is readable from Lua.
            -- If it works, the whole window can be the HTML we already designed.
            link = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeLinkClick) then return end
                probes.probeLinkClick()
                Role.ack(senderCtx, "link probe - click a link, see the log")
            end,
            treeview = function(senderCtx)
                local okView, view = pcall(require, "treeview")
                if not (okView and view) then
                    Role.ack(senderCtx, "tree view failed to load")
                    return
                end
                view.open()
                Role.ack(senderCtx, view.isOpen()
                    and "tree open - arrow keys to move, ESC or !palvolve tree to close"
                    or "tree could not open, see the log")
            end,
            -- Decides what the in-game tree costs to build: whether Lua can
            -- put widgets on a canvas at coordinates it picks. If it can, a pak
            -- only has to supply an empty shell and the nodes stay in Lua.
            canvas = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeCanvas) then return end
                probes.probeCanvas()
                Role.ack(senderCtx, "canvas probe - see log")
            end,
            -- Puts a third tab into the game's own Paldex and reports what the
            -- tabset makes of it. Arm it in the world, then open the Paldex.
            paldex = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probePaldex) then return end
                probes.probePaldex()
                Role.ack(senderCtx, "paldex probe armed - open the Paldex")
            end,
            -- The authored widgets from the pak: do they mount, and does a
            -- click on one come back to Lua as a plain property read.
            pak = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probePak) then return end
                probes.probePak()
                Role.ack(senderCtx, "pak probe - click a card, see the log")
            end,
            -- The tree drawn as a web page in our own browser widget: the same
            -- layout and the same icons as the website.
            web = function(senderCtx)
                if not Config.devMode then return end
                local okTree, tree = pcall(require, "paldextree")
                if not (okTree and tree.toggleTreeWindow) then return end
                tree.toggleTreeWindow(false)
                Role.ack(senderCtx, "tree page - click a Pal, !palvolve web closes")
            end,
            -- Does the engine's web browser widget work in this build. If it
            -- does, the website's own tree view can be the in-game browser.
            webview = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeWebBrowser) then return end
                probes.probeWebBrowser()
                Role.ack(senderCtx, "webview probe - see log")
            end,
            -- The positive control for the same question: drive one of the
            -- game's own stack screens and see whether it appears.
            browserstack = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeBrowserStack) then return end
                probes.probeBrowserStack()
                Role.ack(senderCtx, "browser stack probe - see log")
            end,
            -- measures the host-to-client payload ceiling; run from a client
            xnet = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeNetPayload) then return end
                probes.probeNetPayload(senderCtx)
            end,
            -- Which tree is this world running. Answers the support question
            -- "are we even playing by the same rules" in one line, and it is
            -- the same identity a host and a client would compare.
            tree = function(senderCtx)
                local hash, n = Config.treeHash()
                local origin = "custom"
                if not Config.builtinMap then
                    origin = "built-in"
                elseif hash == Config.treeHash(Config.builtinMap) then
                    origin = "built-in"
                end
                Role.ack(senderCtx, string.format("[Palvolve] tree %s / %d pairs / %s",
                    hash, n, origin))
            end,
            -- dumps the sky plugin's weather presets, which carry the rain, snow,
            -- fog and lightning values of every weather state. Needs a loaded
            -- world: at the main menu only a stub preset exists.
            wpreset = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.dumpWeatherPresets) then return end
                local n = probes.dumpWeatherPresets() or 0
                Role.ack(senderCtx, string.format("%d weather presets read - see log", n))
            end,
            -- cycles the world clock speed for the weather recording session
            fast = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.cycleTimeScale) then return end
                -- chat handlers run on the game thread, like the other probe
                -- commands here, so the call is direct and the result usable
                local rate = probes.cycleTimeScale()
                Role.ack(senderCtx, rate and string.format("world clock at %.0fx", rate)
                    or "time scale unchanged - see log")
            end,
            -- uninstall probe set (devMode): count leftovers, sweep the own
            -- inventory, inspect the tech unlock array, neutralize the entry.
            -- Read (xtech) and write (xtechw) are separate so the array can be
            -- inspected before anything is written to it.
            xcount = function(senderCtx)
                if not Config.devMode then return end
                local okU, U = pcall(require, "uninstall")
                if not okU then return end
                local total, found = U.countReport(senderCtx)
                Role.ack(senderCtx, total == 0 and "Palvolve items in inventory: none"
                    or ("Palvolve items: " .. table.concat(found, ", ")))
            end,
            xsweep = function(senderCtx)
                if not Config.devMode then return end
                local okU, U = pcall(require, "uninstall")
                if not okU then return end
                local removed, failed = U.sweepInventory(senderCtx)
                local msg = #removed == 0 and "nothing to remove"
                    or ("removed: " .. table.concat(removed, ", "))
                if #failed > 0 then msg = msg .. " / FAILED: " .. table.concat(failed, ", ") end
                Role.ack(senderCtx, msg)
            end,
            -- record-map probe: can Lua read (and natively remove from) the
            -- player statistics TMaps that retain crafted mod-item names?
            xrec = function(senderCtx)
                if not Config.devMode then return end
                pcall(function()
                    local rds = FindAllOf("PalPlayerRecordData") or {}
                    Log(string.format("[xrec] PalPlayerRecordData instances=%d", #rds))
                    for ri, rd in ipairs(rds) do
                        local valid = false
                        pcall(function() valid = rd:IsValid() end)
                        Log(string.format("[xrec] rd%d valid=%s", ri, tostring(valid)))
                        if valid then
                            for _, spec in ipairs({
                                { field = "CraftItemCount", inner = "countMap" },
                                { field = "ItemPickupObtainForInstanceFlag", inner = "flagMap" },
                            }) do
                                local okF, errF = pcall(function()
                                    local wrap = rd[spec.field]
                                    Log(string.format("[xrec] rd%d %s wrapType=%s", ri, spec.field, type(wrap)))
                                    local map = wrap and wrap[spec.inner]
                                    Log(string.format("[xrec] rd%d %s.%s mapType=%s", ri, spec.field, spec.inner, type(map)))
                                    if not map then return end
                                    local n, hits = 0, 0
                                    local okFE, errFE = pcall(function()
                                        map:ForEach(function(k, v)
                                            n = n + 1
                                            local ks = "?"
                                            pcall(function() ks = k:get():ToString() end)
                                            if type(ks) ~= "string" then pcall(function() ks = tostring(k) end) end
                                            local vs = "?"
                                            pcall(function() vs = tostring(v.get and v:get() or v) end)
                                            if tostring(ks):find("Palvolve") then hits = hits + 1 end
                                            if tostring(ks):find("Palvolve") or n <= 3 then
                                                Log(string.format("[xrec] rd%d %s [%d] %s = %s", ri, spec.field, n, tostring(ks), vs))
                                            end
                                        end)
                                    end)
                                    Log(string.format("[xrec] rd%d %s entries=%d palvolveKeys=%d forEachOk=%s err=%s",
                                        ri, spec.field, n, hits, tostring(okFE), tostring(errFE)))
                                end)
                                if not okF then
                                    Log(string.format("[xrec] rd%d %s FIELD ERROR: %s", ri, spec.field, tostring(errF)))
                                end
                            end
                        end
                    end
                end)
                Role.ack(senderCtx, "record probe done - see log")
            end,
            -- offer-chain diagnosis: runs every canOffer step for the summoned
            -- pal WITHOUT the swallowing pcall and logs each verdict, plus the
            -- pair list with categories - pinpoints why the radial entry greys
            xoffer = function(senderCtx)
                if not Config.devMode then return end
                local out = {}
                local function step(name, v) table.insert(out, name .. "=" .. tostring(v)); return v end
                local okAll, errAll = pcall(function()
                    step("blocked", ServerCheck.blocked())
                    -- on a dedicated server there is no local player: diagnose
                    -- the SENDING player's chain instead (the server-side view
                    -- that validates evolve requests)
                    local playerCtx = Role.localPlayerCtx() or senderCtx
                    step("playerCtx", playerCtx ~= nil)
                    local holder = EvoUtil.findHolderFor(playerCtx, nil)
                    if not step("holder", holder ~= nil) then return end
                    local actor = nil
                    pcall(function() actor = holder:TryGetSpawnedOtomo() end)
                    if not step("actor", actor and actor:IsValid() or false) then return end
                    local param = EvoUtil.paramOf(actor)
                    if not step("param", param ~= nil) then return end
                    step("owned", EvoUtil.isOwnedBy(param, playerCtx and playerCtx.playerUId))
                    -- raw on purpose: this line exists to show the spelling
                    -- the session reported next to the one the mod resolved
                    local raw = param:GetCharacterID():ToString()
                    local id, isAlpha = EvoUtil.baseCharacterId(raw)
                    table.insert(out, string.format("raw='%s' id='%s' alpha=%s", raw, id, tostring(isAlpha)))
                    local pairs_ = Config.findPairs(id)
                    table.insert(out, "findPairs=" .. #pairs_)
                    for i, p in ipairs(pairs_) do
                        table.insert(out, string.format("  [%d] ->%s cat=%s stone=%s lvl=%d en=%s",
                            i, p.to, tostring(p.category), tostring(p.stone), p.minLevel or -1, tostring(p.enabled)))
                    end
                    local canOk, canRes = pcall(Evolution.canOffer)
                    table.insert(out, string.format("canOffer pcallOk=%s result=%s", tostring(canOk), tostring(canRes)))
                end)
                if not okAll then table.insert(out, "CHAIN ERROR: " .. tostring(errAll)) end
                for _, l in ipairs(out) do Log("[xoffer] " .. l) end
                Role.ack(senderCtx, "offer probe done - see log (" .. #out .. " lines)")
            end,
            xtech = function(senderCtx)
                if not Config.devMode then return end
                local okU, U = pcall(require, "uninstall")
                if okU then Role.ack(senderCtx, U.techInspect(senderCtx)) end
            end,
            xtechw = function(senderCtx)
                if not Config.devMode then return end
                local okU, U = pcall(require, "uninstall")
                if not okU then return end
                local _, msg = U.techNeutralize(senderCtx)
                Role.ack(senderCtx, msg)
            end,
            -- Clean-removal assistant: sweeps the caller's inventory for real
            -- (discard only drops items, and drops persist in the save),
            -- scans EVERY world container so nobody has to search chests by
            -- hand, lists placed benches, neutralizes the tech unlock, and
            -- only reports "safe to uninstall" when the world is clean.
            uninstall = function(senderCtx)
                -- every line goes to the chat AND the UE4SS log: chat lines can
                -- scroll away or throttle, and support diagnosis needs the log
                local function say(msg)
                    Log("[uninstall] " .. msg)
                    Role.ack(senderCtx, msg)
                end
                if not Role.hasWorldAuthority() then
                    say(I18n.msg("uninstAuthorityOnly"))
                    return
                end
                local okU, U = pcall(require, "uninstall")
                if not okU then
                    say(I18n.msg("uninstUnavailable"))
                    return
                end
                local removed = select(1, U.sweepInventory(senderCtx))
                if #removed > 0 then
                    say(I18n.msg("uninstDeleted", table.concat(removed, ", ")))
                end
                local techOk, techMsg = U.techNeutralize(senderCtx)
                say(I18n.msg("uninstTech", techMsg))
                local locations, _, orphans = U.worldScan(senderCtx)
                local benches = U.findBenches()
                local altars = U.findAltars()
                for i, line in ipairs(locations) do
                    if i > 6 then
                        say(I18n.msg("uninstMore", #locations - 6))
                        break
                    end
                    say(line)
                end
                for _, pos in ipairs(benches) do
                    say(I18n.msg("uninstBench", pos))
                end
                for _, pos in ipairs(altars) do
                    say(I18n.msg("uninstAltar", pos))
                end
                -- Honesty over promises: the player statistics keep crafted and
                -- picked-up mod item names, live only as replicated FastArrays
                -- no Lua can touch. A world that ever USED the mod therefore
                -- stays dependent on the PalSchema data folder - the command
                -- cleans everything reachable and says exactly that.
                if #locations == 0 and #benches == 0 and #altars == 0 and techOk then
                    say(I18n.msg("uninstClean"))
                    say(I18n.msg("uninstKeepFolder"))
                else
                    say(I18n.msg("uninstNotClean") ..
                        (#orphans > 0 and (" " .. I18n.msg("uninstOrphanHint")) or ""))
                end
            end,
            -- One line per command. The chat DROPS a line past roughly a
            -- hundred characters instead of truncating it, and one combined
            -- line runs past that in most languages - the message is then
            -- never seen although the log shows it being sent.
            help = function(senderCtx)
                Role.ack(senderCtx, I18n.msg("helpRollback"))
                Role.ack(senderCtx, I18n.msg("helpUninstall"))
            end,
        })
        if okCmd then Log("Chat commands active: !palvolve rollback, !palvolve lock, !palvolve unlock") end
    end)

    -- The banner has to say what is actually bound: the key is off unless the
    -- player asks for it, and a log that promises F2 sends the next support
    -- case chasing a key that was never claimed.
    if not confirmKeyBound then
        Log("Evolution core active: wheel (hold 4), chat: !palvolve rollback")
    else
        Log(string.format("Evolution core active: %s = check/confirm, chat: !palvolve rollback",
            Config.confirmKey))
    end
end

-- What fusion.lua shares with the evolution path. A fusion in a fight is the
-- same despawn, swap and respawn with a different rewrite in the middle, so it
-- runs through performEvolution rather than a copy of it; these are the pieces
-- a request has to resolve before it gets there.
Evolution.fusionApi = {
    run = function(p) return performEvolution(p) end,
    busy = function() return EvoLock.lockBusy() end,
    findHolder = function(playerCtx) return EvoUtil.findHolderFor(playerCtx, nil) end,
    paramOf = EvoUtil.paramOf,
    isOwnedBy = EvoUtil.isOwnedBy,
    baseCharacterId = EvoUtil.baseCharacterId,
    individualKey = EvoUtil.individualKey,
    characterId = function(param) return EvoUtil.characterIdUnsafe(param) end,
    hasAuthority = function(pc) return EvoUtil.controllerHasAuthority(pc) end,
    displayName = EvoNames.palDisplayName,
    --- The Alpha id of a species, or nil when the game has no Alpha row for it.
    alphaTargetId = EvoUtil.alphaTargetId,
    --- The transform-safe freeze the MP reveal uses: movement tick, AI and
    --- queued actions stop, the transform stays writable from Lua.
    freeze = function(actor, frozen) EvoPresent.setRevealFrozen(actor, frozen) end,
    --- Writes the species to both save halves and reads it back.
    --- Returns nil on success, or the reason it did not land.
    writeSpecies = function(param, id)
        local okWrite, writeErr = pcall(EvoState.writeSpeciesUnsafe, param, id)
        if not okWrite then return "species write failed: " .. tostring(writeErr) end
        local okRead, now = pcall(EvoUtil.characterIdUnsafe, param)
        if not okRead then return "species read-back failed: " .. tostring(now) end
        if Config.canonicalId(now) ~= Config.canonicalId(id) then
            return string.format("species read back as %s, expected %s", tostring(now), tostring(id))
        end
        return nil
    end,
}

return Evolution
