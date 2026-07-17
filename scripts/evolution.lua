-- Palvolve core: eligibility, two-stage confirm, transactional species swap,
-- snapshots/rollback, IV bonus and the staged evolution sequence.
-- Sequence design: direct manager teardown first (the holder recall animates
-- a mesh clone that ignores a hidden actor and is therefore only a fallback),
-- species swap while despawned, two-phase activation pump with a
-- species-id-checked respawn, staged reveal driven by the FX staging (fx.lua).

local Config = require("config")
local FX = require("fx")
local Costs = require("costs")
local Elements = require("elements")
local Conditions = require("conditions")
local I18n = require("i18n")
local Role = require("role")
local Authority = require("authority")
local NetChannel = require("netchannel")

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

-- Absolute per-species capsule half-height, from the pal's static parameter
-- component (filled from the pal database at spawn). Readable on a HEADLESS
-- dedicated server, unlike GetSimpleCollisionHalfHeight / GetScaledCapsuleHalfHeight
-- which return a small BP default (~30) until a loaded mesh resizes the capsule -
-- with no mesh on a server, a big target species therefore sank into the ground.
-- Returns nil when unavailable so callers can fall back.
local function staticCapsuleHalf(actor)
    local h = nil
    pcall(function()
        local spc = actor.StaticCharacterParameterComponent
        if spc and spc:IsValid() then
            local v = spc.MeshCapsuleHalfHeight
            if v and v > 0 then h = v end
        end
    end)
    return h
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

-- Strict ownership against a specific player: multiplayer requests may only
-- touch pals owned by the requesting player. Falls back to the any-owner
-- check when no uid is available (playerCtx without a PlayerState yet).
local function isOwnedBy(param, playerUId)
    if not playerUId then return isOwned(param) end
    local owned = false
    pcall(function()
        local g = param.SaveParameter.OwnerPlayerUId
        owned = (g.A == playerUId.A and g.B == playerUId.B
            and g.C == playerUId.C and g.D == playerUId.D)
            and (g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0)
        if not owned and Config.devMode then
            Log(string.format("[ownership] pal owner %08X-%08X-%08X-%08X vs requester %08X-%08X-%08X-%08X",
                g.A, g.B, g.C, g.D, playerUId.A, playerUId.B, playerUId.C, playerUId.D))
        end
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

-- Localized pal display name via the game's own text system (returns the
-- raw character id when the lookup fails). GetLocalizedText has a plain
-- return value, which works from Lua - unlike out-params in this build.
-- Used for radial labels AND every player-facing message, so the chat
-- reasons show "Pengullet Lux", never "Penguin_Electric".
local displayNameCache = {}
local function palDisplayName(id)
    local cached = displayNameCache[id]
    if cached then return cached end
    local name = nil
    pcall(function()
        local mdt = StaticFindObject("/Script/Pal.Default__PalMasterDataTablesUtility")
        local ctx = FindFirstOf("PalPlayerCharacter")
        if not (mdt and mdt:IsValid() and ctx and ctx:IsValid()) then return end
        -- EPalLocalizeTextCategory::PalMonsterName = 4
        local txt = mdt:GetLocalizedText(ctx, 4, FName("PAL_NAME_" .. id))
        if txt then
            local s = txt:ToString()
            if s and s ~= "" then name = s end
        end
    end)
    if Config.devMode then
        Log(string.format("[radial] name lookup %s -> %s", id, name or "FAIL"))
    end
    -- only successful lookups are cached so an early call (no world yet)
    -- retries later; the cache resets with the Lua state on restart
    if name then displayNameCache[id] = name end
    return name or id
end

-- Warms the submenu labels while the MAIN wheel is still open: the localized
-- name lookups cost ~30 ms each on first use, so doing them here means the
-- Evolve click later builds its options from the cache without delay.
-- The loop is bounded per species and ends after one pass over the list.
local warmedNames = {}
local function prewarmNames(id)
    if warmedNames[id] then return end
    warmedNames[id] = true
    local pairList = Config.findPairs(id)
    if #pairList == 0 then return end
    local i = 0
    LoopAsync(100, function()
        i = i + 1
        local pair = pairList[i]
        if not pair then return true end
        ExecuteInGameThread(function()
            pcall(function() palDisplayName(pair.to) end)
        end)
        return false
    end)
end

-- Otomo holder of a SPECIFIC player (never FindFirstOf: on a host with
-- connected clients that would return an arbitrary player's holder).
--
-- The holder is a component of the player's CONTROLLER (its GetOwner()
-- is the PalPlayerController). The generic
-- component getter resolves it from a stable controller reference and works
-- for a REMOTE client on a dedicated server - unlike
-- PalUtility:GetOtomoHolderComponent, which takes only a WorldContextObject
-- and resolves via the local player / world context (null for remote
-- clients). Dump: AActor:GetComponentByClass (objectdump ...:511-513),
-- PalOtomoHolderComponentBase class (...:52602).
local otomoHolderClass = nil
local function findHolderFor(playerCtx, actor)
    -- primary: component of the player's own controller
    local holder = nil
    pcall(function()
        local pc = playerCtx and playerCtx.pc
        if pc and pc:IsValid() then
            if not (otomoHolderClass and otomoHolderClass:IsValid()) then
                otomoHolderClass = StaticFindObject("/Script/Pal.PalOtomoHolderComponentBase")
            end
            if otomoHolderClass then
                local h = pc:GetComponentByClass(otomoHolderClass)
                if h and h:IsValid() then holder = h end
            end
        end
    end)
    if holder then return holder end
    -- fallbacks: by the summoned otomo, then the world-context util
    -- (the latter works for the local player on standalone/listen host)
    local util = palUtility()
    if not util then return nil end
    if actor then
        pcall(function()
            if actor:IsValid() then holder = util:GetOtomoHolderByOtomoPal(actor) end
        end)
        if holder and holder:IsValid() then return holder end
    end
    pcall(function()
        local pc = playerCtx and playerCtx.pc
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
                "  { key = %q, from = %q, to = %q, level = %d, nickname = %q, ivHP = %d, ivMelee = %d, ivShot = %d, ivDefense = %d, uid = %q },\n",
                s.key or "", s.from, s.to, s.level, s.nickname or "",
                s.ivHP or -1, s.ivMelee or -1, s.ivShot or -1, s.ivDefense or -1,
                s.uid or ""))
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

-- Stronger, TRANSFORM-SAFE freeze for the MP reveal. The base/otomo AI would
-- otherwise drag the pal off (flee / base work) mid-animation. This suppresses
-- the movement component's TICK (harder than SetMoveDisableFlag - stops nav,
-- gravity, floor snap, facing-driven movement) plus AI + queued actions, while
-- NEVER writing the actor transform, so the client-driven reveal spin holds.
-- Call surface per the 1.0 object dump.
local REVEAL_FLAG = FName("PalvolveReveal")
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
            Log("IV bonus for " .. field .. " could not be applied - field unavailable on this build")
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
local function startRevealDiagnostics(holderRef, label, playerCtx)
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
            end)
        end)
        return ticks > 24
    end)
end

-- ---------------------------------------------------------------- core sequence

-- pending = { armedAt, key, pair } - the armed confirm state; the confirm
-- press always fetches FRESH handles via findEligibleFor()
local pending = nil
-- the pair a connected client last requested over the net channel, so the
-- host's success ack can drive the local reveal (Evolution.playRemoteReveal)
local lastRemotePair = nil
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

-- Alpha pals keep a BOSS_ prefix on their CharacterID while the pair map
-- uses base ids: strip the prefix for matching and re-apply it on the swap
-- target so an Alpha stays an Alpha. Only species with a real BOSS_ row are
-- valid alpha targets - an id without a row cannot resolve its blueprint
-- class (spawn/summon failure risk). Lucky ("shiny") status lives in
-- SaveParameter.IsRarePal, which the in-place swap never touches.
local BOSS_PREFIX = "BOSS_"
local okBoss, BossSet = pcall(require, "boss_static")
if not okBoss then BossSet = nil end

local function baseCharacterId(rawId)
    if rawId:sub(1, #BOSS_PREFIX) == BOSS_PREFIX then
        return rawId:sub(#BOSS_PREFIX + 1), true
    end
    return rawId, false
end

-- swap target for an alpha; nil when the species has no BOSS_ row
local function alphaTargetId(baseTo)
    if BossSet and BossSet[baseTo] then return BOSS_PREFIX .. baseTo end
    return nil
end

local function swapTargetId(pair, isAlpha)
    if not isAlpha then return pair.to end
    return alphaTargetId(pair.to)
end

-- Only one own pal can be summoned at a time, so the otomo holder is the
-- authoritative source (a FindAllOf scan would also hit ghost actors).
local function findEligibleFor(playerCtx)
    local holder = findHolderFor(playerCtx, nil)
    if not holder then return nil end
    local actor = nil
    pcall(function() actor = holder:TryGetSpawnedOtomo() end)
    if not (actor and actor:IsValid()) then return nil end
    local param = paramOf(actor)
    if not (param and isOwnedBy(param, playerCtx and playerCtx.playerUId)) then return nil end
    local id, isAlpha = baseCharacterId(param:GetCharacterID():ToString())
    -- pick the first pair that passes EVERY gate (alpha form, level,
    -- conditions), so a branched species whose first target is blocked
    -- still reaches its other options
    local pairList = Config.findPairs(id)
    if not pairList or #pairList == 0 then
        return nil, I18n.msg("hasNoEvolution", palDisplayName(id))
    end
    local level = 0
    pcall(function() level = param:GetLevel() end)
    local condCtx = { actor = actor, param = param, playerCtx = playerCtx, holder = holder }
    local pair, pairIndex, firstReason, alphaBlockedTo = nil, nil, nil, nil
    for i, cand in ipairs(pairList) do
        if isAlpha and not swapTargetId(cand, true) then
            alphaBlockedTo = alphaBlockedTo or cand.to
        elseif level < cand.minLevel then
            firstReason = firstReason or I18n.msg("needsLevel", palDisplayName(id), cand.minLevel, level)
        else
            local condOk, unmet = Conditions.evaluate(cand, condCtx)
            if condOk then
                pair = cand
                pairIndex = i
                break
            end
            firstReason = firstReason or I18n.msg("needsConditions", palDisplayName(cand.to), unmet)
        end
    end
    if not pair then
        return nil, firstReason
            or I18n.msg("noAlphaForm", palDisplayName(alphaBlockedTo))
    end
    -- pairIndex is the position in Config.findPairs(id) - the token a
    -- connected client sends over the net channel
    return actor, param, pair, level, holder, isAlpha, pairIndex
end

local function performEvolution(p)
    local actor, param, pair, holder = p.actor, p.param, p.pair, p.holder
    local isAlpha = p.isAlpha == true
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
    oldHalf = staticCapsuleHalf(actor)
    if not oldHalf or oldHalf <= 0 then
        pcall(function() oldHalf = actor:GetSimpleCollisionHalfHeight() end)
    end
    if not oldHalf or oldHalf <= 0 then
        pcall(function() oldHalf = actor.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    end

    local fx = FX
    local ctx = {
        actor = actor, worldCtx = holder,
        playerPawn = playerCtx and playerCtx.pawn or nil,
        oldX = oldX, oldY = oldY, oldZ = oldZ, oldYaw = oldYaw, oldHalf = oldHalf,
        unfreeze = function(a) setFrozen(a, false) end,
        freeze = function(a) setFrozen(a, true) end,
        fx = {},
    }
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
        return false, "Evolution aborted: PalCharacterManager not found"
    end
    local handle = nil
    pcall(function() handle = mgr:GetIndividualHandleFromCharacterParameter(param) end)
    if not (handle and handle:IsValid()) then
        Log("Evolution aborted: individual handle unavailable")
        finishAbort()
        return false, "Evolution aborted: individual handle unavailable"
    end

    -- Take the full cost BEFORE the sequence (no TOCTOU: anything that fails
    -- before the swap refunds everything; after the swap it is earned)
    local costList = Costs.resolve(pair, level, holder)
    if #costList > 0 then
        local failedItem
        txn, failedItem = Costs.beginTransaction(playerCtx, costList)
        if not txn then
            local msg = string.format("Evolution aborted: %dx %s not available/consumable",
                failedItem and failedItem.count or 0, failedItem and failedItem.label or "?")
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
        setFrozen(actor, true)
        pcall(function() actor:SetActorEnableCollision(false) end)
        pcall(function() fx.onDissolve(ctx) end)
    end
    playFanfare(actor)

    -- Teardown with per-strategy despawn verification. The direct manager
    -- teardown destroys the actor without the holder recall action (whose
    -- ball visuals run on a mesh clone that ignores a hidden actor).
    local recallStrategies = {
        { name = "DirectTeardown", fn = function()
            mgr:DespawnCharacterByHandle(handle, nil)
        end },
        { name = "InactivateCurrentOtomo", fn = function()
            holder:InactivateCurrentOtomo()
        end },
        { name = "PlayerController:InactiveOtomo", fn = function()
            local pc = playerCtx and playerCtx.pc
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
        local targetId = swapTargetId(pair, isAlpha) or pair.to

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
        local curId, curAlpha = baseCharacterId(param:GetCharacterID():ToString())
        if curId ~= pair.from or curAlpha ~= isAlpha then
            Log(string.format("Aborted: pal changed during the sequence (now %s%s, expected %s%s)",
                curAlpha and BOSS_PREFIX or "", curId, isAlpha and BOSS_PREFIX or "", pair.from))
            refundCost("pal changed mid-sequence")
            finishAbort()
            return
        end
        local okSwap, errSwap = pcall(function()
            param.SaveParameter.CharacterID = FName(targetId)
            param.SaveParameterMirror.CharacterID = FName(targetId)
        end)
        local idNow = ""
        pcall(function() idNow = param:GetCharacterID():ToString() end)
        if not okSwap or idNow ~= targetId then
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

        -- Snapshot only AFTER a successful swap (no phantom rollback entries);
        -- stores the RAW ids (BOSS_ included) so a rollback restores the alpha
        table.insert(snapshots, {
            key = key, from = isAlpha and (BOSS_PREFIX .. pair.from) or pair.from,
            to = targetId, level = level, nickname = nickname,
            ivHP = talentsBefore.Talent_HP, ivMelee = talentsBefore.Talent_Melee,
            ivShot = talentsBefore.Talent_Shot, ivDefense = talentsBefore.Talent_Defense,
            -- owning player (additive; multiplayer rollback needs to know
            -- whose pal the snapshot belongs to)
            uid = playerCtx and playerCtx.playerUId
                and guidString(playerCtx.playerUId) or nil,
        })
        saveSnapshots()

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
            setRevealFrozen(actor, true)
            NetChannel.sendSignal(pcSender, "start")
            Log(string.format("EVOLVED (server): %s -> %s (level %d) - MP sequence", pair.from, pair.to, level))
            finishOk()

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
            LoopAsync(150, function()
                if watcherDone then return true end
                ExecuteInGameThread(function()
                    if watcherDone then return end
                    -- Disconnect guard: on a dedicated server the requesting
                    -- player's controller (and its otomo holder) are destroyed
                    -- when they leave. Calling a UFunction on a torn-down UObject
                    -- raises a native "Pure virtual not implemented" assert that
                    -- pcall does NOT catch, so gate every deferred touch on
                    -- :IsValid() and abort the sequence (the data mutation already
                    -- committed and the lock was released at finishOk).
                    if not (holder and holder:IsValid() and pcSender and pcSender:IsValid()) then
                        Log("[mpseq] requester left mid-sequence - aborting server presentation")
                        watcherDone = true
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
                        end
                    elseif phase == "activate" then
                        local cand = nil
                        pcall(function() cand = handle:TryGetIndividualActor() end)
                        if not (cand and cand:IsValid()) then watcherDone = true return end
                        -- Read the new pal's capsule half-height. A freshly
                        -- spawned actor's capsule is NOT yet sized to the target
                        -- species for the first frames - it reports a small
                        -- default (~30) that put destZ far too low and sank a big
                        -- pal (Penking) into the ground. Poll until the capsule
                        -- has grown past the old pal's half (evolutions are
                        -- bigger) or a short budget elapses, keeping the best
                        -- value seen. This also gives the client's own capsule
                        -- read time to settle before the reveal signal.
                        -- Absolute capsule half from the static parameter
                        -- component (correct without a mesh, headless-safe). Fall
                        -- back to the collision accessors + a short settle poll
                        -- only if that source is unavailable.
                        local nh = staticCapsuleHalf(cand)
                        if not (nh and nh > 0) then
                            pcall(function() nh = cand:GetSimpleCollisionHalfHeight() end)
                        end
                        if not (nh and nh > 0) then
                            pcall(function() nh = cand.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
                        end
                        nh = nh or 0
                        if nh > nhBest then nhBest = nh end
                        local grew = nhBest > ((savedHalf or 0) * 1.1)
                        if (not grew) and nhTries < 8 then
                            nhTries = nhTries + 1
                            return -- stay in "activate"; let the value settle
                        end
                        nh = (nhBest > 0) and nhBest or nh
                        -- feet-on-ground for the taller new species, plus a
                        -- small lift so it never spawns sunk into the ground
                        local destZ = (savedZ or 0) + 40
                        if savedZ and savedHalf and savedHalf > 0 and nh and nh > 0 then
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
                                -- Re-read the absolute half from the activated
                                -- actor's static parameter component and recompute
                                -- destZ from the best value (belt and braces).
                                local nh2 = staticCapsuleHalf(newActor) or 0
                                local nhUse = math.max(nhBest or 0, nh2 or 0)
                                if savedZ and savedHalf and savedHalf > 0 and nhUse > 0 then
                                    destZ = savedZ - savedHalf + nhUse + 40
                                end
                                -- hard transform-safe freeze (suppresses the
                                -- movement tick + AI + actions, leaves rotation
                                -- writable for the client spin), then place once
                                setRevealFrozen(newActor, true)
                                pcall(function()
                                    newActor:K2_TeleportTo({ X = savedX or 0, Y = savedY or 0, Z = destZ },
                                        { Pitch = 0, Yaw = savedYaw or 0, Roll = 0 })
                                end)
                                pcall(function() newActor:ForceNetUpdate() end)
                                Log("[mpseq] activated fresh " .. targetId .. " -> reveal")
                                NetChannel.sendSignal(pcSender, "reveal")
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
                                local vfxFired = false
                                LoopAsync(250, function()
                                    if vfxFired then return true end
                                    vfxFired = true
                                    -- disconnect guard (see the main loop above)
                                    if not (holder and holder:IsValid()) then return true end
                                    pcall(function()
                                        local na = holder:TryGetSpawnedOtomo()
                                        if na and na:IsValid() then
                                            local vec = na.VisualEffectComponent
                                            if vec and vec:IsValid() then
                                                vec:AddVisualEffect_ToALL(2, { FloatValues = {} }, 0)
                                            end
                                        end
                                    end)
                                    return true
                                end)
                                watcherDone = true
                                -- Keep it pinned for the reveal. The named flags
                                -- are persistent, so only re-assert if the AI
                                -- flips back on (init race). NO transform writes -
                                -- re-teleporting jittered the pal and reset the
                                -- client spin. Release at the end.
                                local holdStart = os.clock()
                                local held = false
                                LoopAsync(300, function()
                                    if held then return true end
                                    -- disconnect guard: never touch a dead holder,
                                    -- and do not attempt an unfreeze on it
                                    if not (holder and holder:IsValid()) then
                                        Log("[mpseq] requester left during reveal hold - releasing")
                                        held = true
                                        return true
                                    end
                                    local na = nil
                                    pcall(function() na = holder:TryGetSpawnedOtomo() end)
                                    if not (na and na:IsValid()) then held = true; return true end
                                    if (os.clock() - holdStart) < 6.2 then
                                        if isAiActive(na) then setRevealFrozen(na, true) end
                                        return false
                                    end
                                    held = true
                                    setRevealFrozen(na, false)
                                    return true
                                end)
                            end
                        end
                    end
                    -- hard deadline: never leave a pal frozen on a lost packet
                    if (not watcherDone) and (os.clock() - startedAt) > 20 then
                        watcherDone = true
                        pcall(function()
                            local na = holder:TryGetSpawnedOtomo()
                            if na and na:IsValid() then setRevealFrozen(na, false) end
                        end)
                    end
                end)
                return watcherDone
            end)
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
                local p = paramOf(a)
                if p and p:IsValid() then idSpawned = p:GetCharacterID():ToString() end
            end)
            if idSpawned ~= targetId then return false end
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
                -- one-shot LoopAsync instead of ExecuteWithDelay: the delay
                -- API's transient callback refs get freed by UE4SS's callback
                -- GC under load ("Ref was not function"), killing every
                -- deferred callback of the mod at once
                LoopAsync(fx.revealDelayMs(), function()
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
                        startRevealDiagnostics(holder, pair.to, playerCtx)
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
                    return true
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
                    local pc = playerCtx.pc
                    pc:SetOtomoSlot(idx)
                    pc:TrySwitchOtomo()
                end)
                Log(string.format("EVOLVED (data only): %s -> %s (level %d) - respawn not confirmed (got class '%s', expected id %s); summon rescue ok=%s",
                    pair.from, pair.to, level, cls, targetId, tostring(okRescue)))
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
            end)
            return pumpDone
        end)
    end

    -- Headless (dedicated server): skip the whole teardown/reveal machinery.
    -- The pal stays summoned as its old actor; proceedAfterDespawn only writes
    -- the new species onto the param (safe while summoned) and the headless
    -- branch there finishes. The client recalls + re-summons to render it.
    if headless then
        proceedAfterDespawn()
        return true
    end

    -- Start the teardown only AFTER the dissolve staging; the actor is
    -- hard-hidden right before it so no despawn visuals are ever seen
    local dissolveMs = 1200
    pcall(function()
        if fx.dissolveDurationMs then dissolveMs = fx.dissolveDurationMs() end
    end)
    -- one-shot LoopAsync instead of ExecuteWithDelay: the delay API's
    -- transient callback refs get freed by UE4SS's callback GC under load
    -- ("Ref was not function"), killing every deferred callback of the mod
    LoopAsync(dissolveMs, function()
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
        return true
    end)
    -- the sequence is started; asynchronous stages report their outcome
    -- through the sequence's own logging/abort paths
    return true
end

-- ---------------------------------------------------------------- public API

function Evolution.check()
    if lockBusy() then
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
    local actor, param, pair, level, holder, isAlpha, pairIndex = findEligibleFor(playerCtx)
    if not actor then
        if not pending then
            -- second return value carries the reason message when present
            local reason = param or I18n.msg("noPalSummoned")
            Log(reason)
            Role.chat(playerCtx, reason)
        end
        return
    end

    -- Full cost check (stone + materials); lists every missing item. On a
    -- connected client this reads the client's own (replicated) inventory
    -- for a readable message; the host re-checks authoritatively.
    local costList = Costs.resolve(pair, level, holder)
    local costOk, missing = Costs.check(playerCtx, costList)
    if not costOk then
        local reason = I18n.msg("couldEvolveMissing",
            palDisplayName(pair.from), level, palDisplayName(pair.to), Costs.describeMissing(missing))
        Log(reason)
        Role.chat(playerCtx, reason)
        return
    end

    local now = os.clock()
    local key = individualKey(param)
    if pending and (now - pending.armedAt) <= Config.confirmWindowSeconds then
        if pending.key == key then
            if Role.hasWorldAuthority() then
                -- use FRESH handles (the pal may have been resummoned since arming)
                performEvolution({ actor = actor, param = param, pair = pair, holder = holder,
                    key = key, isAlpha = isAlpha, playerCtx = playerCtx })
            else
                -- connected client: the confirm travels to the host, which
                -- re-derives and consumes authoritatively
                pending = nil
                NetChannel.sendEvolve(playerCtx, pairIndex or 0)
            end
            return
        else
            Log(I18n.msg("confirmChanged",
                pending.pair and palDisplayName(pending.pair.from) or "?", palDisplayName(pair.from)))
        end
    end
    pending = { armedAt = now, key = key, pair = pair }
    playFanfare(actor)
    local costHint = ""
    if #costList > 0 then
        costHint = I18n.msg("costHint", Costs.describe(costList))
    end
    Log(I18n.msg("canEvolveConfirm",
        palDisplayName(pair.from), level, palDisplayName(pair.to), costHint,
        Config.confirmKey, Config.confirmWindowSeconds))
end

-- true while a confirm is armed; the radial menu label switches to
-- "confirm" in that window
function Evolution.isArmed()
    return pending ~= nil and (os.clock() - pending.armedAt) <= Config.confirmWindowSeconds
end

-- Light-weight availability for the radial label: an owned pal is
-- summoned and has at least one configured option. Level and costs are
-- only checked in the submenu - this runs on every wheel rebuild.
function Evolution.canOffer()
    local ok, res = pcall(function()
        local playerCtx = Role.localPlayerCtx()
        local holder = findHolderFor(playerCtx, nil)
        if not holder then return false end
        local actor = nil
        pcall(function() actor = holder:TryGetSpawnedOtomo() end)
        if not (actor and actor:IsValid()) then return false end
        local param = paramOf(actor)
        if not (param and isOwnedBy(param, playerCtx and playerCtx.playerUId)) then return false end
        local id = baseCharacterId(param:GetCharacterID():ToString())
        if #Config.findPairs(id) == 0 then return false end
        prewarmNames(id)
        return true
    end)
    return ok and res == true
end

-- All evolution/adaptation options for the currently summoned pal with
-- affordability info - feeds the radial submenu. Returns nil, reason when
-- nothing is available.
function Evolution.listOptions()
    if lockBusy() then return nil, I18n.msg("evolutionRunning") end
    local playerCtx = Role.localPlayerCtx()
    local holder = findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return nil, I18n.msg("noPalSummoned") end
    local param = paramOf(actor)
    if not (param and isOwnedBy(param, playerCtx and playerCtx.playerUId)) then return nil, I18n.msg("noPalSummoned") end
    local id, isAlpha = baseCharacterId(param:GetCharacterID():ToString())
    local pairList = Config.findPairs(id)
    if not pairList or #pairList == 0 then
        return nil, I18n.msg("hasNoEvolution", palDisplayName(id))
    end
    local level = 0
    pcall(function() level = param:GetLevel() end)
    local condCtx = { actor = actor, param = param, playerCtx = playerCtx, holder = holder }
    local options = {}
    local byTarget = {}
    for i, pair in ipairs(pairList) do
        -- index is the pair's position in Config.findPairs(id) - the compact
        -- token a connected client sends over the net channel (the host
        -- re-derives the pair from its own config at this index)
        local opt = { pair = pair, index = i, label = palDisplayName(pair.to) }
        if isAlpha and not swapTargetId(pair, true) then
            opt.blocked = I18n.msg("noAlphaFormShort", opt.label)
        elseif level < pair.minLevel then
opt.blocked = I18n.msg("needsLevelShort", opt.label, pair.minLevel, level)
        else
            local condOk, unmet = Conditions.evaluate(pair, condCtx)
            if not condOk then
                opt.blocked = I18n.msg("needsConditions", opt.label, unmet)
            else
                local costList = Costs.resolve(pair, level, holder)
                local costOk, missing = Costs.check(playerCtx, costList)
                if not costOk then
                    opt.blocked = I18n.msg("missingItems",
                        opt.label, Costs.describeMissing(missing))
                end
            end
        end
        -- Same-target variants (either/or conditions) collapse into ONE wheel
        -- entry: the first unblocked variant wins its index; while every
        -- variant is blocked the reasons are joined so the player sees all
        -- ways to unlock the target.
        local existing = byTarget[pair.to]
        if not existing then
            byTarget[pair.to] = opt
            table.insert(options, opt)
        elseif existing.blocked and not opt.blocked then
            existing.pair = opt.pair
            existing.index = opt.index
            existing.blocked = nil
        elseif existing.blocked and opt.blocked then
            existing.blocked = existing.blocked .. I18n.msg("orJoiner") .. opt.blocked
        end
    end
    return options
end

-- Authoritative evolve request: re-derives and re-validates EVERYTHING from
-- the requesting player's context; caller-supplied data is only the pair
-- NAMES, never handles. Serves the in-process path (standalone/listen host)
-- and decoded network requests. Returns ok, message.
local function handleEvolveRequest(playerCtx, fromId, toId)
    if lockBusy() then
        return false, I18n.msg("evolutionRunning")
    end
    if not (playerCtx and playerCtx.pc and playerCtx.pc:IsValid()) then
        return false, "Requesting player unavailable"
    end
    local holder = findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return false, I18n.msg("noPalSummoned") end
    local param = paramOf(actor)
    if not (param and isOwnedBy(param, playerCtx.playerUId)) then
        return false, I18n.msg("noPalSummoned")
    end
    local id, isAlpha = baseCharacterId(param:GetCharacterID():ToString())
    if id ~= fromId then
return false, I18n.msg("selectionOutdated", palDisplayName(id), palDisplayName(fromId))
    end
    -- The pair is re-resolved from the mod config, never taken from the
    -- request. Several same-target variants may exist (either/or conditions):
    -- the first candidate that passes every gate wins, so a stale client pick
    -- still lands on whichever variant currently holds.
    local candidates = {}
    for _, cand in ipairs(Config.findPairs(id)) do
        if cand.to == toId then table.insert(candidates, cand) end
    end
    if #candidates == 0 then
        return false, I18n.msg("noConfiguredEvolution",
            palDisplayName(id), palDisplayName(tostring(toId)))
    end
    local level = 0
    pcall(function() level = param:GetLevel() end)
    local condCtx = { actor = actor, param = param, playerCtx = playerCtx, holder = holder }
    local pair, failReason = nil, nil
    for _, cand in ipairs(candidates) do
        if isAlpha and not swapTargetId(cand, true) then
            failReason = failReason or I18n.msg("noAlphaForm", palDisplayName(cand.to))
        elseif level < cand.minLevel then
            failReason = failReason or I18n.msg("needsLevel", palDisplayName(id), cand.minLevel, level)
        else
            local condOk, unmet = Conditions.evaluate(cand, condCtx)
            if condOk then
                pair = cand
                break
            end
            failReason = failReason or I18n.msg("needsConditions", palDisplayName(cand.to), unmet)
        end
    end
    if not pair then
        return false, failReason or "Conditions not met"
    end
    -- fresh cost pre-check for a readable message; the transaction inside
    -- performEvolution is the authoritative consume
    local costList = Costs.resolve(pair, level, holder)
    local costOk, missing = Costs.check(playerCtx, costList)
    if not costOk then
        return false, I18n.msg("couldEvolveMissing",
            palDisplayName(id), level, palDisplayName(pair.to), Costs.describeMissing(missing))
    end
    -- ok = the sequence STARTED; asynchronous stage failures surface via
    -- the sequence's own logging/abort handling (the network layer sends
    -- no completion acknowledgements)
    local started, reason = performEvolution({ actor = actor, param = param, pair = pair,
        holder = holder, key = individualKey(param), isAlpha = isAlpha,
        playerCtx = playerCtx })
    if not started then
        return false, reason or "Evolution could not start"
    end
    return true
end

-- Host entry for a decoded network request: the client only sent WHICH
-- radial option it picked (an index into the sender's evolution pairs). The
-- host re-derives the pair from ITS OWN config at that index and hands off
-- to the fully-revalidating handleEvolveRequest. Returns ok, message (the
-- message is chatted back to the requester).
local function handleEvolveByIndex(playerCtx, pairIndex)
    local holder = findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return false, I18n.msg("noPalSummoned") end
    local param = paramOf(actor)
    if not (param and isOwnedBy(param, playerCtx and playerCtx.playerUId)) then
        return false, I18n.msg("noPalSummoned")
    end
    local baseId = baseCharacterId(param:GetCharacterID():ToString())
    local pairList = Config.findPairs(baseId)
    local pair = pairList and pairList[pairIndex]
    if not pair then
        return false, I18n.msg("optionUnavailable")
    end
    local ok, msg = handleEvolveRequest(playerCtx, baseId, pair.to)
    if ok then
        return true, I18n.msg("evolvingInto", palDisplayName(pair.to))
    end
    return false, msg
end

-- Executes one option from listOptions - the submenu selection IS the
-- confirmation. Only the pair names travel; the authority re-derives
-- fresh handles and re-validates.
function Evolution.executeOption(opt)
    if not (opt and opt.pair) then return end
    local playerCtx = Role.localPlayerCtx()
    -- the option was greyed out in the wheel (missing materials, too low a
    -- level, no Alpha form): the reason goes to the player chat, not
    -- only to the log
    if opt.blocked then
        Log(opt.blocked)
        Role.chat(playerCtx, opt.blocked)
        return
    end
    if not playerCtx then
        Log(I18n.msg("noLocalPlayer"))
        return
    end
    if Role.hasWorldAuthority() then
        -- re-validation can still fail (state changed since the wheel was
        -- built); surface that reason in chat too
        local ok, msg = handleEvolveRequest(playerCtx, opt.pair.from, opt.pair.to)
        if not ok and msg then
            Log(msg)
            Role.chat(playerCtx, msg)
        end
    else
        -- connected client: send the picked option index to the host over
        -- the net channel. The host does the authoritative swap and, on
        -- success, signals this client to re-play the transformation locally
        -- (Evolution.playRemoteReveal, via the net channel client hook).
        lastRemotePair = opt.pair
        local sent = NetChannel.sendEvolve(playerCtx, opt.index or 0)
        if not sent then
            local msg = I18n.msg("serverUnreachable")
            Log(msg)
            Role.chat(playerCtx, msg)
        end
    end
end

-- Build the fx ctx for the CLIENT re-play. Same shape as the singleplayer ctx,
-- but the transform backend is swapped for MP: yaw goes on the MESH (client-
-- local, smooth), position is owned by the server (placeForScale no-op), and
-- freeze is a no-op (the host freezes authoritatively). Actor SCALE stays as
-- the SP path uses it - scale is not in FRepMovement, so it renders locally on
-- this client and is not reset by the server's movement packets.
local remoteCtx = nil
local remoteRevealBusy = false
local remoteRevealStart = 0
local function buildRemoteCtx(actor, holder, playerCtx, pair)
    local ox, oy, oz, oyaw, ohalf = nil, nil, nil, 0, 0
    pcall(function() local l = actor:K2_GetActorLocation(); ox, oy, oz = l.X, l.Y, l.Z end)
    pcall(function() oyaw = actor:K2_GetActorRotation().Yaw end)
    pcall(function() ohalf = actor:GetSimpleCollisionHalfHeight() end)
    if not ohalf or ohalf <= 0 then
        pcall(function() ohalf = actor.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    end
    local ctx = {
        actor = actor, worldCtx = holder,
        playerPawn = playerCtx and playerCtx.pawn or nil,
        oldX = ox, oldY = oy, oldZ = oz, oldYaw = oyaw, oldHalf = ohalf, newHalf = nil,
        fx = {},
        -- yaw uses the SP default (actor rotation): the host freezes the pal,
        -- so it sends no rotation updates and the client-side spin holds.
        placeForScale = function() end, -- position is server-authoritative
        freeze = function() end,        -- freeze is server-authoritative
        unfreeze = function() end,
    }
    ctx.elemsFrom = (pair and Elements.of(pair.from, holder)) or {}
    if pair and pair.stone == "adaptation" then
        local adapted = Elements.adaptationElement(pair, holder)
        ctx.elemsTo = adapted and { adapted } or (Elements.of(pair.to, holder) or {})
    elseif pair then
        ctx.elemsTo = Elements.of(pair.to, holder) or {}
    else
        ctx.elemsTo = {}
    end
    ctx.colorFrom = Elements.colorFor(ctx.elemsFrom[1])
    ctx.colorTo = Elements.colorFor(ctx.elemsTo[1])
    ctx.completeOk = function() remoteRevealBusy = false; remoteCtx = nil end
    ctx.completeAbort = function()
        pcall(function() FX.cleanup(ctx) end)
        remoteRevealBusy = false; remoteCtx = nil
    end
    return ctx
end

-- CLIENT presentation, driven by the host's phase signals. Reuses the EXACT
-- singleplayer fx staging (dissolve/hide/gap/preReveal/reveal - timing, glow,
-- element bursts, peak loop, finale) so the look is 1:1; the lifecycle
-- (recall/re-summon) goes through the vanilla client-facing controller RPCs,
-- and the host owns freeze + position + the pool break.
--   start  = host froze + swapped the pal -> dissolve, then recall
--   ready  = host destroyed the old pooled body -> re-summon the new form
--   reveal = host teleported + froze the fresh pal at the old spot -> grow/finale
function Evolution.onNetSignal(kind)
    local playerCtx = Role.localPlayerCtx()
    if not playerCtx then return end
    local pc = playerCtx.pc
    local holder = findHolderFor(playerCtx, nil)
    if not holder then return end

    Log("[mpseq-c] signal: " .. tostring(kind))
    if kind == "start" then
        if remoteRevealBusy and (os.clock() - remoteRevealStart) < 20 then return end
        local actor = nil
        pcall(function() actor = holder:TryGetSpawnedOtomo() end)
        if not (actor and actor:IsValid()) then return end
        remoteRevealBusy = true
        remoteRevealStart = os.clock()
        remoteCtx = buildRemoteCtx(actor, holder, playerCtx, lastRemotePair)
        local toName = lastRemotePair and palDisplayName(lastRemotePair.to) or "its new form"
        Role.chat(playerCtx, I18n.msg("evolvingInto", toName))
        pcall(function() playFanfare(actor) end)
        pcall(function() FX.onDissolve(remoteCtx) end)
        -- after the dissolve, start the hold loop and recall the pal
        local dur = 1200
        pcall(function() if FX.dissolveDurationMs then dur = FX.dissolveDurationMs() end end)
        local done = false
        LoopAsync(dur, function()
            if done then return true end
            done = true
            ExecuteInGameThread(function()
                if remoteCtx then pcall(function() FX.onHide(remoteCtx) end) end
                pcall(function() pc:InactiveOtomo() end)
            end)
            return true
        end)

    elseif kind == "reveal" then
        if not remoteCtx then return end
        local a = nil
        pcall(function() a = holder:TryGetSpawnedOtomo() end)
        if not (a and a:IsValid()) then remoteRevealBusy = false; return end
        remoteCtx.worldCtx = holder
        -- The server now places the pal at the correct height (it reads the
        -- absolute capsule half from the static parameter component), so
        -- anchor the finale to where the pal actually stands and size the beam
        -- spread to the species. Height comes from the same static source (also
        -- available on the client), falling back to the capsule accessor.
        local nh = staticCapsuleHalf(a)
        if not (nh and nh > 0) then pcall(function() nh = a:GetSimpleCollisionHalfHeight() end) end
        if not (nh and nh > 0) then nh = 60 end
        -- Anchor the finale to where the pal actually stands; leaving
        -- finaleRadius/Za/Zb unset keeps the tight singleplayer default spread.
        pcall(function()
            local loc = a:K2_GetActorLocation()
            remoteCtx.newHalf = nh
            remoteCtx.oldX, remoteCtx.oldY, remoteCtx.oldZ = loc.X, loc.Y, loc.Z
        end)
        pcall(function() FX.onPreReveal(remoteCtx, a) end)
        local rd = false
        LoopAsync((FX.revealDelayMs and FX.revealDelayMs()) or 100, function()
            if rd then return true end
            rd = true
            ExecuteInGameThread(function()
                pcall(function() FX.onReveal(remoteCtx, a) end)
                pcall(function() playFanfare(a) end)
            end)
            return true
        end)
        -- safety: never leave the busy flag stuck if the reveal driver stalls
        local sd = false
        LoopAsync(9000, function()
            if sd then return true end
            sd = true
            remoteRevealBusy = false
            return true
        end)
    end
end

function Evolution.rollbackLast(playerCtx)
    local function say(msg)
        Log(msg)
        if playerCtx then Role.chat(playerCtx, msg) end
    end
    if lockBusy() then
        say("Rollback blocked: an evolution is currently running")
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
    for i = #snapshots, 1, -1 do
        local s = snapshots[i]
        if not requesterUid then
            snapIdx = i
            break
        end
        if s.uid and s.uid == requesterUid then
            snapIdx = i
            break
        end
    end
    local last = snapIdx and snapshots[snapIdx]
    if not last then
        say("Rollback: no snapshot available")
        return
    end
    local reverted = false
    local all = FindAllOf("PalIndividualCharacterParameter") or {}
    local hasKey = last.key and last.key ~= ""
    -- owner isolation: a snapshot with a stored owner uid may only ever
    -- restore a pal of that same player (legacy snapshots have no uid)
    local function ownerMatches(p)
        if not (last.uid and last.uid ~= "") then return true end
        local m = false
        pcall(function()
            m = guidString(p.SaveParameter.OwnerPlayerUId) == last.uid
        end)
        return m
    end
    for _, p in ipairs(all) do
        if p:IsValid() and isOwned(p) and ownerMatches(p)
            and p:GetCharacterID():ToString() == last.to then
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
        table.remove(snapshots, snapIdx)
        saveSnapshots()
        say(string.format("Rollback %s -> %s: restored including IVs (resummon to see the model)",
            palDisplayName(last.to), palDisplayName(last.from)))
    else
        say(string.format("Rollback %s -> %s: no matching pal found (snapshot kept; bring the pal nearby and retry)",
            palDisplayName(last.to), palDisplayName(last.from)))
    end
end

function Evolution.init()
    loadSnapshots()

    -- authority entry for in-process and network requests
    Authority.bind({ evolve = handleEvolveRequest })

    -- host side of the net channel: decode connected-client evolve requests
    -- and run them through the fully-revalidating index handler. The hook
    -- fires only where the game routes _ToServer RPCs (the authority); on a
    -- pure client it registers but never fires.
    NetChannel.initHost(function(senderCtx, pairIndex)
        return handleEvolveByIndex(senderCtx, pairIndex)
    end)

    -- client side of the net channel: the host drives the presentation with
    -- phase signals (start/ready/reveal) which we play locally (no local
    -- player = no-op, so this is harmless on a dedicated server)
    NetChannel.initClient(function(kind)
        Evolution.onNetSignal(kind)
    end)

    -- keybinds are player input - meaningless on a dedicated server
    if not Role.isDedicated() then
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
                    local actor = self:get()
                    local param = actor.CharacterParameterComponent:GetIndividualParameter()
                    -- the notification is local UX: only this machine's
                    -- player should hear about their own pals
                    local localCtx = Role.localPlayerCtx()
                    if not isOwnedBy(param, localCtx and localCtx.playerUId) then return end
                    local id, isAlpha = baseCharacterId(param:GetCharacterID():ToString())
                    local pair = nil
                    for _, cand in ipairs(Config.findPairs(id)) do
                        if not (isAlpha and not swapTargetId(cand, true)) then
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
                        local key = individualKey(param) .. ">" .. pair.to
                        if notified[key] then return end
                        notified[key] = true
                        playFanfare(actor)
                        -- conditions are transient, so the reached-level hint
                        -- still fires and lists the remaining conditions
                        local condHint = ""
                        local conds = Conditions.describe(pair)
                        if conds then condHint = I18n.msg("whenSuffix", conds) end
                        Log(I18n.msg("reachedLevel",
                            palDisplayName(id), newLevel, palDisplayName(pair.to), condHint,
                            Config.confirmKey))
                    end
                end)
            end)
        hookRegistered = ok
        return ok
    end
    -- The notification is client-side UX (fanfare + on-screen hint); on a
    -- dedicated server the poll would churn transient callback refs forever
    -- (no local player pawn ever exists), so it must not run there.
    if not Role.isDedicated() then
        if not tryHook() then
            LoopAsync(5000, function()
                if hookRegistered then return true end
                ExecuteInGameThread(function() tryHook() end)
                return hookRegistered
            end)
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

    -- chat commands: the retail build ships without an in-game console
    pcall(function()
        local ChatCommands = require("chatcommands")
        local okCmd = ChatCommands.init({
            rollback = function(senderCtx) Evolution.rollbackLast(senderCtx) end,
            help = function(senderCtx)
                Role.chat(senderCtx, "Palvolve: /palvolve rollback restores your last evolved Pal")
            end,
        })
        if okCmd then Log("Chat commands active: /palvolve rollback") end
    end)

    Log(string.format("Evolution core active: %s = check/confirm, chat: /palvolve rollback",
        Config.confirmKey))
end

return Evolution
