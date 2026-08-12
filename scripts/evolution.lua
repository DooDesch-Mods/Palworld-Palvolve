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
local ServerCheck = require("servercheck")

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

local function loadSnapshots()
    snapshots = {}
    -- Start the file over so old entries cannot be mistaken for this session's.
    -- The file exists from the second launch onwards, so its mere presence says
    -- nothing; only a file with entries in it means something was discarded.
    local existed, hadEntries = false, false
    pcall(function()
        local f = io.open(STATE_FILE, "r")
        if not f then return end
        existed = true
        local body = f:read("*a") or ""
        f:close()
        hadEntries = body:find("{ key =", 1, true) ~= nil
    end)
    if existed then
        pcall(function()
            local f = io.open(STATE_FILE, "w")
            if f then f:write("return {\n}\n"); f:close() end
        end)
    end
    if hadEntries then
        Log("Rollback restore points from earlier sessions discarded - rollback covers this session")
    end
end

local function saveSnapshots()
    local ok, err = pcall(function()
        local f = assert(io.open(STATE_FILE, "w"))
        f:write("return {\n")
        for _, s in ipairs(snapshots) do
            local cost = ""
            for _, c in ipairs(s.cost or {}) do
                -- floored: material counts come from the user config verbatim,
                -- and "%d" on a non-integer number raises rather than rounding
                cost = cost .. string.format("{ id = %q, count = %d }, ",
                    c.id, math.floor(tonumber(c.count) or 0))
            end
            f:write(string.format(
                "  { key = %q, from = %q, to = %q, level = %d, nickname = %q, ivHP = %d, ivMelee = %d, ivShot = %d, ivDefense = %d, uid = %q, cost = { %s} },\n",
                s.key or "", s.from, s.to, s.level, s.nickname or "",
                s.ivHP or -1, s.ivMelee or -1, s.ivShot or -1, s.ivDefense or -1,
                s.uid or "", cost))
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

-- A pal's work suitability comes from a cache built when the individual parameter is
-- constructed, so after a species swap it still describes the old form. Every write path
-- into that cache was ruled out, which is why the native companion fixes the READ instead.
--
-- Two reads matter and they are separate. The Team and Palbox screens go through the
-- reflected getters, so those are post-hooked. The base camp does not: it reaches the pal
-- through a direct C++ call that never passes ProcessEvent, and that one needs an inline
-- hook on the method itself. Without the companion nothing happens here and the values
-- update on the next reload, which is the behaviour this shipped with before.
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
    -- First target that only lacks materials, kept as the fallback: if nothing
    -- is affordable, its missing list is the useful thing to report.
    local unpaid, unpaidIndex = nil, nil
    for i, cand in ipairs(pairList) do
        if isAlpha and not swapTargetId(cand, true) then
            alphaBlockedTo = alphaBlockedTo or cand.to
        elseif level < cand.minLevel then
            firstReason = firstReason or I18n.msg("needsLevel", palDisplayName(id), cand.minLevel, level)
        else
            local condOk, unmet = Conditions.evaluate(cand, condCtx)
            if condOk then
                -- The cost belongs in this loop. Checked only afterwards, a
                -- species whose first target lacks a stone reported that stone
                -- and never mentioned the target the player could pay for.
                local affordable = true
                pcall(function()
                    affordable = (Costs.check(playerCtx, Costs.resolve(cand, level, holder)))
                end)
                if affordable then
                    pair = cand
                    pairIndex = i
                    break
                end
                if not unpaid then unpaid, unpaidIndex = cand, i end
            else
                firstReason = firstReason or I18n.msg("needsConditions", palDisplayName(cand.to), unmet)
            end
        end
    end
    if not pair and unpaid then
        pair, pairIndex = unpaid, unpaidIndex
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
        local okSwap, errSwap = pcall(function()
            param.SaveParameter.CharacterID = FName(targetId)
            param.SaveParameterMirror.CharacterID = FName(targetId)
        end)
        local idNow = ""
        pcall(function() idNow = param:GetCharacterID():ToString() end)
        -- Compare the read-back through the canonicalizer: the name just
        -- written can come back under a spelling the engine registered
        -- earlier, and a raw comparison would treat a swap that worked as a
        -- failure and refund it.
        if not okSwap or Config.canonicalId(idNow) ~= Config.canonicalId(targetId) then
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
        refreshWorkSuitability(param, playerCtx, actor, pair.from)

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
        saveSnapshots()
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
    local actor, param, pair, level, holder, isAlpha, pairIndex = findEligibleFor(playerCtx)
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
        local reason = I18n.msg("couldEvolveMissing",
            palDisplayName(pair.from), level, palDisplayName(pair.to), Costs.describeMissing(missing))
        Log(reason)
        if Role.hasWorldAuthority() then
            -- authority (single player / host): this check is final, show it here
            Role.chat(playerCtx, reason, "reply")
        elseif remoteTransmitReady(playerCtx) then
            -- pure client: emitting the reason locally would attribute it to the
            -- player ("[Name]: ..."). Send the request instead so the host rejects
            -- it and delivers the reason as a private [SYSTEM] line; the host
            -- re-checks and consumes nothing on a rejected evolve.
            NetChannel.sendEvolve(playerCtx, pairIndex or 0)
        end
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
                if not remoteTransmitReady(playerCtx) then return end
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

-- Reason the radial entry was last greyed, or nil while it was offered. canOffer
-- runs on every wheel rebuild, so the reason is written only when it CHANGES -
-- logging every call would put one line per frame in the file. Logging nothing
-- is worse: "not your pal", "nothing configured for this species" and "host not
-- confirmed" produce the same grey entry and are otherwise indistinguishable.
local lastOfferReason = nil

-- Player-facing half of the verdict. The log line names the cause for support;
-- this names it for the person looking at a grey entry, who otherwise gets
-- nothing to act on. One line per distinct cause per session: canOffer runs on
-- every wheel rebuild, so anything less selective would be chat spam.
local toldReasons = {}
local function tellPlayer(msg)
    if not msg or toldReasons[msg] then return end
    toldReasons[msg] = true
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
    return reason
end

-- Light-weight availability for the radial label: an owned pal is
-- summoned and has at least one configured option. Level and costs are
-- only checked in the submenu - this runs on every wheel rebuild.
function Evolution.canOffer()
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
        local n = #Config.findPairs(id)
        if n == 0 then
            return string.format("no enabled pair configured for '%s'", id),
                I18n.msg("hasNoEvolution", palDisplayName(id))
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
    local minLevel = tonumber(pair.minLevel) or 0
    if minLevel > 0 then wrapText(I18n.msg("guideLevelShort", minLevel), CENTER_WIDTH, lines) end

    local cond = Conditions.describe(pair)
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
        -- What this target asks for, short enough for a wheel segment and
        -- phrased the same way the guide pages phrase it. Without this the
        -- wheel names targets and nothing else, so the only way to learn what
        -- an evolution costs was to try it and read the refusal.
        opt.requirement = requirementLine(pair, level, holder)
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
            NetChannel.sendEvolve(playerCtx, opt.index or 0)
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
        local ok, msg = handleEvolveRequest(playerCtx, opt.pair.from, opt.pair.to)
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
        local sent = NetChannel.sendEvolve(playerCtx, opt.index or 0)
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
                pcall(function()
                    p.SaveParameter.CharacterID = FName(last.from)
                    p.SaveParameterMirror.CharacterID = FName(last.from)
                end)
                local idNow = ""
                pcall(function() idNow = p:GetCharacterID():ToString() end)
                if Config.canonicalId(idNow) == Config.canonicalId(last.from) then
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
                    refreshWorkSuitability(p, nil)
                    reverted = true
                    pcall(function() resummonAfterRollback(playerCtx, p) end)
                end
                break
            end
        end
    end
    if reverted then
        -- Give the price back: the evolution is undone, so keeping the stones
        -- would charge for something that no longer happened. Only after the
        -- restore actually succeeded, and only what this evolution recorded.
        local refunded = false
        pcall(function()
            if last.cost and #last.cost > 0 then
                refunded = Costs.refund(playerCtx, last.cost)
                Log(refunded and ("Rollback refunded: " .. Costs.describe(last.cost))
                    or "Rollback refund PARTIALLY FAILED - please report")
            end
        end)
        table.remove(snapshots, snapIdx)
        saveSnapshots()
        say(I18n.msg(refunded and "rollbackDoneRefunded" or "rollbackDone",
            palDisplayName(last.to), palDisplayName(last.from)))
    else
        say(I18n.msg("rollbackNoMatch", palDisplayName(last.to)))
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
    end, ServerCheck.onPong)

    -- keybinds are player input - meaningless on a dedicated server
    if not Role.isDedicated() and Config.confirmKeyEnabled ~= false then
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
            -- work suitability experiment E0: writes an add-rank on the summoned
            -- pal and reports whether the getters the Team and Palbox screens
            -- read move with it. Run right after an evolution.
            worksuit = function(senderCtx)
                if not Config.devMode then return end
                local okProbes, probes = pcall(require, "probes")
                if not (okProbes and probes.probeWorkSuitability) then return end
                probes.probeWorkSuitability()
                Role.ack(senderCtx, "work suitability probe done - see log")
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
            help = function(senderCtx)
                Role.ack(senderCtx, I18n.msg("helpLine"))
            end,
        })
        if okCmd then Log("Chat commands active: !palvolve rollback") end
    end)

    -- The banner has to say what is actually bound: the key is off unless the
    -- player asks for it, and a log that promises F2 sends the next support
    -- case chasing a key that was never claimed.
    if Role.isDedicated() or Config.confirmKeyEnabled == false then
        Log("Evolution core active: wheel (hold 4), chat: !palvolve rollback")
    else
        Log(string.format("Evolution core active: %s = check/confirm, chat: !palvolve rollback",
            Config.confirmKey))
    end
end

return Evolution
