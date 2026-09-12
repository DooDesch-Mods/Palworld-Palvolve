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

-- An unset FGuid reads as all zeros. It is a table like any other, so a plain nil check
-- accepts it as an identity and it then matches no record at all.
local function isZeroGuid(g)
    return not g or (g.A == 0 and g.B == 0 and g.C == 0 and g.D == 0)
end

-- Catch-gated technologies (saddles, Pal gear) unlock when a species is CAPTURED, not when
-- its CharacterID changes - so an evolved form stays locked. The capture record lives in
-- replicated FastArrays that UE4SS-Lua cannot map; the native companion (dlls/main.dll)
-- sets it through the game's own _ForServer setters. See
-- Workspace/docs/Palvolve/KNOWN-ISSUE-catch-tech-unlock.md.
local nativeMissingLogged = false
-- Keyed by player, not a single flag: on a dedicated server one shared flag would let the
-- first player to hit a failure consume the notice for everyone else.
local techUnlockNoticeSent = {}
local function unlockCatchTech(targetId, playerCtx)
    if not Config.unlockCatchTech then return end

    -- Without the companion the evolution itself is unaffected: skip quietly, note it once.
    if type(PalvolveNative_UnlockCaptureRecord) ~= "function" then
        if not nativeMissingLogged then
            nativeMissingLogged = true
            Log("Native companion missing - catch-gated technologies stay locked for this session")
        end
        return
    end

    local uid = ""
    pcall(function()
        if playerCtx and not isZeroGuid(playerCtx.playerUId) then
            uid = guidString(playerCtx.playerUId)
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

--- Is there a world to ask. The text system answers through the local player
--- character, and in the main menu there is none - every name then costs a
--- reflection round trip, fails, is not cached, and is asked again on the next
--- pass. Hundreds of those per menu screen are the cost, and the log fills with
--- FAIL lines that say nothing.
-- The text system needs two objects, and both are the same for a whole world:
-- the local character and the master data utility. Looking them up per name is
-- what made a name cost milliseconds, because FindFirstOf walks the object
-- list every time and a single tree page asks for two dozen names. Held here
-- and revalidated, so a page pays for one lookup instead of two per Pal.
local cachedNameCtx = nil
local cachedNameMdt = nil

local function nameLookupPair()
    if not (cachedNameCtx and cachedNameCtx:IsValid()) then
        cachedNameCtx = FindFirstOf("PalPlayerCharacter")
    end
    if not (cachedNameCtx and cachedNameCtx:IsValid()) then return nil, nil end
    if not (cachedNameMdt and cachedNameMdt:IsValid()) then
        cachedNameMdt = StaticFindObject("/Script/Pal.Default__PalMasterDataTablesUtility")
    end
    if not (cachedNameMdt and cachedNameMdt:IsValid()) then return nil, nil end
    return cachedNameMdt, cachedNameCtx
end

local function worldIsUp()
    if cachedNameCtx and cachedNameCtx:IsValid() then return true end
    local pc = FindFirstOf("PalPlayerCharacter")
    if pc and pc:IsValid() then
        cachedNameCtx = pc
        return true
    end
    return false
end

local function palDisplayName(id)
    local cached = displayNameCache[id]
    if cached then return cached end
    if not worldIsUp() then return id end
    -- Alphas carry a BOSS_ prefix that the text table does not know: it keys
    -- one entry per species, exactly like the Palpedia. Asking for the prefixed
    -- key returns the key itself ("PAL_NAME_BOSS_CubeTurtle_Neutral"), so the
    -- prefix is stripped for the lookup while the cache stays keyed by the
    -- original id.
    local lookupId = id:gsub("^BOSS_", "")
    local name = nil
    local function ask()
        pcall(function()
            local mdt, ctx = nameLookupPair()
            if not (mdt and ctx) then return end
            -- EPalLocalizeTextCategory::PalMonsterName = 4
            local txt = mdt:GetLocalizedText(ctx, 4, FName("PAL_NAME_" .. lookupId))
            if txt then
                local s = txt:ToString()
                -- An unknown key comes back as the key. Treating that as a name
                -- would also cache it, so the raw key would stick for the session.
                if s and s ~= "" and s:sub(1, 9) ~= "PAL_NAME_" then name = s end
            end
        end)
    end
    ask()
    if not name then
        -- The two objects the lookup rides on are held between calls, and a
        -- held character does not survive its player leaving: on a server that
        -- turned every name into its raw id from the first disconnect onwards.
        -- IsValid still answers yes for an object that is on its way out, so
        -- the only reliable signal is the lookup itself failing.
        cachedNameCtx, cachedNameMdt = nil, nil
        ask()
    end
    -- Five species have no PAL_NAME_ row at all, so no amount of retrying
    -- produces a name and the raw CharacterID was what the wheel showed. Their
    -- names are baked per language from the same source the website uses.
    if not name then name = I18n.palName(id) end
    if Config.devMode then
        Log(string.format("[radial] name lookup %s -> %s", id, name or "FAIL"))
    end
    -- only successful lookups are cached so an early call (no world yet)
    -- retries later; the cache resets with the Lua state on restart
    if name then displayNameCache[id] = name end
    return name or id
end

-- Exported for the guide pages, which name every species in the configured
-- tree and must use the same localized names the wheel shows.
Evolution.displayName = palDisplayName

-- Warms the submenu labels while the MAIN wheel is still open: the localized
-- name lookups cost ~30 ms each on first use, so doing them here means the
-- Evolve click later builds its options from the cache without delay.
-- The loop is bounded per species and ends after one pass over the list.
local warmedNames = {}
local function prewarmNames(id)
    if warmedNames[id] then return end
    -- Nothing to warm without a world: the names would all miss, and missing
    -- names are not remembered, so the pass would be pure cost.
    if not worldIsUp() then return end
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

    local holder = findHolderFor(playerCtx, nil)
    if not (holder and holder:IsValid()) then return bail("no otomo holder") end
    local mgr = findManager(playerCtx.pc)
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
    local fired = false
    LoopAsync(700, function()
        if fired then return true end
        fired = true
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                if not (holder and holder:IsValid()
                    and playerCtx.pc and playerCtx.pc:IsValid()) then return end
                playerCtx.pc:SetOtomoSlot(slot)
                holder:SpawnOtomoByLoad(slot)
            end)
            if ok then
                Log(string.format("Resummoned slot %d after rollback", slot))
            else
                Log("Resummon failed: " .. tostring(err))
            end
        end)
        return true
    end)
    return true
end

-- Rollback reaches back to the start of this session and no further.
--
-- Restore points live in memory. The file is still written, as executable Lua
-- (simplest robust format without a JSON lib), so the session's restore points
-- stay inspectable from outside the game, but it is never read back: a rollback
-- returns what the evolution cost, and a restore point that outlives the
-- session would hand back stones for an evolution made days ago, on a Pal that
-- has been levelled, bred or traded since. Undoing what you just did is the
-- promise; undoing your history is not.
local snapshots = {}

-- Rollback lives in memory for the session, so there is no state file. Older
-- versions wrote one on the game thread after every evolution, never read it
-- back, and left it behind on uninstall - so it is deleted here, once.
local function loadSnapshots()
    snapshots = {}
    local hadEntries = false
    pcall(function()
        local f = io.open(STATE_FILE, "r")
        if not f then return end
        local body = f:read("*a") or ""
        f:close()
        hadEntries = body:find("{ key =", 1, true) ~= nil
        os.remove(STATE_FILE)
    end)
    if hadEntries then
        Log("Rollback restore points from earlier sessions discarded - rollback covers this session")
    end
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

local workNativeAnnounced = false
local function refreshWorkSuitability(param, playerCtx, actor, previousId)
    if type(PalvolveNative_SetWorkSuitability) ~= "function" then
        if not workNativeAnnounced then
            workNativeAnnounced = true
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
    -- Opt-in on top of devMode. Each call leaves a LoopAsync closure running for 12s with an
    -- ExecuteInGameThread nested inside it; two evolutions in quick succession overlap two of
    -- them and the game dies with "Ref was not function" - the callback GC trap from
    -- UE4SS-LESSONS.md. Off by default so repeated evolutions can be tested at all.
    if not Config.diagReveal then return end
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

-- Heartbeat for the mod's own timers. Every timed step runs on callbacks that
-- UE4SS delivers from its Lua tick hook, and that hook is removed as soon as
-- one callback reference has been garbage collected while still scheduled
-- ("Ref was not function"). From then on nothing timed happens: an evolution
-- that is mid-flight never reaches its next phase, the Pal stays hidden and
-- the stone is already spent, with no line in the log to say why. Hooks keep
-- firing though, so anything hook-driven can still notice the silence.
local lastBeat = os.clock()
local lastTimersNotice = -1000
LoopAsync(1000, function()
    lastBeat = os.clock()
    return false
end)

-- Deliberately generous: five missed beats, so a loading screen or a frame
-- spike is never mistaken for a dead tick.
local function timersDead()
    return (os.clock() - lastBeat) > 5
end

-- Long past any stall a running process can produce, so this one is safe to
-- act on: starting an evolution here would take the cost and then stop at the
-- first timed step, leaving the player a hidden Pal and a spent stone.
local function timersGone()
    return (os.clock() - lastBeat) > 15
end

-- Said from both entry points, at most twice a minute: the state does not heal
-- on its own, so repeating it on every press would bury the chat.
local function reportDeadTimers(playerCtx)
    if (os.clock() - lastTimersNotice) <= 30 then return end
    lastTimersNotice = os.clock()
    Log("the timers are not running: UE4SS removed this mod's Lua tick hook, "
        .. "so no timed step of the mod happens any more. A game restart brings them back.")
    -- A reply, not a notice: both callers are the player reaching for evolution
    -- and getting nothing back. Silenced, the key and the wheel entry would just
    -- stop working with no reason given.
    Role.chat(playerCtx or Role.localPlayerCtx(), I18n.msg("timersDead"), "reply")
end

--- True while the mod's timed steps are still being delivered.
function Evolution.timersAlive()
    return not timersDead()
end

-- Frees a stuck lock (budget exceeded); returns true while the lock is busy.
local function lockBusy()
    if not sequenceRunning then return false end
    if timersDead() then
        Log("the timers stopped while an evolution was running, so the sequence "
            .. "cannot finish: UE4SS removed this mod's Lua tick hook, which is "
            .. "what delivers every timed step. Aborting the run; the cost comes "
            .. "back unless the species swap already went through.")
        if currentAbort then pcall(currentAbort) else sequenceRunning = false end
        return sequenceRunning
    end
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

-- This is also the single point where a runtime id gets its spelling fixed.
-- The game reports a CharacterID as an FName, which compares case-insensitively
-- but hands back whichever spelling was registered first that session, while
-- every lookup below this point matches a string exactly. The prefix test runs
-- without case for the same reason: the game's own data spells one Alpha row
-- "Boss_Anubis" rather than "BOSS_Anubis".
local BOSS_PREFIX_LOWER = BOSS_PREFIX:lower()
local function baseCharacterId(rawId)
    if rawId:sub(1, #BOSS_PREFIX):lower() == BOSS_PREFIX_LOWER then
        return Config.canonicalId(rawId:sub(#BOSS_PREFIX + 1)), true
    end
    return Config.canonicalId(rawId), false
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

-- Sanitization keeps known ids usable for diagnostics, but a dropped id means
-- this binary cannot prove the author's complete rule. The metadata never goes
-- on the wire; it only turns every local gate for that pair into fail-closed.
local function unknownConditionReason(pair)
    local metadata = pair and pair.conditionMetadata
    if metadata and metadata.hasUnknown then
        return I18n.msg("unknownConditionsBlocked")
    end
    return nil
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
    return guidString(param.IndividualId.InstanceId)
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

local function conditionCount(pair)
    return type(pair and pair.conditions) == "table" and #pair.conditions or 0
end

local function controllerHasAuthority(pc)
    return pc:HasAuthority() == true
end

local function characterIdUnsafe(param)
    return param:GetCharacterID():ToString()
end

local function disclosedConditions(pair, exactText)
    if Config.conditionDisclosure == "exact" then return exactText end
    return Conditions.describe(pair, Config.conditionDisclosure) or exactText
end

-- Normal connections always win. A Pal with anything still ahead of it is not
-- allowed to use prestige as a shortcut around that connection, even while its
-- level or conditions are not met yet.
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

local function optionPairsFor(characterId)
    local ordinary = Config.findPairs(characterId)
    if ordinary and #ordinary > 0 then return ordinary, false end
    local prestige, err = Prestige.forSpecies(Config, characterId)
    return prestige, true, err
end

local function requiredLevelFor(pair)
    if pair and pair.category == "prestige" then
        return tonumber(Config.prestigeMinLevel) or 1
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
        local wazaOk, wazaErr = WazaInherit.restore(param, wazaState)
        if not wazaOk then errors[#errors + 1] = "moves=" .. tostring(wazaErr) end
    end
    if #errors > 0 then return false, table.concat(errors, "; ") end
    return true
end

local function readPrestigeFieldsUnsafe(param)
    return {
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
    local okId, readId = pcall(characterIdUnsafe, param)
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
    local pairList, isPrestige, prestigeErr = optionPairsFor(id)
    if isPrestige and prestigeAtMax(param) then
        return nil, I18n.msg("prestigeAtMax", palDisplayName(id))
    end
    if not pairList or #pairList == 0 then
        if prestigeErr then Log("Prestige targets unavailable: " .. tostring(prestigeErr)) end
        if isPrestige then return nil, I18n.msg("hasNoPrestige", palDisplayName(id)) end
        return nil, I18n.msg("hasNoEvolution", palDisplayName(id))
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
        local unknownReason = unknownConditionReason(cand)
        if unknownReason then
            firstReason = firstReason or unknownReason
        elseif isAlpha and not swapTargetId(cand, true) then
            alphaBlockedTo = alphaBlockedTo or cand.to
        elseif level < requiredLevelFor(cand) then
            firstReason = firstReason or I18n.msg(
                isPrestige and "needsLevelPrestige" or "needsLevel",
                palDisplayName(id), requiredLevelFor(cand), level)
        else
            local condOk, unmet = Conditions.evaluate(cand, condCtx)
            if not condOk and AutoUnlock.has(param, cand.to) then condOk = true end
            if condOk then
                -- The cost belongs in this loop. Checked only afterwards, a
                -- species whose first target lacks a stone reported that stone
                -- and never mentioned the target the player could pay for.
                local affordable = true
                pcall(function()
                    affordable = (Costs.check(playerCtx, Costs.resolve(cand, level, holder)))
                end)
                if affordable then
                    local count = conditionCount(cand)
                    if Config.evolutionMode ~= "conditioned" or count > pairConditionCount then
                        pair = cand
                    pairIndex = isPrestige and cand.prestigeIndex or i
                        pairConditionCount = count
                    end
                    if Config.evolutionMode ~= "conditioned" then break end
                end
                if not unpaid or (Config.evolutionMode == "conditioned"
                    and conditionCount(cand) > conditionCount(unpaid)) then
                    unpaid, unpaidIndex = cand, i
                end
            else
                firstReason = firstReason or I18n.msg("needsConditions",
                    palDisplayName(cand.to), disclosedConditions(cand, unmet))
            end
        end
    end
    if not pair and unpaid then
        pair = unpaid
        pairIndex = isPrestige and unpaid.prestigeIndex or unpaidIndex
    end
    if not pair then
        return nil, firstReason
            or I18n.msg("noAlphaForm", palDisplayName(alphaBlockedTo))
    end
    -- pairIndex is the position in Config.findPairs(id) - the token a
    -- connected client sends over the net channel
    return actor, param, pair, level, holder, isAlpha, pairIndex, isPrestige
end

local function performEvolution(p)
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
        oldHalf = staticCapsuleHalf(actor)
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
        local u = palUtility()
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
        unfreeze = function(a) setFrozen(a, false) end,
        freeze = function(a) setFrozen(a, true) end,
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
    -- Which prestige programme plays: the Pal's own stage, so the Nth prestige
    -- outdoes the N-1th. Unknown reads as 1 rather than as nothing.
    -- The host's number wins where it is available: the local passive list can
    -- still be the pre-prestige one when this runs on a client.
    ctx.prestigeStage = (pair and tonumber(pair.prestigeStage)) or 1
    if ctx.isPrestige and not (pair and pair.prestigeStage) then
        local probeParam = paramOf(ctx.actor)
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

    -- Prestige changes three independent save surfaces. Refuse before taking a
    -- cost or hiding the actor unless every one can be captured for an exact
    -- rollback; a partial reset is worse than no prestige at all.
    local prestigeState = nil
    if isPrestige then
        local captureErr
        prestigeState, captureErr = capturePrestigeState(param)
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
        skinBefore, skinErr = captureSkinState(param)
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
        setFrozen(actor, true)
        pcall(function() actor:SetActorEnableCollision(false) end)
        pcall(function() fx.onDissolve(ctx) end)
    end
    playFanfare(actor)

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
        currentAbort = nil
        pcall(function() fx.cleanup(ctx) end)
        sequenceRunning = false
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
        if not handlesAlive() then
            abandonOnTeardown()
            return
        end
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
        local originalId = isAlpha and (BOSS_PREFIX .. pair.from) or pair.from
        local function restoreFailedMutation(reason)
            local stateOk, stateErr
            if isPrestige then
                stateOk, stateErr = restorePrestigeState(param, prestigeState)
            else
                local okSpecies, speciesErr = pcall(writeSpeciesUnsafe, param, originalId)
                local okId, restoredId = pcall(characterIdUnsafe, param)
                stateOk = okSpecies and okId
                    and Config.canonicalId(restoredId) == Config.canonicalId(originalId)
                stateErr = speciesErr
            end
            local survivorOk, survivorErr = restoreSwapSurvivors(param, skinBefore, wazaBefore)
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

        if isPrestige then
            local mutationOk, passiveResult = applyPrestigeMutation(param, targetId, playerCtx)
            if not mutationOk then
                restoreFailedMutation(passiveResult)
                return
            end
            local survivorOk, survivorErr = applySwapSurvivors(param, skinBefore, wazaBefore)
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
            local okSwap, errSwap = pcall(writeSpeciesUnsafe, param, targetId)
            local idNow = ""
            local okId, readId = pcall(characterIdUnsafe, param)
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
            local survivorOk, survivorErr = applySwapSurvivors(param, skinBefore, wazaBefore)
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
            applyIvBonus(param)
            local passiveOk, passiveResult = PalPassives.grantEvolved(param)
            if passiveOk then
                Log(string.format("Evolution bonus (passive): %s", passiveResult.id))
                -- Optional and off by default: an extra slot on top of the ladder
                -- reward, which a server owner turns on. It fails loudly and
                -- changes nothing else, because the swap is already committed.
                local slotOk, slotResult = PalSlots.grantEvolution(param, playerCtx)
                reportBonusSlot(playerCtx, slotOk, slotResult, "Evolution")
            else
                -- The cost is already committed. Continuing keeps the successful
                -- species swap at the tradeoff that this reward is not refunded alone.
                Log("EVOLVED PASSIVE WRITE FAILED after cost commit: "
                    .. tostring(passiveResult) .. " - evolution remains committed")
            end
        end
        pcall(function() param:FullRecoveryHP() end)
        refreshWorkSuitability(param, playerCtx, actor, pair.from)

        -- Snapshot only AFTER a successful swap (no phantom rollback entries);
        -- stores the RAW ids (BOSS_ included) so a rollback restores the alpha
        table.insert(snapshots, {
            kind = isPrestige and "prestige" or "evolution",
            key = key, from = isAlpha and (BOSS_PREFIX .. pair.from) or pair.from,
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
                and guidString(playerCtx.playerUId) or nil,
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
        unlockCatchTech(pair.to, playerCtx)

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
            local phaseSequence = nil
            pcall(function()
                -- The client draws the sequence, so the mode it is told IS the
                -- look. Anything not named here falls back to the evolution
                -- presentation rather than reaching the wire as an unknown word.
                local presentationMode = pair.category
                if presentationMode ~= "adaptation" and presentationMode ~= "prestige" then
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
            LoopAsync(150, function()
                if watcherDone then return true end
                ExecuteInGameThread(function()
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
                            if oldActor and oldActor:IsValid() then setRevealFrozen(oldActor, false) end
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
                            nh = staticCapsuleHalf(cand)
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
                                    nh2 = staticCapsuleHalf(newActor) or 0
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
                                setRevealFrozen(newActor, true)
                                pcall(function()
                                    newActor:K2_TeleportTo({ X = savedX or 0, Y = savedY or 0, Z = destZ },
                                        { Pitch = 0, Yaw = savedYaw or 0, Roll = 0 })
                                end)
                                pcall(function() newActor:ForceNetUpdate() end)
                                -- fresh actor now carries the new species; refresh
                                -- work suitability HERE (the swap-time call ran on
                                -- the old actor and could not re-derive the base)
                                refreshWorkSuitability(param, playerCtx, newActor, pair.from)
                                Log("[mpseq] activated fresh " .. targetId .. " -> reveal")
                                -- Second read, on the far side of the reload. The
                                -- write before the swap reports success, so what
                                -- is left to learn is whether SpawnOtomoByLoad
                                -- rebuilds the move lists from the new species and
                                -- drops what was written into them.
                                local probeParam = paramOf(newActor)
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
                                local digimon = Config.digimon or {}
                                local holdSeconds = ((tonumber(digimon.growMs) or 0)
                                    + (tonumber(digimon.finaleHoldMs) or 0)) / 1000
                                local held = false
                                LoopAsync(300, function()
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
                                        if isAiActive(na) then setRevealFrozen(na, true) end
                                        return false
                                    end
                                    held = true
                                    setRevealFrozen(na, false)
                                    finishOk()
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
                        finishOk()
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
                            local mh = staticCapsuleHalf(newActor)
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
    -- one-shot LoopAsync instead of ExecuteWithDelay: the delay API's
    -- transient callback refs get freed by UE4SS's callback GC under load
    -- ("Ref was not function"), killing every deferred callback of the mod
    LoopAsync(dissolveMs, function()
        ExecuteInGameThread(function()
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
        end)
        return true
    end)
    -- the sequence is started; asynchronous stages report their outcome
    -- through the sequence's own logging/abort paths
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

-- F2 is defined before the indexed authority handler below, but it must enter
-- that same pipeline rather than capture a pair table from the arm step.
local handleEvolveByIndex
local handlePrestigeByIndex

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
    if timersDead() then
        reportDeadTimers(nil)
        if timersGone() then return end
    end
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
                palDisplayName(pair.from), level, palDisplayName(pair.to), Costs.describeMissing(missing))
        else
            reason = I18n.msg("couldEvolveMissing",
                palDisplayName(pair.from), level, palDisplayName(pair.to), Costs.describeMissing(missing))
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
    local key = individualKey(param)
    if pending and (now - pending.armedAt) <= Config.confirmWindowSeconds then
        if pending.key == key then
            if Role.hasWorldAuthority() then
                -- Run the same indexed revalidation as the wheel, network and
                -- watcher. The pal or a same-target variant may have changed
                -- since this confirmation was armed.
                local ok, msg
                if isPrestige then
                    ok, msg = handlePrestigeByIndex(playerCtx, pairIndex)
                else
                    ok, msg = handleEvolveByIndex(playerCtx, pairIndex)
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
                pending.pair and palDisplayName(pending.pair.from) or "?", palDisplayName(pair.from)))
        end
    end
    pending = { armedAt = now, key = key, pair = pair }
    playFanfare(actor)
    local costHint = ""
    if #costList > 0 then
        costHint = I18n.msg("costHint", Costs.describe(costList))
    end
    if isPrestige then
        Log(I18n.msg("canPrestigeConfirm",
            palDisplayName(pair.from), level, palDisplayName(pair.to), costHint,
            Config.confirmKey, Config.confirmWindowSeconds))
    else
        Log(I18n.msg("canEvolveConfirm",
            palDisplayName(pair.from), level, palDisplayName(pair.to), costHint,
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
        local holder = findHolderFor(playerCtx, nil)
        if not holder then
            return "no otomo holder for the local player", I18n.msg("noPalSummoned")
        end
        local actor = nil
        pcall(function() actor = holder:TryGetSpawnedOtomo() end)
        if not (actor and actor:IsValid()) then
            return "no pal summoned", I18n.msg("noPalSummoned")
        end
        local param = paramOf(actor)
        if not param then
            return "the summoned pal has no individual parameter", I18n.msg("noPalSummoned")
        end
        local id = baseCharacterId(param:GetCharacterID():ToString())
        if not isOwnedBy(param, playerCtx and playerCtx.playerUId) then
            -- a traded or gifted pal keeps the original catcher in its save
            -- record, so it reads as someone else's while sitting in this
            -- player's own party
            return string.format("pal '%s' is not owned by this player", id),
                I18n.msg("greyNotYours")
        end
        local pairList, isPrestige, prestigeErr = optionPairsFor(id)
        -- Before any of the refusals below, not after them. The entry names
        -- itself from this, and every early return left it on the value the
        -- last Pal set - so a Pal whose only step is a prestige was refused
        -- under the word "Evolve", while the reason beside it talked about
        -- prestige. A greyed entry still has to say what it is greyed FOR.
        lastOfferPrestige = isPrestige
        if isPrestige and prestigeAtMax(param) then
            return string.format("pal '%s' is already at the last prestige rank", id),
                I18n.msg("prestigeAtMax", palDisplayName(id))
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
        prewarmNames(id)
        return nil
    end)
    if not ok then
        offerVerdict("availability check failed: " .. tostring(reason))
        return false
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

    local holder = findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then
        previewReply(playerCtx, I18n.msg("noPalSummoned"))
        return
    end

    local id = ""
    local param = paramOf(actor)
    if param then
        local okId, raw = pcall(function() return param:GetCharacterID():ToString() end)
        if okId then id = baseCharacterId(raw) end
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
    setRevealFrozen(actor, true)
    local frozenActor = actor
    local until_ = os.clock() + lease
    LoopAsync(250, function()
        if os.clock() < until_ then return false end
        ExecuteInGameThread(function()
            if frozenActor and frozenActor:IsValid() then
                setRevealFrozen(frozenActor, false)
            end
        end)
        Log("prestige preview: pal released")
        return true
    end)

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
            LoopAsync(250, function()
                if os.clock() < doneAt then return false end
                ExecuteInGameThread(function() FX.previewOutro(intro) end)
                return true
            end)
        end
    end

    Finale.playStandalone(holder, loc.X, loc.Y, loc.Z, {}, half, meshHalf,
        { isPrestige = true, stage = stage, beats = beats })
end

function Evolution.offerIsPrestige()
    return lastOfferPrestige == true
end

-- All evolution/adaptation options for the currently summoned pal with
-- affordability info - feeds the radial submenu. Returns nil, reason when
-- nothing is available.
-- The middle of the radial is a circle, not a line. A pair with six conditions
-- and nine materials produces roughly 200 characters, so the text is split by
-- kind and each kind wrapped, instead of being handed over as one run that
-- would leave the circle on both sides.
local CENTER_WIDTH = 30
-- The circle has room for a handful of lines, not for a shopping list. Past
-- this the price is summarised instead, so an absurd config cannot push the
-- text out of the ring.
local CENTER_MAX_LINES = 6

-- Greedy word wrap. Breaks on spaces only, so an item name never gets cut in
-- half, and a single word longer than the width stays on its own line rather
-- than being sliced mid-character - cutting by bytes would land inside a
-- multi-byte character in German, Russian or Japanese.
local function wrapText(text, width, out)
    local line = nil
    for word in tostring(text):gmatch("%S+") do
        if not line then
            line = word
        elseif #line + 1 + #word <= width then
            line = line .. " " .. word
        else
            table.insert(out, line)
            line = word
        end
    end
    if line then table.insert(out, line) end
end

-- The requirements of one target as wrapped lines: level, then conditions,
-- then price. The target's own name is left out because the wheel segment
-- already carries it. Costs resolve against the pair's minimum level, the
-- earliest point the price applies, which is the level the guide quotes too.
local function requirementLine(pair, level, worldCtx)
    local lines = {}
    -- What KIND of step this is, above the level and the price. A prestige and
    -- an ordinary evolution ask for the same things and cost the same shape of
    -- price, so without a word for it the middle of the wheel reads identically
    -- for a step that resets the Pal and one that does not. Auto-Evo is the
    -- same case from the other side: it does not wait to be picked, and the
    -- colour on the segment only says so to somebody who knows the colour.
    if pair.category == "prestige" then
        wrapText(I18n.msg("prestige"), CENTER_WIDTH, lines)
    end
    if pair.autoEvolve == true then
        wrapText(I18n.msg("autoLockEntry"), CENTER_WIDTH, lines)
    end
    local minLevel = requiredLevelFor(pair)
    if minLevel > 0 then wrapText(I18n.msg("guideLevelShort", minLevel), CENTER_WIDTH, lines) end

    local cond = Conditions.describe(pair, Config.conditionDisclosure)
    if cond and cond ~= "" then wrapText(cond, CENTER_WIDTH, lines) end

    local okCost, costList = pcall(Costs.resolve, pair, minLevel, worldCtx)
    if okCost and type(costList) == "table" and #costList > 0 then
        local before = #lines
        local okDesc, text = pcall(Costs.describe, costList)
        if okDesc and text and text ~= "" then
            wrapText(text, CENTER_WIDTH, lines)
            -- A price that does not fit is replaced by its own summary rather
            -- than cut mid-list, so the player still learns there is a cost and
            -- how big it is. The full list is on the guide page.
            if #lines > CENTER_MAX_LINES then
                for i = #lines, before + 1, -1 do lines[i] = nil end
                wrapText(I18n.msg("costItemCount", #costList), CENTER_WIDTH, lines)
            end
        end
    end

    if #lines == 0 then return nil end
    -- Last word on the budget. The cost block trims itself above, but the
    -- kind of step, the level and the conditions do not, and together they
    -- pass the cap on their own: two kind lines plus a level plus three
    -- conditions plus a price is eight. What goes is what came last, so the
    -- kind and the level - the two a player reads first - always survive.
    for i = #lines, CENTER_MAX_LINES + 1, -1 do lines[i] = nil end
    return table.concat(lines, "\n")
end

function Evolution.listOptions()
    if ServerCheck.blocked() then return nil, I18n.msg("serverNoPalvolveShort") end
    if lockBusy() then return nil, I18n.msg("evolutionRunning") end
    local playerCtx = Role.localPlayerCtx()
    local holder = findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return nil, I18n.msg("noPalSummoned") end
    local param = paramOf(actor)
    if not (param and isOwnedBy(param, playerCtx and playerCtx.playerUId)) then return nil, I18n.msg("noPalSummoned") end
    local id, isAlpha = baseCharacterId(param:GetCharacterID():ToString())
    local pairList, isPrestige, prestigeErr = optionPairsFor(id)
    if isPrestige and prestigeAtMax(param) then
        return nil, I18n.msg("prestigeAtMax", palDisplayName(id))
    end
    if not pairList or #pairList == 0 then
        if prestigeErr then Log("Prestige targets unavailable: " .. tostring(prestigeErr)) end
        if isPrestige then return nil, I18n.msg("hasNoPrestige", palDisplayName(id)) end
        return nil, I18n.msg("hasNoEvolution", palDisplayName(id))
    end
    local level = 0
    pcall(function() level = param:GetLevel() end)
    local condCtx = { actor = actor, param = param, playerCtx = playerCtx, holder = holder }
    local options = {}
    local byTarget = {}
    local conditioned = Config.evolutionMode == "conditioned"
    local conditionedBest, conditionedBestCount, conditionedReason = nil, -1, nil
    for i, pair in ipairs(pairList) do
        -- index is the pair's position in Config.findPairs(id) - the compact
        -- token a connected client sends over the net channel (the host
        -- re-derives the pair from its own config at this index)
        local opt = {
            pair = pair,
            index = isPrestige and pair.prestigeIndex or i,
            label = palDisplayName(pair.to),
            prestige = isPrestige,
        }
        -- What this target asks for, short enough for a wheel segment and
        -- phrased the same way the guide pages phrase it. Without this the
        -- wheel names targets and nothing else, so the only way to learn what
        -- an evolution costs was to try it and read the refusal.
        opt.requirement = requirementLine(pair, level, holder)
        local rulePasses = false
        -- Marked further down once the unlock is known, because an entry that is
        -- open only because the Pal earned it once looks identical to a normally
        -- open one otherwise, and the player would read it as the mod ignoring
        -- its own requirement.

        local unknownReason = unknownConditionReason(pair)
        if unknownReason then
            opt.blocked = unknownReason
        elseif isAlpha and not swapTargetId(pair, true) then
            opt.blocked = I18n.msg("noAlphaFormShort", opt.label)
        elseif level < requiredLevelFor(pair) then
            opt.blocked = I18n.msg("needsLevelShort", opt.label, requiredLevelFor(pair), level)
        else
            local condOk, unmet = Conditions.evaluate(pair, condCtx)
            -- A target this Pal has already qualified for once stays reachable,
            -- even now that the condition has passed. Most conditions are
            -- transient, so without this "electrified" is only usable by a
            -- player standing at the wheel in that exact second.
            if not condOk and AutoUnlock.has(param, pair.to) then
                condOk = true
                opt.unlocked = true
                opt.requirement = I18n.msg("unlockedShort", opt.label)
            end
            if not condOk then
                opt.blocked = I18n.msg("needsConditions", opt.label,
                    disclosedConditions(pair, unmet))
            else
                rulePasses = true
                local costList = Costs.resolve(pair, level, holder)
                local costOk, missing = Costs.check(playerCtx, costList)
                if not costOk then
                    opt.blocked = I18n.msg("missingItems",
                        opt.label, Costs.describeMissing(missing))
                end
            end
        end
        if Config.devMode then
            Log(string.format("[radial] %s auto=%s blocked=%s unlocked=%s",
                tostring(opt.label), tostring(pair.autoEvolve),
                tostring(opt.blocked), tostring(opt.unlocked)))
        end
        -- Same-target variants (either/or conditions) collapse into ONE wheel
        -- entry: the first unblocked variant wins its index; while every
        -- variant is blocked the reasons are joined so the player sees all
        -- ways to unlock the target.
        if conditioned then
            if rulePasses and conditionCount(pair) > conditionedBestCount then
                conditionedBest = opt
                conditionedBestCount = conditionCount(pair)
            elseif not rulePasses and not conditionedReason then
                conditionedReason = opt.blocked
            end
        else
            local existing = byTarget[pair.to]
            if not existing then
                byTarget[pair.to] = opt
                table.insert(options, opt)
            elseif existing.blocked and not opt.blocked then
                existing.pair = opt.pair
                existing.index = opt.index
                existing.blocked = nil
                existing.requirement = opt.requirement
            elseif existing.blocked and opt.blocked then
                existing.blocked = existing.blocked .. I18n.msg("orJoiner") .. opt.blocked
            end
        end
    end
    if conditioned then
        if conditionedBest then return { conditionedBest } end
        if conditionedReason then return nil, conditionedReason end
        if isPrestige then return nil, I18n.msg("hasNoPrestige", palDisplayName(id)) end
        return nil, I18n.msg("hasNoEvolution", palDisplayName(id))
    end
    return options
end

-- Authoritative evolve request: re-derives and re-validates EVERYTHING from
-- the requesting player's context; caller-supplied data is only the pair
-- NAMES, never handles. Serves the in-process path (standalone/listen host)
-- and decoded network requests. Returns ok, message.
local function handleEvolveRequest(playerCtx, fromId, toId, exactPairIndex, prestigeRequest)
    if lockBusy() then
        return false, I18n.msg("evolutionRunning")
    end
    if not (playerCtx and playerCtx.pc and playerCtx.pc:IsValid()) then
        return false, "Requesting player unavailable"
    end
    local okAuthority, hasAuthority = pcall(controllerHasAuthority, playerCtx.pc)
    if not okAuthority or not hasAuthority then
        return false, "Evolution requires host authority"
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
    local pairList = nil
    if prestigeRequest then
        -- An enabled ordinary connection is an absolute precedence gate. Its
        -- level or conditions may be unmet, but prestige cannot bypass it.
        if #Config.findPairs(id) > 0 then return false, I18n.msg("optionUnavailable") end
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
            palDisplayName(id), palDisplayName(tostring(toId)))
    end
    local level = 0
    pcall(function() level = param:GetLevel() end)
    local condCtx = { actor = actor, param = param, playerCtx = playerCtx, holder = holder }
    local pair, failReason = nil, nil
    local bestConditionCount = -1
    for _, cand in ipairs(candidates) do
        local unknownReason = unknownConditionReason(cand)
        if unknownReason then
            failReason = failReason or unknownReason
        elseif isAlpha and not swapTargetId(cand, true) then
            failReason = failReason or I18n.msg("noAlphaForm", palDisplayName(cand.to))
        elseif level < requiredLevelFor(cand) then
            failReason = failReason or I18n.msg(
                prestigeRequest and "needsLevelPrestige" or "needsLevel",
                palDisplayName(id), requiredLevelFor(cand), level)
        else
            local condOk, unmet = Conditions.evaluate(cand, condCtx)
            -- The same relaxation listOptions applies when it draws the wheel.
            -- Without it here the entry is offered ungreyed, marked as unlocked,
            -- and then refused on the way in - which is the one situation the
            -- unlock exists to prevent.
            if not condOk and AutoUnlock.has(param, cand.to) then condOk = true end
            if condOk then
                local count = conditionCount(cand)
                if exactPairIndex ~= nil or Config.evolutionMode ~= "conditioned"
                    or count > bestConditionCount then
                    pair = cand
                    bestConditionCount = count
                end
                if exactPairIndex ~= nil or Config.evolutionMode ~= "conditioned" then break end
            end
            failReason = failReason or I18n.msg("needsConditions",
                palDisplayName(cand.to), disclosedConditions(cand, unmet))
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
                palDisplayName(id), level, palDisplayName(pair.to), Costs.describeMissing(missing))
        end
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
    local holder = findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return false, I18n.msg("noPalSummoned") end
    local param = paramOf(actor)
    if not (param and isOwnedBy(param, playerCtx and playerCtx.playerUId)) then
        return false, I18n.msg("noPalSummoned")
    end
    local numericIndex = tonumber(pairIndex)
    if not numericIndex or numericIndex % 1 ~= 0 or numericIndex < 1 or numericIndex > 255 then
        return false, I18n.msg("optionUnavailable")
    end
    local okId, rawId = pcall(characterIdUnsafe, param)
    if not okId then return false, I18n.msg("optionUnavailable") end
    local baseId = baseCharacterId(rawId)
    local pair = nil
    if prestigeRequest then
        -- Global prestige indices address the host's complete target list.
        -- The source check below prevents an index for another Pal from being
        -- replayed against the one the requester currently has summoned.
        if #Config.findPairs(baseId) > 0 then return false, I18n.msg("optionUnavailable") end
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
        if prestigeRequest then return true, I18n.msg("prestigingInto", palDisplayName(pair.to)) end
        return true, I18n.msg("evolvingInto", palDisplayName(pair.to))
    end
    return false, msg
end


handleEvolveByIndex = function(playerCtx, pairIndex)
    return handleByIndex(playerCtx, pairIndex, false)
end

handlePrestigeByIndex = function(playerCtx, targetIndex)
    return handleByIndex(playerCtx, targetIndex, true)
end

-- Executes one option from listOptions - the submenu selection IS the
-- confirmation. Only the pair names travel; the authority re-derives
-- fresh handles and re-validates.
function Evolution.executeOption(opt)
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
    if timersDead() then
        reportDeadTimers(playerCtx)
        if timersGone() then return end
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
            ok, msg = handlePrestigeByIndex(playerCtx, opt.index)
        else
            ok, msg = handleEvolveByIndex(playerCtx, opt.index)
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
    if lockBusy() then return false, I18n.msg("evolutionRunning") end
    local playerCtx = Role.localPlayerCtx()
    if not playerCtx then return false, I18n.msg("noLocalPlayer") end
    local holder = findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return false, I18n.msg("noPalSummoned") end
    local param = paramOf(actor)
    if not (param and isOwnedBy(param, playerCtx.playerUId)) then
        return false, I18n.msg("noPalSummoned")
    end
    local id = baseCharacterId(param:GetCharacterID():ToString())
    local pair = { from = id, to = toId, category = "evolution",
        minLevel = 1, stone = "evolution", enabled = true }
    return performEvolution({ actor = actor, param = param, pair = pair,
        holder = holder, key = individualKey(param), isAlpha = false,
        playerCtx = playerCtx })
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
    -- scaled COLLISION capsule = the engine's grounding measure
    -- (GetSimpleCollisionHalfHeight is not a UFunction in this build)
    pcall(function()
        local cap = actor.CapsuleComponent
        if cap and cap:IsValid() then ohalf = cap:GetScaledCapsuleHalfHeight() end
    end)
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
    -- The finale picks its base layer from this. Read off the pair rather than
    -- passed in, so the client side gets the same answer from the synced tree
    -- without another field on the wire.
    ctx.isPrestige = (pair and pair.category == "prestige") or false
    -- Which prestige programme plays: the Pal's own stage, so the Nth prestige
    -- outdoes the N-1th. Unknown reads as 1 rather than as nothing.
    -- The host's number wins where it is available: the local passive list can
    -- still be the pre-prestige one when this runs on a client.
    ctx.prestigeStage = (pair and tonumber(pair.prestigeStage)) or 1
    if ctx.isPrestige and not (pair and pair.prestigeStage) then
        local probeParam = paramOf(ctx.actor)
        if probeParam then
            local okStages, stages = pcall(PalPassives.resolve, probeParam)
            if okStages and type(stages) == "table" and stages.prestige
                and (stages.prestige.stage or 0) > 0 then
                ctx.prestigeStage = stages.prestige.stage
            end
        end
    end
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
function Evolution.onNetSignal(kind, phaseInfo)
    local playerCtx = Role.localPlayerCtx()
    if not playerCtx then return end
    local holder = findHolderFor(playerCtx, nil)
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
        if remoteRevealBusy and (os.clock() - remoteRevealStart) < 20 then return end
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
        remoteRevealBusy = true
        remoteRevealStart = os.clock()
        remoteCtx = buildRemoteCtx(actor, holder, playerCtx, lastRemotePair)
        local toName = lastRemotePair and palDisplayName(lastRemotePair.to) or "its new form"
        -- The same step by its own name. This line is the only one a client
        -- gets for a host-run step, and it said "evolving" for a prestige too -
        -- the one word the player uses to tell the two apart.
        local startKey = (lastRemotePair and lastRemotePair.category == "prestige")
            and "prestigingInto" or "evolvingInto"
        Role.chat(playerCtx, I18n.msg(startKey, toName))
        pcall(function() playFanfare(actor) end)
        pcall(function() FX.onDissolve(remoteCtx) end)
        -- after the dissolve, start the hold loop and recall the pal
        local dur = 1200
        pcall(function() if FX.dissolveDurationMs then dur = FX.dissolveDurationMs(remoteCtx) end end)
        local done = false
        LoopAsync(dur, function()
            if done then return true end
            done = true
            ExecuteInGameThread(function()
                -- Teardown guard, same reason as the server watcher above:
                -- leaving for the main menu destroys the controller while this
                -- deferred callback is still scheduled, and a UFunction call on
                -- a freed UObject is a native fault that pcall does NOT catch.
                -- Re-resolve instead of trusting the handle captured a full
                -- dissolve ago, and abort the presentation if the world is gone.
                local livePc = Role.getLocalPlayerController()
                if not (livePc and livePc:IsValid()) then
                    if remoteCtx then pcall(function() FX.cleanup(remoteCtx) end) end
                    remoteRevealBusy = false
                    remoteCtx = nil
                    return
                end
                if remoteCtx then pcall(function() FX.onHide(remoteCtx) end) end
                pcall(function() livePc:InactiveOtomo() end)
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
        -- scaled COLLISION capsule for the physics anchor; the mesh-space
        -- body half goes to the FX framing separately
        local nh = nil
        pcall(function()
            local cap = a.CapsuleComponent
            if cap and cap:IsValid() then nh = cap:GetScaledCapsuleHalfHeight() end
        end)
        if not (nh and nh > 0) then nh = 30 end
        pcall(function()
            local mh = staticCapsuleHalf(a)
            if mh and mh > 0 then remoteCtx.meshHalfTo = mh end
        end)
        -- Anchor the finale to where the pal actually stands; leaving
        -- finaleRadius/Za/Zb unset keeps the tight singleplayer default spread.
        pcall(function()
            local loc = a:K2_GetActorLocation()
            remoteCtx.newHalf = nh
            remoteCtx.oldX, remoteCtx.oldY, remoteCtx.oldZ = loc.X, loc.Y, loc.Z
            -- oldZ is now the NEW pal's center - the finale derives its
            -- ground/grown-center anchors from that instead of old-half math
            remoteCtx.centerAnchored = true
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
    local holder = findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return false end
    local param = paramOf(actor)
    if not param then return false end
    return AutoLock.isLocked(param)
end

function Evolution.toggleAutoLock(senderCtx)
    local playerCtx = senderCtx or Role.localPlayerCtx()
    local holder = findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then
        Role.ack(playerCtx, I18n.msg("noPalSummoned"))
        return false
    end
    local param = paramOf(actor)
    if not (param and isOwnedBy(param, playerCtx and playerCtx.playerUId)) then
        Role.ack(playerCtx, I18n.msg("greyNotYours"))
        return false
    end
    return Evolution.runAutoLockCommand(playerCtx, not AutoLock.isLocked(param))
end

function Evolution.runAutoLockCommand(senderCtx, wanted)
    local playerCtx = senderCtx or Role.localPlayerCtx()
    local holder = findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then
        Role.ack(playerCtx, I18n.msg("noPalSummoned"))
        return false
    end
    local param = paramOf(actor)
    if not (param and isOwnedBy(param, playerCtx and playerCtx.playerUId)) then
        Role.ack(playerCtx, I18n.msg("greyNotYours"))
        return false
    end
    local id = baseCharacterId(param:GetCharacterID():ToString())
    local ok = AutoLock.set(param, wanted)
    if not ok then
        Role.ack(playerCtx, I18n.msg("autoLockFailed", palDisplayName(id)))
        return false
    end
    Role.ack(playerCtx, I18n.msg(wanted and "autoLocked" or "autoUnlocked",
        palDisplayName(id)))
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
    if lockBusy() then
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
            m = guidString(p.SaveParameter.OwnerPlayerUId) == last.uid
        end)
        return m
    end
    for _, p in ipairs(all) do
        if p:IsValid() and isOwned(p) and ownerMatches(p)
            and Config.canonicalId(p:GetCharacterID():ToString()) == Config.canonicalId(last.to) then
            -- With a key only the exact match counts (a species fallback could
            -- hit the wrong individual, e.g. SmallYeti->Yeti vs MopKing->Yeti)
            local match = hasKey and (individualKey(p) == last.key) or (not hasKey)
            if match then
                local prestigeAfter = nil
                if last.kind == "prestige" then
                    local prestigeAfterErr
                    prestigeAfter, prestigeAfterErr = capturePrestigeState(p)
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
                    skinAfter, skinAfterErr = captureSkinState(p)
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
                        restoreSwapSurvivors(p, last.skin, last.waza)
                    if not survivorsRestored then
                        Log("ROLLBACK SKIN/MOVE RESTORE FAILED: " .. tostring(survivorRestoreErr))
                        local undoOk, undoErr
                        if prestigeAfter then
                            undoOk, undoErr = restorePrestigeState(p, prestigeAfter)
                        else
                            local speciesOk, speciesErr = pcall(writeSpeciesUnsafe, p, last.to)
                            local passiveOk, passiveErr = PalPassives.restore(p, passivesAfter)
                            undoOk = speciesOk and passiveOk
                            undoErr = tostring(speciesErr) .. "; " .. tostring(passiveErr)
                        end
                        local survivorUndoOk, survivorUndoErr =
                            restoreSwapSurvivors(p, skinAfter, wazaAfter)
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
                            pcall(function()
                                p.SaveParameter[field] = v
                                p.SaveParameterMirror[field] = v
                            end)
                        end
                    end
                    local levelRestored = true
                    if last.kind == "prestige" then
                        local mirrorLevel = last.mirrorLevel
                        if mirrorLevel == nil then mirrorLevel = last.level end
                        local mirrorExp = last.mirrorExp
                        if mirrorExp == nil then mirrorExp = last.exp end
                        local okLevel = pcall(writePrestigeLevelUnsafe, p,
                            last.level, last.exp, mirrorLevel, mirrorExp)
                        local expected = {
                            characterId = last.from,
                            level = last.level,
                            exp = last.exp,
                            mirrorLevel = mirrorLevel,
                            mirrorExp = mirrorExp,
                        }
                        local okFields, fieldsMatch = pcall(prestigeFieldsMatchUnsafe, p, expected)
                        levelRestored = okLevel and okFields and fieldsMatch
                    end
                    if levelRestored then
                        -- mirror the forward path: normalize HP after the
                        -- species/IV/level change (current HP may exceed the
                        -- restored form's maximum otherwise)
                        pcall(function() p:FullRecoveryHP() end)
                        refreshWorkSuitability(p, nil)
                        reverted = true
                        pcall(function() resummonAfterRollback(playerCtx, p) end)
                    elseif prestigeAfter then
                        local undoOk, undoErr = restorePrestigeState(p, prestigeAfter)
                        local survivorUndoOk, survivorUndoErr =
                            restoreSwapSurvivors(p, skinAfter, wazaAfter)
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
                    local undoOk, undoErr = restorePrestigeState(p, prestigeAfter)
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
        table.remove(snapshots, snapIdx)
        local key = "rollbackDone"
        if hadCost then key = refunded and "rollbackDoneRefunded" or "rollbackDoneRefundFailed" end
        say(I18n.msg(key, palDisplayName(last.to), palDisplayName(last.from)))
    elseif restoreFailed then
        say(I18n.msg("rollbackStateRestoreFailed"))
    else
        say(I18n.msg("rollbackNoMatch", palDisplayName(last.to)))
    end
end

-- ---------------------------------------------------------------- auto evolve

-- The scheduler wakes cheaply, but only enters the game thread when the
-- adaptive deadline arrives. This keeps idle ticks free of transient callback
-- registrations while still allowing a half-second condition window near a
-- completed rule set.
local AUTO_SLOW_S = 5.0
local AUTO_FAST_S = 0.5
local AUTO_SCHEDULER_MS = 250
local autoWatchNextAt = 0
local autoWatchQueued = false
local autoOwnershipSkipped = {}
-- Pals already told "two ways are open", so a timer that runs every few seconds
-- does not repeat one line into the chat forever.
local autoHeldTold = {}

local function autoDelayFor(met, total)
    if not total or total <= 0 then return AUTO_SLOW_S end
    local ratio = math.max(0, math.min(1, (tonumber(met) or 0) / total))
    return AUTO_SLOW_S - ((AUTO_SLOW_S - AUTO_FAST_S) * ratio)
end

local function autoCostPasses(playerCtx, pair, level, holder)
    local costList = Costs.resolve(pair, level, holder)
    return Costs.check(playerCtx, costList) == true
end

-- Runs under pcall from scanAutoController. Every direct UObject call in this
-- hot path is therefore inside one named protected callback, with no closure
-- allocated for each controller or condition poll.
local function scanAutoControllerUnsafe(pc)
    if not (pc and pc:IsValid() and pc:HasAuthority()) then return AUTO_SLOW_S, false end
    if pc:IsRiding() == true then return AUTO_SLOW_S, false end

    local playerCtx = Role.playerCtxFor(pc)
    if not playerCtx then return AUTO_SLOW_S, false end
    if not (otomoHolderClass and otomoHolderClass:IsValid()) then
        otomoHolderClass = StaticFindObject("/Script/Pal.PalOtomoHolderComponentBase")
    end
    if not otomoHolderClass then return AUTO_SLOW_S, false end
    local holder = pc:GetComponentByClass(otomoHolderClass)
    if not (holder and holder:IsValid()) then return AUTO_SLOW_S, false end
    local actor = holder:TryGetSpawnedOtomo()
    if not (actor and actor:IsValid()) then return AUTO_SLOW_S, false end
    local param = actor.CharacterParameterComponent:GetIndividualParameter()
    if not (param and param:IsValid()) then return AUTO_SLOW_S, false end

    local owner = param.SaveParameter.OwnerPlayerUId
    local uid = playerCtx.playerUId
    if not uid or (owner.A == 0 and owner.B == 0 and owner.C == 0 and owner.D == 0)
        or not (owner.A == uid.A and owner.B == uid.B
            and owner.C == uid.C and owner.D == uid.D) then
        local palKey = guidString(param.IndividualId.InstanceId)
        if not autoOwnershipSkipped[palKey] then
            autoOwnershipSkipped[palKey] = true
            Log("auto-evolve skipped: the summoned Pal's recorded owner does not match its holder")
        end
        return AUTO_SLOW_S, false
    end

    local id, isAlpha = baseCharacterId(param:GetCharacterID():ToString())
    local level = tonumber(param:GetLevel()) or 0
    local pairList, isPrestige = optionPairsFor(id)
    local bestIndex = nil
    local nextDelay = AUTO_SLOW_S
    local condCtx = { actor = actor, param = param, playerCtx = playerCtx, holder = holder }

    -- A Pal the player has locked is left alone entirely: no scan, no unlock.
    if AutoLock.isLocked(param) then return AUTO_SLOW_S, false end

    -- EVERY ready candidate is collected, not the first one. The old loop broke
    -- out on the first match in `selected` mode, so which of several possible
    -- evolutions fired came down to their order in the config - an order nobody
    -- sets on purpose and the editor does not show.
    local ready = {}
    for i, pair in ipairs(pairList) do
        if pair.autoEvolve == true and not unknownConditionReason(pair)
            and level >= requiredLevelFor(pair)
            and not (isAlpha and not swapTargetId(pair, true)) then
            local met, total = Conditions.progress(pair, condCtx)
            nextDelay = math.min(nextDelay, autoDelayFor(met, total))
            if met == total then
                local okCost, affordable = pcall(autoCostPasses,
                    playerCtx, pair, level, holder)
                if okCost and affordable then
                    ready[#ready + 1] = {
                        index = isPrestige and pair.prestigeIndex or i,
                        pair = pair,
                    }
                end
            end
        end
    end

    -- More than one way is open at this very moment, so nothing fires on its
    -- own: picking for the player is how a Pal ends up as the form they did not
    -- want. Each of them is unlocked instead, which makes it available from the
    -- wheel from now on - the point being that most conditions are transient,
    -- and "electrified" is otherwise only reachable if the player happens to be
    -- at the wheel in that second.
    if #ready > 1 then
        for _, entry in ipairs(ready) do
            AutoUnlock.remember(param, entry.pair)
        end
        -- Nothing happening is the whole point here, and nothing happening is
        -- indistinguishable from the feature never running. Both the player and
        -- the log are told, or the next report is "auto-evolve does nothing".
        -- Once per Pal per stretch, not once per scan: this runs on a timer.
        local heldKey = guidString(param.IndividualId.InstanceId)
        if not autoHeldTold[heldKey] then
            autoHeldTold[heldKey] = true
            Log(string.format("auto-evolve held: '%s' has %d ways open at once", id, #ready))
            Role.chat(playerCtx, I18n.msg("autoEvolveHeld", palDisplayName(id)))
        end
        return nextDelay, false
    end
    if #ready == 1 then
        -- Cleared here and nowhere else. A condition that lapses puts the Pal
        -- back at nothing-to-do, and clearing there would let a pair of
        -- flickering conditions re-announce the same hold every few seconds.
        -- One evolution is the event that makes the next hold a new one.
        autoHeldTold[guidString(param.IndividualId.InstanceId)] = nil
        bestIndex = ready[1].index
    end

    if bestIndex then
        local started
        if isPrestige then
            started = handlePrestigeByIndex(playerCtx, bestIndex)
        else
            started = handleEvolveByIndex(playerCtx, bestIndex)
        end
        return nextDelay, started == true
    end
    return nextDelay, false
end

-- One line per distinct failure and never again, not one per scan: this runs
-- every few hundred milliseconds per player, so an unfiltered log would bury
-- everything else. Silence is not the alternative - a scan that throws on its
-- first call looks exactly like a scan that never finds anything ready.
local autoScanFailures = {}

local function scanAutoController(pc)
    local ok, delay, started = pcall(scanAutoControllerUnsafe, pc)
    if not ok then
        local reason = tostring(delay)
        if not autoScanFailures[reason] then
            autoScanFailures[reason] = true
            Log("auto-evolve scan failed: " .. reason)
        end
        return AUTO_SLOW_S, false
    end
    return delay or AUTO_SLOW_S, started == true
end

local function runAutoWatcherUnsafe()
    autoWatchQueued = false
    local nextDelay = AUTO_SLOW_S
    if not Config.autoEvolve or sequenceRunning then
        autoWatchNextAt = os.clock() + nextDelay
        return
    end
    local controllers = FindAllOf("PalPlayerController") or {}
    for _, pc in ipairs(controllers) do
        local delay, started = scanAutoController(pc)
        nextDelay = math.min(nextDelay, delay)
        if started then break end
    end
    autoWatchNextAt = os.clock() + nextDelay
end

local function runAutoWatcher()
    local ok, err = pcall(runAutoWatcherUnsafe)
    autoWatchQueued = false
    if not ok then
        autoWatchNextAt = os.clock() + AUTO_SLOW_S
        if Config.devMode then Log("auto-evolve watcher failed: " .. tostring(err)) end
    end
end

local function autoWatcherLoop()
    if autoWatchQueued or os.clock() < autoWatchNextAt then return false end
    autoWatchQueued = true
    local ok = pcall(ExecuteInGameThread, runAutoWatcher)
    if not ok then
        autoWatchQueued = false
        autoWatchNextAt = os.clock() + AUTO_SLOW_S
    end
    return false
end

local function startAutoWatcher()
    if not Config.autoEvolve then return end
    autoWatchNextAt = 0
    local ok, err = pcall(LoopAsync, AUTO_SCHEDULER_MS, autoWatcherLoop)
    if not ok then Log("auto-evolve watcher failed to start: " .. tostring(err)) end
end

function Evolution.init()
    loadSnapshots()
    local conditionsOk, conditionsErr = pcall(Conditions.init)
    if not conditionsOk then Log("condition hooks failed to initialize: " .. tostring(conditionsErr)) end
    startAutoWatcher()

    -- authority entry for in-process and network requests
    Authority.bind({ evolve = handleEvolveRequest })

    -- host side of the net channel: decode connected-client evolve requests
    -- and run them through the fully-revalidating index handler. The hook
    -- fires only where the game routes _ToServer RPCs (the authority); on a
    -- pure client it registers but never fires.
    NetChannel.initHost(function(senderCtx, request)
        local pairIndex = type(request) == "table" and request.index or request
        local opcode = type(request) == "table" and request.opcode or NetChannel.OP_EVOLVE_LEGACY
        if opcode == NetChannel.OP_PRESTIGE then
            return handlePrestigeByIndex(senderCtx, pairIndex)
        end
        if opcode == NetChannel.OP_AUTOLOCK then
            -- senderCtx is the requesting player resolved on this side, so the
            -- lock is written on the host's own Pal, by the player who owns it.
            -- toggleAutoLock reads the current state here, where it is true.
            return Evolution.toggleAutoLock(senderCtx)
        end
        return handleEvolveByIndex(senderCtx, pairIndex)
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
                    if not isOwnedBy(param, localCtx.playerUId) then return end
                    local id, isAlpha = baseCharacterId(param:GetCharacterID():ToString())
                    local pair = nil
                    for _, cand in ipairs(Config.findPairs(id)) do
                        if not unknownConditionReason(cand)
                            and not (isAlpha and not swapTargetId(cand, true)) then
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
                        local conds = Conditions.describe(pair, Config.conditionDisclosure)
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
                    local holder = findHolderFor(playerCtx, nil)
                    if not step("holder", holder ~= nil) then return end
                    local actor = nil
                    pcall(function() actor = holder:TryGetSpawnedOtomo() end)
                    if not step("actor", actor and actor:IsValid() or false) then return end
                    local param = paramOf(actor)
                    if not step("param", param ~= nil) then return end
                    step("owned", isOwnedBy(param, playerCtx and playerCtx.playerUId))
                    -- raw on purpose: this line exists to show the spelling
                    -- the session reported next to the one the mod resolved
                    local raw = param:GetCharacterID():ToString()
                    local id, isAlpha = baseCharacterId(raw)
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
                -- Honesty over promises: the player statistics keep crafted and
                -- picked-up mod item names, live only as replicated FastArrays
                -- no Lua can touch. A world that ever USED the mod therefore
                -- stays dependent on the PalSchema data folder - the command
                -- cleans everything reachable and says exactly that.
                if #locations == 0 and #benches == 0 and techOk then
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

return Evolution
