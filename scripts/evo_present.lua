-- Palvolve evolution presentation and the work around it: fanfare, freezing the
-- Pal during the reveal, the party HUD, IV bonus, work suitability refresh, the
-- catch-gated technology unlock and the resummon after a rollback.

local Config = require("config")
local GameLoop = require("gameloop")
local I18n = require("i18n")
local Role = require("role")
local Sound = require("sound")
local EvoUtil = require("evo_util")

local EvoPresent = {}

local MOD_NAME = "Palvolve"
local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- Catch-gated technologies (saddles, Pal gear) unlock when a species is CAPTURED, not when
-- its CharacterID changes - so an evolved form stays locked. The capture record lives in
-- replicated FastArrays that UE4SS-Lua cannot map; the native companion (dlls/main.dll)
-- sets it through the game's own _ForServer setters. See
-- Workspace/docs/Palvolve/KNOWN-ISSUE-catch-tech-unlock.md.
EvoPresent.nativeMissingLogged = false
-- Keyed by player, not a single flag: on a dedicated server one shared flag would let the
-- first player to hit a failure consume the notice for everyone else.
local techUnlockNoticeSent = {}
local function unlockCatchTech(targetId, playerCtx)
    if not Config.unlockCatchTech then return end

    -- Without the companion the evolution itself is unaffected: skip quietly, note it once.
    if type(PalvolveNative_UnlockCaptureRecord) ~= "function" then
        if not EvoPresent.nativeMissingLogged then
            EvoPresent.nativeMissingLogged = true
            Log("Native companion missing - catch-gated technologies stay locked for this session")
        end
        return
    end

    local uid = ""
    pcall(function()
        if playerCtx and not EvoUtil.isZeroGuid(playerCtx.playerUId) then
            uid = EvoUtil.guidString(playerCtx.playerUId)
        end
    end)

    -- Naming the PlayerState lets the native side read the uid off the authority's own object
    -- rather than trust the replicated value this process happened to see. Both are passed:
    -- the native side prefers the state and falls back to the uid.
    local stateName = ""
    pcall(function()
        local ps = playerCtx and playerCtx.playerState
        if ps and ps:IsValid() then stateName = ps:GetFName():ToString() end
    end)

    local called, ok, msg = pcall(PalvolveNative_UnlockCaptureRecord, targetId, uid, stateName)
    if not called then
        Log(string.format("Catch-tech unlock errored for %s: %s", tostring(targetId), tostring(ok)))
    elseif ok then
        Log(string.format("Catch-tech unlocked for %s (%s)", tostring(targetId), tostring(msg)))
    else
        Log(string.format("Catch-tech unlock skipped for %s: %s", tostring(targetId), tostring(msg)))
        -- Species that share a Palpedia slot with their base (Gumoss Botan) have no own
        -- EPalTribeID, so the game keeps no capture record for them and there are no
        -- catch-gated recipes to unlock. Nothing is wrong there, so the player is not asked
        -- to report it - unlike a missing enum, which breaks every species and does count
        -- as a failure. The native side distinguishes the two in its message.
        local noRecordSlot = type(msg) == "string"
            and msg:find("no EPalTribeID entry", 1, true) ~= nil
        -- The evolution itself worked, so a real failure costs the player one line per
        -- session; without it the failure only ever reaches the server log.
        local noticeKey = uid ~= "" and uid or "unresolved"
        if not noRecordSlot and not techUnlockNoticeSent[noticeKey] then
            techUnlockNoticeSent[noticeKey] = true
            pcall(function() Role.chat(playerCtx, I18n.msg("techUnlockFailed"), "reply") end)
        end
    end
end
-- Recalls and re-summons the Pal after a rollback so the model matches the
-- species again. The parameter change alone is invisible: the spawned actor
-- keeps the mesh it was built with, so without this the player has to recall
-- the pal by hand to see the result.
--
-- Only for the pal that is actually out, and only for a local player: a remote
-- client on a dedicated server drives its own presentation, and reaching into
-- its otomo lifecycle from the host is the sequence that belongs to the evolve
-- path, not here. Every step is optional - if anything fails the rollback has
-- still happened and the pal simply keeps its old model until recalled by hand.
local function resummonAfterRollback(playerCtx, param)
    -- Every exit logs its reason: the sequence has half a dozen ways to decline
    -- legitimately, and a silent decline reads exactly like a broken one.
    local function bail(reason)
        Log("Resummon skipped: " .. reason)
        return false
    end
    if not (playerCtx and playerCtx.pc and playerCtx.pc:IsValid()) then
        return bail("no player controller")
    end
    if playerCtx.isLocal == false then return bail("remote player, client drives its own otomo") end

    local holder = EvoUtil.findHolderFor(playerCtx, nil)
    if not (holder and holder:IsValid()) then return bail("no otomo holder") end
    local mgr = EvoUtil.findManager(playerCtx.pc)
    if not mgr then return bail("no character manager") end

    -- Party slot of an individual, via its handle. Both lookups return plain
    -- values (an object pointer and an int), so neither can hit the
    -- struct-by-value return that kills the process from Lua.
    local function slotOf(p)
        local slot = -1
        pcall(function()
            local handle = mgr:GetIndividualHandleFromCharacterParameter(p)
            slot = holder:GetSlotIndexByIndividualHandle(handle)
        end)
        if type(slot) ~= "number" then return -1 end
        return slot
    end

    local slot = slotOf(param)
    if slot < 0 then return bail("pal has no party slot") end

    -- Only act when this exact pal is the one that is out. Identified by slot
    -- index rather than by comparing the two parameter objects: those come back
    -- as separate Lua wrappers, and equality between them is the binding's
    -- business, not something this should depend on. Slots are integers.
    local spawned, spawnedSlot = nil, -1
    pcall(function() spawned = holder:TryGetSpawnedOtomo() end)
    if not (spawned and spawned:IsValid()) then return bail("no pal is out") end
    pcall(function()
        local sp = spawned.CharacterParameterComponent:GetIndividualParameter()
        if sp and sp:IsValid() then spawnedSlot = slotOf(sp) end
    end)
    if spawnedSlot < 0 or spawnedSlot ~= slot then
        return bail(string.format("a different pal is out (slot %d, rolled back %d)",
            spawnedSlot, slot))
    end

    local okOff, errOff = pcall(function() holder:InactivateCurrentOtomo() end)
    if not okOff then return bail("recall failed: " .. tostring(errOff)) end

    -- The recall needs a moment before the slot can be loaded again; a single
    -- delayed shot, not a poller, so nothing keeps ticking if it does not work.
    GameLoop.after(700, function()
        if not (holder and holder:IsValid()
            and playerCtx.pc and playerCtx.pc:IsValid()) then
            Log("Resummon skipped: player or holder gone before the reload")
            return
        end
        local ok, err = pcall(function()
            playerCtx.pc:SetOtomoSlot(slot)
            holder:SpawnOtomoByLoad(slot)
        end)
        if ok then
            Log(string.format("Resummoned slot %d after rollback", slot))
        else
            Log("Resummon failed: " .. tostring(err))
        end
    end, "resummon after rollback")
    return true
end
local function playFanfare(actor)
    Sound.onActor("/Game/Pal/Sound/Events/SE/UI/CampLevelUp/AKE_CampLevelUp.AKE_CampLevelUp", actor, false)
end
local function setFrozen(palActor, frozen)
    pcall(function()
        local ctrl = palActor:GetController()
        if ctrl and ctrl:IsValid() then ctrl:SetActiveAI(not frozen) end
    end)
    pcall(function()
        local util = EvoUtil.palUtility()
        if util then util:SetMoveDisableFlag(palActor, frozen, FName("PalvolveSeq")) end
    end)
end
-- Stronger, TRANSFORM-SAFE freeze for the MP reveal. The base/otomo AI would
-- otherwise drag the pal off (flee / base work) mid-animation. This suppresses
-- the movement component's TICK (harder than SetMoveDisableFlag - stops nav,
-- gravity, floor snap, facing-driven movement) plus AI + queued actions, while
-- NEVER writing the actor transform, so the client-driven reveal spin holds.
-- Call surface per the 1.0 object dump.
local REVEAL_FLAG = FName("PalvolveReveal")
-- The party panel keeps the name and element of the species it drew last; a
-- species swap does not tell it. Selecting the same slot again makes it read
-- the Pal anew. Only for the local player: the panel is local UI.
local function refreshPartyHud(holder)
    if not (holder and holder:IsValid()) then return end
    local ok, err = pcall(function() holder:SetSelectOtomoID(holder:GetSelectedOtomoID()) end)
    if not ok then Log("[WARN] party panel refresh failed: " .. tostring(err)) end
end
local function setRevealFrozen(actor, frozen)
    if not (actor and actor:IsValid()) then return end
    local ctrl, move = nil, nil
    pcall(function() ctrl = actor:GetController() end)
    pcall(function() move = actor.CharacterMovement end)
    if frozen then
        if move and move:IsValid() then
            pcall(function() move:SetMoveDisableFlag(REVEAL_FLAG, true) end)
            pcall(function() move:SetComponentTickSuppressFlag(REVEAL_FLAG, true) end)
            pcall(function() move:StopMovementImmediately() end)
        end
        if ctrl and ctrl:IsValid() then
            pcall(function() ctrl:SetActiveAI(false) end)
            pcall(function() ctrl:StopMovement() end)
        end
        pcall(function() actor.ActionComponent:CancelAllAction() end)
    else
        if move and move:IsValid() then
            pcall(function() move:SetComponentTickSuppressFlag(REVEAL_FLAG, false) end)
            pcall(function() move:SetMoveDisableFlag(REVEAL_FLAG, false) end)
        end
        if ctrl and ctrl:IsValid() then
            pcall(function() ctrl:SetActiveAI(true) end)
        end
    end
end
-- true when the pal's AI is still (or again) active - the re-assert guard
local function isAiActive(actor)
    local active = false
    pcall(function()
        local ctrl = actor:GetController()
        if ctrl and ctrl:IsValid() then active = ctrl:IsActiveAI() end
    end)
    return active
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
local TALENT_FIELDS = { "Talent_HP", "Talent_Melee", "Talent_Shot", "Talent_Defense" }
local function readTalents(param)
    local t = {}
    for _, field in ipairs(TALENT_FIELDS) do
        local v = -1
        local ok, err = pcall(function() v = param.SaveParameter[field] end)
        if not ok then Log("IV read for " .. field .. " failed: " .. tostring(err)) end
        t[field] = v
    end
    return t
end
local TALENT_LABELS = {
    Talent_HP = "HP", Talent_Shot = "Attack", Talent_Defense = "Defense",
}
-- The talents the game shows. Talent_Melee stays in TALENT_FIELDS so a rollback
-- restores it as it was, but raising it would change nothing the player sees.
local BONUS_TALENTS = { "Talent_HP", "Talent_Shot", "Talent_Defense" }
local function applyIvBonus(param)
    local parts = {}
    for _, field in ipairs(BONUS_TALENTS) do
        local ok = pcall(function()
            local cur = param.SaveParameter[field]
            local new = math.min(cur + Config.ivBonusPerStage, Config.ivCap)
            param.SaveParameter[field] = new
            param.SaveParameterMirror[field] = new
            table.insert(parts, string.format("%s +%d", TALENT_LABELS[field] or field, new - cur))
        end)
        if not ok then
            Log("IV bonus for " .. field .. " could not be applied - field unavailable on this build")
        end
    end
    if #parts > 0 then Log("Evolution bonus (IVs): " .. table.concat(parts, ", ")) end
end
EvoPresent.workNativeAnnounced = false
local function refreshWorkSuitability(param, playerCtx, actor, previousId)
    if type(PalvolveNative_SetWorkSuitability) ~= "function" then
        if not EvoPresent.workNativeAnnounced then
            EvoPresent.workNativeAnnounced = true
            Log("Work suitability: native companion missing - values update after a relog")
        end
        return
    end
    if not (param and param:IsValid()) then return end

    -- The parameter object goes over as-is. An earlier version sent a key built here, and
    -- individualKey falls back to GetFullName when the struct read fails - the native side
    -- then got a name where it expected an instance id and installed nothing at all.
    local called, ok, msg = pcall(PalvolveNative_SetWorkSuitability, param)
    if not called then
        Log("Work suitability: native call failed: " .. tostring(ok))
        return
    end
    if not ok then
        Log("Work suitability: " .. tostring(msg))
        return
    end
    -- the native side answers with the species it resolved, which is the one the getters
    -- will report from here on
    Log(string.format("Work suitability: now reading as %s", tostring(msg)))
    -- Both halves are covered from here: the reflected getters feed the UI, and a native
    -- inline hook answers the base camp, which reads the pal through a direct C++ call that
    -- never passes ProcessEvent. Details and the eight disproven routes: SUPPORT-CASES.md
    -- case 8 and CPP-MODDING.md section 8.3e.
end
-- Runs checkFn on the game thread every intervalMs until it returns true or
-- timeoutMs elapsed; calls doneFn(success) exactly once on the game thread.
local function pollUntil(intervalMs, timeoutMs, checkFn, doneFn)
    local elapsed = 0
    local finished = false
    GameLoop.start(intervalMs, function()
        if finished then return true end
        elapsed = elapsed + intervalMs
        local ok, res = pcall(checkFn)
        if ok and res then
            finished = true
            local okDone, errDone = pcall(doneFn, true)
            if not okDone then Log("pollUntil doneFn FAIL: " .. tostring(errDone)) end
        elseif elapsed >= timeoutMs then
            finished = true
            if not ok then Log("pollUntil checkFn FAIL: " .. tostring(res)) end
            local okDone, errDone = pcall(doneFn, false)
            if not okDone then Log("pollUntil doneFn FAIL: " .. tostring(errDone)) end
        end
        return finished
    end, "poll")
end
-- devMode telemetry: after a reveal, log for ~6s WHO moves the new actor where
-- (position, attach parent, movement mode, scale, height above the player)
local function startRevealDiagnostics(holderRef, label, playerCtx)
    if not Config.devMode then return end
    -- Opt-in on top of devMode. Each call leaves a loop running for 12s. As a LoopAsync with
    -- an ExecuteInGameThread nested inside it, two evolutions in quick succession overlapped
    -- two of them and the game died with "Ref was not function" - the callback GC trap from
    -- UE4SS-LESSONS.md. Off by default so repeated evolutions can be tested at all.
    if not Config.diagReveal then return end
    local ticks = 0
    local function diagStep()
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
            local pawn = playerCtx and playerCtx.pawn
            if pawn and pawn:IsValid() then dz = loc.Z - pawn:K2_GetActorLocation().Z end
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
    end
    GameLoop.start(500, function()
        ticks = ticks + 1
        if ticks > 24 then return true end
        local ok, err = pcall(diagStep)
        if not ok then Log(string.format("[diag %s t=%d] read failed: %s", label, ticks, tostring(err))) end
        return ticks > 24
    end, "reveal diagnostics")
end

EvoPresent.techUnlockNoticeSent = techUnlockNoticeSent
EvoPresent.unlockCatchTech = unlockCatchTech
EvoPresent.resummonAfterRollback = resummonAfterRollback
EvoPresent.playFanfare = playFanfare
EvoPresent.setFrozen = setFrozen
EvoPresent.REVEAL_FLAG = REVEAL_FLAG
EvoPresent.refreshPartyHud = refreshPartyHud
EvoPresent.setRevealFrozen = setRevealFrozen
EvoPresent.isAiActive = isAiActive
EvoPresent.completeOtomoActivation = completeOtomoActivation
EvoPresent.TALENT_FIELDS = TALENT_FIELDS
EvoPresent.readTalents = readTalents
EvoPresent.TALENT_LABELS = TALENT_LABELS
EvoPresent.BONUS_TALENTS = BONUS_TALENTS
EvoPresent.applyIvBonus = applyIvBonus
EvoPresent.refreshWorkSuitability = refreshWorkSuitability
EvoPresent.pollUntil = pollUntil
EvoPresent.startRevealDiagnostics = startRevealDiagnostics

return EvoPresent
