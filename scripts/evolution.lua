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

-- In-game options (Mod Options Framework). Its generation check has to ride an
-- event we ALREADY own - the framework's API forbids a watcher loop for it and
-- the house rules forbid a new LoopAsync - so ModOptions.pump() sits at the top
-- of the three pollers below. Optional module, loaded defensively: a missing or
-- broken modoptions.lua must not cost the core a single feature.
local ModOptions
do
    local okMO, mo = pcall(require, "modoptions")
    ModOptions = (okMO and type(mo) == "table") and mo or nil
end

local Evolution = {}

-- DarnToasts integration (darntoasts.lua): richer HUD toasts and one sticky
-- progress panel when that framework is installed, and nothing at all when it
-- is not. Parked on the module table instead of a chunk local ON PURPOSE:
-- this file sits at 175 of Lua's 200 top-level locals per chunk, and every
-- notification site below (announce, flavor, rollback, the sequence stages)
-- needs the same upvalue. The stub keeps every call site guard-free - the
-- module itself is what decides whether anything is shown.
do
    local okDT, dt = pcall(require, "darntoasts")
    Evolution.Toasts = (okDT and type(dt) == "table") and dt or {
        available = function() return false end,
        notify = function() return false, false end,
        progressBegin = function() return false end,
        progressUpdate = function() return false end,
        progressEnd = function() return false end,
    }
end

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
    return path or "ue4ss\\Mods\\Palvolve-Fork\\palvolve_state.lua"
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

-- Catch-gated technologies (saddles, Pal gear) unlock when a species is CAPTURED, not when
-- its CharacterID changes - so an evolved form stays locked. The capture record lives in
-- replicated FastArrays that UE4SS-Lua cannot map; the native companion (dlls/main.dll)
-- sets it through the game's own _ForServer setters.
--
-- FORK: `who` is either a playerCtx (the manual / net / auto paths, which always
-- have the requesting controller) or an owner uid STRING. The base-camp sweep
-- only ever holds the latter - it commits a species swap for a pal whose owner
-- may be offline and has no controller at all - and it must unlock the same
-- technologies the identical pair unlocks through F2, or the same evolution
-- would leave the saddle craftable or not depending on which path produced it.
--
-- The companion's API grew a THIRD parameter (playerStateName) for dedicated
-- servers, where the PlayerState uid this process replicated can be empty or
-- stale: named the state OBJECT, the native side reads the uid off the
-- authority's own object instead of trusting ours. Both still travel - it
-- prefers the state and falls back to the uid - and the extra argument is
-- harmlessly ignored by the OLD companion build, which is the one a fork
-- install may still be carrying. So nothing here may assume the new resolution
-- happened: the uid stays the primary identity on every path.
local unlockCatchTech
do
    local nativeMissingLogged = false
    -- Keyed by player, not a single flag: on a dedicated server one shared flag would
    -- let the first player to hit a failure consume the notice for everyone else.
    local techUnlockNoticeSent = {}

    -- An unset uid reads as all zeros ("00000000-..."), which is not an identity at
    -- all: it matches no record, and handing it over as an authoritative player would
    -- point the unlock at whatever the native resolves for a blank guid. Treated
    -- exactly like "no uid" - the fork's proven nil, which the companion reads as
    -- "the player who asked".
    local function isZeroUidString(s)
        return s == nil or s == "" or s:match("^[0%-]+$") ~= nil
    end

    function unlockCatchTech(targetId, who)
        if not Config.unlockCatchTech then return end

        -- Without the companion the evolution itself is unaffected: skip quietly, note it once.
        if type(PalvolveNative_UnlockCaptureRecord) ~= "function" then
            if not nativeMissingLogged then
                nativeMissingLogged = true
                Log("Native companion missing - catch-gated technologies stay locked for this session")
            end
            return
        end

        local uid, playerCtx
        if type(who) == "string" then
            uid = who
        else
            playerCtx = who
            pcall(function()
                if playerCtx and playerCtx.playerUId then uid = guidString(playerCtx.playerUId) end
            end)
        end
        if isZeroUidString(uid) then
            if not playerCtx then
                -- bare-uid caller (base sweep) with a zeroed owner: an
                -- UNADDRESSED unlock would land on whichever player the
                -- companion resolves by default - the exact outcome the base
                -- call site forbids. Skip the call outright (review catch);
                -- only a ctx-bearing caller may fall through to nil, where
                -- the companion resolves identity from the state name.
                Log(string.format(
                    "Catch-tech unlock skipped for %s: owner uid is zero",
                    tostring(targetId)))
                return
            end
            uid = nil
        end

        -- Only the playerCtx paths can name a PlayerState; the base sweep holds a bare
        -- uid for an owner who may not be in the process at all. Empty string = "not
        -- given", the value the companion expects when the caller has no state to name.
        local stateName = ""
        pcall(function()
            local ps = playerCtx and playerCtx.playerState
            if ps and ps:IsValid() then stateName = ps:GetFName():ToString() end
        end)

        local called, ok, msg = pcall(PalvolveNative_UnlockCaptureRecord, targetId, uid, stateName)
        if not called then
            Log(string.format("Catch-tech unlock errored for %s: %s", tostring(targetId), tostring(ok)))
            -- the errored branch earns the notice too (review catch): if a
            -- future companion rejects an argument shape outright, the player
            -- must still hear about the lost unlock - same one-shot gating as
            -- the skipped branch below
            local noticeKey = uid or "unresolved"
            if playerCtx and not techUnlockNoticeSent[noticeKey] then
                techUnlockNoticeSent[noticeKey] = true
                pcall(function() Role.chat(playerCtx, I18n.msg("techUnlockFailed")) end)
            end
        elseif ok then
            Log(string.format("Catch-tech unlocked for %s (%s)", tostring(targetId), tostring(msg)))
        else
            Log(string.format("Catch-tech unlock skipped for %s: %s", tostring(targetId), tostring(msg)))
            -- Species that share a Paldeck slot with their base (Gumoss Botan) have no
            -- own EPalTribeID, so the game keeps no capture record for them and there
            -- are no catch-gated recipes to unlock. Nothing is wrong there, so the
            -- player is not asked to report it - unlike a missing enum, which breaks
            -- every species and does count as a failure. The companion distinguishes
            -- the two in its message.
            local noRecordSlot = type(msg) == "string"
                and msg:find("no EPalTribeID entry", 1, true) ~= nil
            -- The evolution itself worked, so a real failure costs the player one
            -- private line per session; without it it only ever reaches the log. The
            -- base sweep has nobody to tell (offline owner, no controller), so it
            -- never burns the one-shot the same player's F2 evolution still needs.
            local noticeKey = uid or "unresolved"
            if playerCtx and not noRecordSlot and not techUnlockNoticeSent[noticeKey] then
                techUnlockNoticeSent[noticeKey] = true
                pcall(function() Role.chat(playerCtx, I18n.msg("techUnlockFailed")) end)
            end
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
-- Alpha character ids are the base id under this prefix. Declared here (rather
-- than beside baseCharacterId/alphaTargetId further down) because the evolution
-- prompt below needs it to name an alpha's target species.
local BOSS_PREFIX = "BOSS_"

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

-- Exported for the guide pages, which name every species in the configured tree
-- and must read the same localized names the wheel shows - a second lookup route
-- would drift the moment one of them gained a fallback the other lacks. Thin
-- wrapper only: the cache and the world-not-ready retry stay here.
function Evolution.displayName(id)
    return palDisplayName(id)
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

-- ---------------------------------------------------------------- evolution prompt

-- FText from a Lua string. UE4SS resolves the engine converter behind FText()
-- once per session; if that first lookup ran before init it stays broken, so
-- fall back to the engine's own string->text converter for a fresh lookup.
-- Deliberately duplicated per module (servercheck.lua:67 is the original).
local function toText(s)
    local ok, t = pcall(FText, s)
    if ok and t then return t end
    local converted = nil
    pcall(function()
        local ktl = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        if ktl and ktl:IsValid() then converted = ktl:Conv_StringToText(s) end
    end)
    return converted
end

-- Which surface actually carried the first prompt of the session. Logged
-- unconditionally once (a devMode-only proof line proves nothing on a user's
-- machine); every later outcome is devMode-only so the log stays quiet.
local notifyProofDone = false
local function notifyProof(surface)
    if notifyProofDone and not Config.devMode then return end
    notifyProofDone = true
    Log("[notify] evolution prompt delivered via " .. surface)
end

-- The game's OWN notice stream for the player sitting at THIS machine:
-- UPalLogManager::AddLog (PalLogManager.h:90-91), the surface vanilla uses for
-- "you caught a Pal" style lines. Free-form FText, so it can carry the
-- sentence; FText is mandatory here (the FString-taking chat surfaces crash
-- natively on FText userdata - role.lua:134-135 - so never cross the two).
--
-- Returns true when the log manager ACCEPTED the line - which is emphatically
-- not "the player saw something". The widget is instantiated Blueprint-side by
-- whatever subscribes to OnAddedImportantLogDelegate (PalLogManager.h:63); no
-- reflected C++ path drives or observes it, so rendering cannot be verified from
-- here at all. That is why the caller does not treat a true return as coverage:
-- the chat line rides along by default rather than only on failure.
--
-- DarnToasts REPLACES this surface when the integration is live: one
-- evolution gets one notice, never two, so the AddLog attempt below is
-- skipped entirely whenever the channel accepted the line. A loaded but MUTED
-- channel counts as accepted - the player muted the Palvolve lane on the
-- Toasts page, and quietly re-drawing the same sentence through the vanilla
-- feed would defeat exactly the setting they just changed. A channel that is
-- absent, switched off, or that raises falls through to AddLog unchanged.
-- The second return value names the surface for the proof line.
local function localEvolutionToast(ownerCtx, msg, toId)
    if Evolution.Toasts.available() then
        local handled, muted = Evolution.Toasts.notify(msg)
        if muted then return true, "DarnToasts (muted - notice suppressed)" end
        if handled then return true, "DarnToasts toast" end
    end
    local shown = false
    pcall(function()
        local pc = ownerCtx and ownerCtx.pc
        local util = palUtility()
        if not (util and pc and pc:IsValid()) then return end
        local mgr = util:GetLogManager(pc)
        if not (mgr and mgr:IsValid()) then return end
        local text = toText(msg)
        if not text then return end
        -- EPalLogContentToneType::Positive = 2 (EPalLogContentToneType.h:
        -- Normal, Negative, Positive)
        local data = { logToneType = 2 }
        -- Portrait of the new species, best-effort only: the helper takes the
        -- struct as UPARAM(Ref) (PalLogUtility.h:43-44) and a Lua-table
        -- round-trip through an out-param is unproven in this build, so it gets
        -- its OWN pcall - a failure (or a silent no-write) must never cost us
        -- the prompt itself, which then simply renders without an icon.
        pcall(function()
            local lu = StaticFindObject("/Script/Pal.Default__PalLogUtility")
            if lu and lu:IsValid() and toId then
                lu:SetTextureToAdditionalDataFromCharacterID(pc, data, FName(toId))
            end
        end)
        -- EPalLogPriority::Important = 2 (EPalLogPriority.h: None, Normal,
        -- Important, VeryImportant)
        local guid = mgr:AddLog(2, text, data)
        -- AddLog returns the new entry's FGuid. A zero guid means the manager
        -- refused the line - the one cheap signal on offer, so read it instead of
        -- discarding the return. An unreadable guid is treated as accepted (no
        -- regression on builds where the struct does not marshal back).
        local zero = false
        pcall(function()
            if guid ~= nil then
                zero = (guid.A == 0 and guid.B == 0 and guid.C == 0 and guid.D == 0)
            end
        end)
        shown = not zero
    end)
    return shown, shown and "toast (queued)" or "the log manager"
end

-- Message key per context, plus the English template as the last line of
-- defence. These prompt keys were hand-added to i18n_static.lua's `en` catalog
-- (which is GENERATED from Palvolve-Web/pipeline/mod-messages.json, a repo that
-- is not part of this workspace). If that file is regenerated before the keys
-- land upstream, I18n.msg finds no template and returns the KEY - the notice
-- feed would read a literal "evolvedPrompt". promptMsg catches exactly that and
-- formats the English sentence instead, so the worst case is untranslated text,
-- never a debug token. Non-en locales fall back to English per key today, the
-- same as adaptationTag/statusEvolveHeader/cancelWithdrawn before them.
local PROMPT_KEYS = {
    party = "evolvedPrompt",
    base = "evolvedPromptBase",
    resummon = "evolvedNeedsResummon",
}
local PROMPT_FALLBACK = {
    evolvedPrompt = "%s evolved into %s! (Lv %s)",
    evolvedPromptBase = "Base pal %s evolved into %s! (Lv %s)",
    evolvedNeedsResummon = "%s evolved into %s - if it did not reappear, resummon it to see the new form",
    evolvingFlavor = "What's this? %s is evolving?",
    adaptingFlavor = "What's this? %s is adapting to its environment!",
}
local function promptMsg(key, ...)
    local s = I18n.msg(key, ...)
    if s == key then
        local ok, formatted = pcall(string.format, PROMPT_FALLBACK[key] or key, ...)
        if ok then return formatted end
    end
    return s
end

-- ONE emit for every owned-pal evolution, whoever owns it and wherever they
-- are. kind = "party" (the player's own pal: manual F2, radial, auto-evolve,
-- and the same paths driven by a remote requester), "base" (a camp worker) or
-- "resummon" (a POST-commit reveal failure: the species did change, but no actor
-- came back, so the success line already read has to be qualified).
-- ownerCtx must already be resolved by the caller - the base path resolves it
-- from the pal's stored owner uid, the party paths carry the requester's ctx -
-- and nil is a legitimate value (base pal whose owner is not in this process),
-- in which case the evolution is recorded in the log alone.
--
-- Surface contract, deliberately IDENTICAL for a local and a remote owner:
--   enabled = false        -> UE4SS log only, nothing on screen anywhere
--   chatFallback = true    -> notice toast AND the private chat line (default)
--   chatFallback = false   -> toast attempt only; log alone if it does not land
-- The chat line is not conditional on the toast failing, because "the toast
-- failed" is not observable: AddLog returning a live guid only means the entry
-- was queued (localEvolutionToast above). Without it, a build whose Blueprint
-- side never spawns the widget would leave the owner with ZERO surfaces - and on
-- the base path that would have been a regression, since 1.6.0 always chatted.
-- The cost of the guarantee is one duplicated sentence for players who do see
-- the toast, which chatFallback = false turns off - on both paths now, where it
-- used to be silently ignored for remote owners.
local function announceEvolution(ownerCtx, fromId, toId, level, kind)
    -- An alpha's swap target is BOSS_<species>, which the localized name table
    -- has no row for; name the species (the game marks alphas separately). The
    -- portrait stamp still gets the raw id, which is the real CharacterID.
    local function nameOf(id)
        local s = tostring(id or "")
        if s:sub(1, #BOSS_PREFIX) == BOSS_PREFIX then s = s:sub(#BOSS_PREFIX + 1) end
        return palDisplayName(s)
    end
    -- level is config-derived on some paths: never %d
    local lvl = math.floor(tonumber(level) or 0)
    local msg = promptMsg(PROMPT_KEYS[kind] or PROMPT_KEYS.party,
        nameOf(fromId), nameOf(toId), string.format("%g", lvl))
    local off = not Config.evolveNotify or Config.evolveNotify.enabled == false
    local remote = (ownerCtx ~= nil) and (ownerCtx.isLocal ~= true)
    local wantChat = (not off) and (Config.evolveNotify.chatFallback ~= false)
    -- The plain log line always happens - it is the record of the evolution
    -- even with prompts switched off. Role.notify logs the same sentence
    -- itself, so the remote path skips it here instead of printing it twice.
    if off or not remote then Log(msg) end
    if off then return end
    if ownerCtx == nil then return end
    if remote then
        -- the owner's own client renders the toast from the relayed payload;
        -- wantChat decides whether the private chat line rides along (that flag
        -- was unreachable from Role.notify before, so it always did)
        Role.notify(ownerCtx, msg, wantChat)
        notifyProof(wantChat and "relay + private chat" or "relay only")
        return
    end
    -- surface is whichever notice surface actually took the line (DarnToasts
    -- when the integration is live, the game's log manager otherwise), so the
    -- proof line stays true for both and a support log says which one ran
    local toasted, surface = localEvolutionToast(ownerCtx, msg, toId)
    if wantChat then Role.chat(ownerCtx, "[Palvolve] " .. msg) end
    if toasted and wantChat then
        notifyProof(surface .. " + chat")
    elseif toasted then
        notifyProof(surface .. "; chatFallback off")
    elseif wantChat then
        notifyProof("chat only (" .. surface .. " refused the line)")
    else
        notifyProof("log only")
    end
end

-- The pre-sequence flavor beat (evolveNotify.flavorLine): "What's this? X is
-- evolving?" lands the moment an evolution is committed, flavorLeadMs before
-- the dissolve starts (startEvolutionWithFlavor, below performEvolution,
-- owns the pause). Adaptation pairs get their own sentence - the pair's
-- CATEGORY decides, not the stone it charges (the v1.5.0 rule). The portrait
-- is the CURRENT species: nothing has changed yet, that is the point of the
-- beat. Same surface contract as announceEvolution: relay for a remote
-- owner, toast + optional chat locally, nothing anywhere when prompts are
-- off - and nothing when flavorLine alone is off.
local function announceFlavor(ownerCtx, pair, portraitId)
    local en = Config.evolveNotify
    if not en or en.enabled == false or en.flavorLine == false then return end
    local fromId = tostring(pair and pair.from or "")
    if fromId:sub(1, #BOSS_PREFIX) == BOSS_PREFIX then
        fromId = fromId:sub(#BOSS_PREFIX + 1)
    end
    local key = (pair and pair.category == "adaptation")
        and "adaptingFlavor" or "evolvingFlavor"
    local msg = promptMsg(key, palDisplayName(fromId))
    local remote = (ownerCtx ~= nil) and (ownerCtx.isLocal ~= true)
    local wantChat = en.chatFallback ~= false
    -- Role.notify logs the sentence itself; log here only on the local path
    if not remote then Log(msg) end
    if ownerCtx == nil then return end
    if remote then
        Role.notify(ownerCtx, msg, wantChat)
        return
    end
    -- portrait follows announceEvolution's contract: the RAW id (an alpha's
    -- BOSS_ form) is the real CharacterID the portrait helper resolves - and
    -- the DarnToasts routing rides along with it, since the whole surface
    -- decision (channel, mute, vanilla fallback) lives inside that one helper
    localEvolutionToast(ownerCtx, msg, portraitId or (pair and pair.from) or nil)
    if wantChat then Role.chat(ownerCtx, "[Palvolve] " .. msg) end
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

-- Recalls and re-summons the pal after a rollback so the MODEL follows the
-- species back. The parameter write alone is invisible: a spawned actor keeps
-- the mesh it was built with, so without this the player has to recall the pal
-- by hand to see the restored form.
--
-- Local player only, and only for the pal that is actually out: a remote client
-- on a dedicated server drives its own presentation, and reaching into its
-- otomo lifecycle from the host belongs to the evolve path's phase signals, not
-- here. Every step is optional - the revert has already happened when this
-- runs, so a decline costs nothing but a manual recall.
local function resummonAfterRollback(playerCtx, param)
    -- Every exit names its reason: this sequence has half a dozen legitimate
    -- ways to decline, and a silent decline reads exactly like a broken one.
    local function bail(reason)
        Log("Resummon skipped: " .. reason)
        return false
    end
    if not (playerCtx and playerCtx.pc and playerCtx.pc:IsValid()) then
        return bail("no player controller")
    end
    if playerCtx.isLocal == false then
        return bail("remote player, client drives its own otomo")
    end

    local holder = findHolderFor(playerCtx, nil)
    if not (holder and holder:IsValid()) then return bail("no otomo holder") end
    local mgr = findManager(playerCtx.pc)
    if not mgr then return bail("no character manager") end

    -- Party slot of an individual, via its handle. Both calls hand back plain
    -- values (an object pointer and an int), so neither can hit the
    -- struct-by-value return that faults natively past a pcall.
    local function slotOf(p)
        if not (p and p:IsValid()) then return -1 end
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

    -- Only act when this exact pal is the one that is out. Identified by SLOT
    -- index, not by comparing the two parameter objects: those come back as
    -- separate Lua wrappers and equality between them is the binding's
    -- business, not something a presentation step may depend on. Slots are ints.
    local spawned, spawnedSlot = nil, -1
    pcall(function() spawned = holder:TryGetSpawnedOtomo() end)
    if not (spawned and spawned:IsValid()) then return bail("no pal is out") end
    pcall(function()
        local sp = spawned.CharacterParameterComponent:GetIndividualParameter()
        if sp and sp:IsValid() then spawnedSlot = slotOf(sp) end
    end)
    if spawnedSlot < 0 or spawnedSlot ~= slot then
        return bail(string.format("a different pal is out (slot %g, rolled back %g)",
            spawnedSlot, slot))
    end

    local okOff, errOff = pcall(function() holder:InactivateCurrentOtomo() end)
    if not okOff then return bail("recall failed: " .. tostring(errOff)) end

    -- The recall needs a moment before the slot loads again: ONE delayed shot
    -- (never ExecuteWithDelay), and the LATCH is what makes it one - a body
    -- that outlives its interval is re-entered before `return true` retires
    -- the loop (crash #7), so the return is the tidy-up and the latch is the
    -- guarantee. Nothing keeps ticking if the reload does not take.
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
                Log(string.format("Resummoned slot %g after rollback", slot))
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
-- (simplest robust format without a JSON lib), so this session's restore points
-- stay inspectable from outside the game - but it is never read back: a
-- rollback now hands the evolution's PRICE back, and a restore point that
-- outlived the session would refund materials priced at a level the pal has
-- long since left, on an individual that may have been bred, traded or
-- re-evolved in between. Undoing what you just did is the promise; undoing
-- your history is not.
local snapshots = {}

local function loadSnapshots()
    snapshots = {}
    -- Start the file over so old entries can never be mistaken for this
    -- session's. Truncating the whole file is exactly right and no wider than
    -- intended: saveSnapshots is its ONLY writer and snapshot rows are all it
    -- ever holds (the stage crumb is a sibling file, autoSnooze is memory-only).
    -- The file exists from the second launch onwards, so its mere presence says
    -- nothing; only a file WITH entries means something was actually discarded.
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
                -- and "%d" on a non-integral number raises rather than rounds
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

-- ------------------------------------------------------- damage protection

-- Damage protection for the transformation window (Config.evolveProtection).
-- The staging freezes the pal (AI + movement off) but leaves it DAMAGEABLE,
-- and no stage checks for death: mid-combat, a kill during the dissolve reads
-- as a successful despawn, and the revealed new form can be shot down through
-- the whole grow/hold. While a window is open, the protected individual's
-- CURRENT body - re-derived from the holder every tick and identity-checked,
-- which carries the protection across the old body, the actor-less gap and
-- the freshly spawned target body - is flagged undamageable, and the
-- individual's HP is re-topped as a second layer for any damage path that
-- ignores the actor flag. Closing restores damageability; the final full
-- heal happens only when the species swap actually committed, so an ABORTED
-- evolution does not hand out a free heal on top of the refund (the pump may
-- already have topped it up while the window was open - unavoidable for a
-- heal-based damage floor).
--
-- One instance per performEvolution run, registered per individual: on a
-- dedicated server the sequence lock is released right after the swap while
-- the presentation continues, so a chained follow-up evolution of the SAME
-- pal can start while the previous window still runs. The new window
-- supersedes the old one WITHOUT a restore (it re-flags the same actor
-- synchronously below), so no damageable gap opens and a late closer of the
-- superseded run can no longer punch a hole into the live window.
-- AActor-level damage flag; Palworld's own damage pipeline sits above it,
-- so callers layer their own guarantee on top (the protection window adds
-- an HP pump; the Primed Pal telegraph deliberately does NOT heal, so a low
-- HP wild pal keeps its juicy capture odds while it cannot die)
local function setActorDamageable(a, damageable)
    if not (a and a:IsValid()) then return end
    pcall(function() a:SetCanBeDamaged(damageable) end)
    pcall(function() a.bCanBeDamaged = damageable end)
end

local activeProtections = {}

-- resolveBody (optional) replaces the holder read for individuals that are NOT
-- a summoned otomo: a base worker has no otomo holder, so its current body is
-- resolved from the character handle instead. The identity check below is
-- unchanged either way - whatever the resolver returns must still BE this
-- individual before it is flagged or restored.
local function startProtection(param, holder, key, label, resolveBody)
    local cfg = Config.evolveProtection or {}
    if cfg.enabled == false then return nil end
    local prot = { active = true, swapCommitted = false }
    local startedAt = os.clock()
    local maxS = tonumber(cfg.maxWindowSeconds) or 90
    local pumpMs = math.floor(math.max(100, tonumber(cfg.healPumpMs) or 250))
    local lastActor = nil
    local pkey = key
    if not pkey or pkey == "" then pkey = individualKey(param) end

    local prev = activeProtections[pkey]
    if prev then prev.active = false end -- supersede, deliberately no restore
    activeProtections[pkey] = prot

    -- the protected individual's current body ONLY: during the respawn gap
    -- the player can summon a DIFFERENT pal (the summon key is not blocked),
    -- and that one must never be flagged or restored by this window
    local function currentActor()
        local a = nil
        if resolveBody then
            pcall(function() a = resolveBody() end)
        else
            pcall(function()
                if holder and holder:IsValid() then a = holder:TryGetSpawnedOtomo() end
            end)
        end
        if not (a and a:IsValid()) then return nil end
        local ap = paramOf(a)
        if not (ap and ap:IsValid()) then return nil end
        if individualKey(ap) ~= pkey then return nil end
        return a
    end

    local function pumpOnce()
        local a = currentActor()
        if a then
            -- re-assert every tick: cheap, and survives both the actor
            -- churn (old body -> new body) and anything that resets the
            -- flag during activation
            setActorDamageable(a, false)
            lastActor = a
        end
        pcall(function()
            if param and param:IsValid() then param:FullRecoveryHP() end
        end)
    end

    -- restore=false: the world (or the requester's holder) is tearing down -
    -- end the window without touching anything the dying side owns (same
    -- rule as abandonOnTeardown)
    function prot.stop(restore)
        if not prot.active then return end
        prot.active = false
        if activeProtections[pkey] == prot then activeProtections[pkey] = nil end
        if not restore then return end
        local a = currentActor()
        if a then setActorDamageable(a, true) end
        if lastActor and lastActor ~= a then setActorDamageable(lastActor, true) end
        if prot.swapCommitted then
            pcall(function() if param and param:IsValid() then param:FullRecoveryHP() end end)
        end
    end

    -- one synchronous pump before the loop: LoopAsync first fires only AFTER
    -- pumpMs, and the pal must never sit exposed through that first interval
    -- (every startProtection caller runs on the game thread)
    pumpOnce()

    LoopAsync(pumpMs, function()
        if not prot.active then return true end
        ExecuteInGameThread(function()
            if not prot.active then return end
            -- backstop only: every regular sequence end already stops the
            -- window; this catches a leaked one (e.g. lost callback)
            if (os.clock() - startedAt) > maxS then
                Log(string.format("Protection window deadline hit (%s) - releasing", tostring(label)))
                prot.stop(true)
                return
            end
            pumpOnce()
        end)
        return not prot.active
    end)
    return prot
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

-- Work-suitability rebuild at the swap (v1.8.2). WHERE the stale data lives:
-- TArray<FPalWorkSuitabilityInfo> CraftSpeeds (per row: WorkSuitability enum
-- + Rank int32), a TRANSIENT member INSIDE both save-parameter copies this
-- file already mirrors every write to - SaveParameter and
-- SaveParameterMirror (PalIndividualCharacterSaveParameter.h). It is stamped
-- once at param construction and is NOT rebuilt when an evolution rewrites
-- CharacterID, so the SAVE is never wrong (Transient = never serialized) and
-- only the live session's cache lies. The party panel reads that cache
-- through param:GetWorkSuitabilityRank(enumAsInt).
--
-- v1.8.1's single attempt - UpdateApplyDatabaseToIndividualParameter - is
-- CONVICTED, not suspected (live receipt 2026-07-29 23:25:32): it ran clean
-- and rebuilt NOTHING. All 13 read-backs stayed flat AND the party panel
-- stayed stale - one cache, both stories, so "the UI just did not repaint"
-- is not available as an excuse. The call is gone; nothing here asks the
-- database to re-stamp the param object.
--
-- v1.8.2 rebuilt the cache IN PLACE, census-first, in staged steps: census
-- CraftSpeeds on both copies -> read the SPECIES ranks for the new
-- CharacterID -> rewrite each existing row's Rank -> read back. CENSUS
-- VERDICT (live, 2026-07-30): the arrays are 13-SLOT DENSE on this build
-- (every suit present, absent ones Rank=0) - the growth pass is never
-- needed; pass-1 rank rewrites alone fully retarget a pal.
--
-- v1.8.3 (crash #7, 2026-07-30) retired both bridge probes the same night:
-- the species read - UPalDatabaseCharacterParameter's OWN
-- GetWorkSuitabilityRank(FName RowName, TMap-out); NAME-COLLISION trap vs
-- the individual param's same-named enum->int getter - ran CLEAN and
-- returned EMPTY on 933 (both routes, both BOSS_ and base row ids; the
-- techcensus count-only marshal family), and the OnRep nudge is convicted
-- of worse (see the stage-3 tombstone below).
--
-- v1.8.4: the species source is worksuit_static.lua - a GENERATED
-- full-roster table (tools/gen-worksuit.js, saddle-tech style: zero
-- runtime reads; regenerate only when the game adds species). With the
-- 13-slot-dense census verdict, pass-1 rank rewrites alone fully retarget
-- a pal - the growth pass exists only as a fallback for a build where the
-- array turns out sparse.
--
-- CRASH #7's actual killer was neither probe directly: the reveal
-- finisher's one-shot LoopAsync had no fired-latch, and v1.8.2's ~100ms
-- refresh outran the 100ms revealDelay - the finisher re-fired every tick
-- until a fourth concurrent pass read freed memory. The latch is fixed at
-- the finisher; the belt here is the 2s per-cid repeat guard.
--
-- STILL BANNED: SetWorkSuitabilityAddRank(suit, 0) - vanilla's rank-up write
-- path backs onto the SAVED GotWorkSuitabilityAddRankList, and its
-- set-vs-add semantics for a zero add are stub-unknowable; a blind call could
-- pollute that persisted list invisibly or zero out rank-up progress the
-- player paid items for. The list is CENSUSED (read-only, devMode) and NEVER
-- written - not by this path, not by any other.
--
-- CRUMB LAW (earned by crash #5, techcensus.lua): every unproven bridge call
-- sits inside a flush-safe write+flush+close bracket in worksuit_stage.txt
-- next to the snapshot file, because a hard native AV eats the log's final
-- second. "entering X" with no "X ok" next session names the call a native
-- fault no pcall could have caught. NO early return may sit between a
-- bracket's two halves - a bail that consumes the bracket reads as a crash
-- and falsely convicts the one call the bracket exists to judge.
--
-- Nothing here trusts a write: the 13 ranks are read before and after
-- (GetWorkSuitabilityRank - enum-in/int-out, the one bulk-free shape on this
-- object), and a rank that fails to READ is never evidence of a change.
-- First PROOF logs in ANY mode (a devMode-only proof line proves nothing);
-- the no-change and error outcomes get their own one-shot lines.
--
-- EPalWorkSuitability ordinals are a STATIC header-derived table
-- (EPalWorkSuitability.h; the UEnum object is never touched - CTD law):
local SUIT_LABELS = {
    [1] = "Kindling", [2] = "Watering", [3] = "Planting", [4] = "Electricity",
    [5] = "Handiwork", [6] = "Gathering", [7] = "Lumbering", [8] = "Mining",
    [9] = "Oil", [10] = "Medicine", [11] = "Cooling", [12] = "Transport",
    [13] = "Farming",
}
local SUIT_ORDINALS = {}  -- display name -> ordinal, the reverse map
for i = 1, 13 do SUIT_ORDINALS[SUIT_LABELS[i]] = i end
-- The GENERATED species->ranks table (tools/gen-worksuit.js; the
-- saddle-tech pattern - zero runtime reads). Lazy-required so a missing or
-- broken file degrades to the honest no-source line at the first evolve,
-- never to an init failure; the miss is logged exactly once.
local worksuitStaticTried, worksuitStaticTbl = false, nil
local function worksuitStatic()
    if not worksuitStaticTried then
        worksuitStaticTried = true
        local ok, t = pcall(require, "worksuit_static")
        if ok and type(t) == "table" then
            worksuitStaticTbl = t
        else
            Log("[worksuit] static rank table missing or unreadable - "
                .. "in-session refresh has no source")
        end
    end
    return worksuitStaticTbl
end
-- both save-parameter copies, in write order (the fork mirrors every write)
local SUIT_COPIES = { "SaveParameter", "SaveParameterMirror" }
local worksuitProven = false      -- latched ONLY by a real observed delta
local worksuitQuietNoted = false  -- the honest no-change line, once
local worksuitErrNoted = false    -- the error line, once
local worksuitLast = { cid = nil, at = 0 }  -- repeat-guard belt (crash #7)
local worksuitCrumbPath = nil     -- resolved once, from the snapshot file's dir
local worksuitCrumbHeader = false

-- Flush-safe stage crumb: open/write/flush/close per line, because a hard
-- native AV eats the UE4SS log's last second and the console is then no
-- witness. Written in ANY mode - this is crash forensics, not chatter - and
-- entirely inside pcall: an io failure must NEVER break an evolution.
-- Append-only by design; an orphaned "entering X" from a crashed run is the
-- evidence, so nothing here ever truncates the file.
-- Declared ahead of WorkNative because the companion bridge below is bracketed
-- with it: a helper defined after the function that uses it is not an upvalue
-- of that function at all.
local function worksuitCrumb(line)
    pcall(function()
        if not worksuitCrumbPath then
            -- same directory as the snapshot file, whose path is already
            -- derived from this script's own location (no second copy of
            -- that path logic)
            local dir = STATE_FILE:match("^(.*)[/\\]")
            worksuitCrumbPath = (dir and (dir .. "\\worksuit_stage.txt"))
                or "worksuit_stage.txt"
        end
        local f = io.open(worksuitCrumbPath, "a")
        if not f then return end
        if not worksuitCrumbHeader then
            f:write("=== session start, modVersion "
                .. tostring(Config.modVersion) .. "\n")
            worksuitCrumbHeader = true
        end
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. line .. "\n")
        f:flush()
        f:close()
    end)
end

-- The companion's half of the work-suitability story, and the only half that
-- ever reaches the screen on this build: the H2 verdict (v1.8.8) proved the
-- Team/Palbox panel and the base camp read a NATIVE cache built when the
-- individual param is constructed, so every Lua WRITE lands in the save struct
-- and is never read back in-session. PalvolveNative_SetWorkSuitability
-- post-hooks the READ instead and answers with the species the pal is now.
-- One table rather than three locals: this chunk sits near Lua's 200
-- top-level-local ceiling and each new name is a real cost.
local WorkNative = {
    announced = false,  -- the "companion missing" line, once per session
    installed = false,  -- the "override installed" line, once per session
}

-- True when the companion dll exported its hook into this Lua state. Cheap
-- enough to ask per call, and it must be asked per call: the dll can finish
-- loading after the first evolution of a session.
function WorkNative.present()
    return type(PalvolveNative_SetWorkSuitability) == "function"
end

-- Hands the parameter object to the companion and reports whether the override
-- took. The caller uses the answer for one thing only: whether the receipts may
-- still promise the panel catches up "after a save & reload" (with an override
-- installed they may not - the getters answer live from here on).
-- The parameter object goes over AS-IS. An upstream build sent a key built in
-- Lua instead, and its GetFullName fallback handed the native side a name where
-- it expected an instance id, which installed nothing at all.
-- A false answer is normal and harmless: an alpha's species is resolved natively
-- from the RAW BOSS_ id and the character DB has no row for some of them. The
-- native side logs that itself; nothing latches here, so the next evolution
-- (and the next species) gets a clean try.
function WorkNative.apply(param)
    if not WorkNative.present() then
        if not WorkNative.announced then
            WorkNative.announced = true
            Log("[worksuit] native companion missing - values update after a relog")
        end
        return false
    end
    if not (param and param:IsValid()) then return false end
    -- BRACKETED like every other unproven native bridge in this file: the
    -- companion's exported hook has never fired on this machine, and a fault
    -- inside a dll export is pcall-transparent - it takes the process with no
    -- Lua error and no log flush, so the only witness is the line already on
    -- disk. The cid is read first (a proven getter) so the entering line names
    -- the pal, and the closer carries BOTH verdicts: whether the pcall returned
    -- at all, and what the companion itself answered.
    local cid = "?"
    pcall(function() cid = tostring(param:GetCharacterID():ToString()) end)
    worksuitCrumb("entering native SetWorkSuitability cid=" .. cid)
    local called, ok, msg = pcall(PalvolveNative_SetWorkSuitability, param)
    worksuitCrumb(string.format("survived native SetWorkSuitability cid=%s %s", cid,
        called and string.format("returned=%s msg=%s", tostring(ok), tostring(msg))
            or ("raised err=" .. tostring(ok))))
    if not called then
        Log("[worksuit] native call failed: " .. tostring(ok))
        return false
    end
    if not ok then
        Log("[worksuit] native override refused: " .. tostring(msg))
        return false
    end
    if not WorkNative.installed then
        WorkNative.installed = true
        Log("[worksuit] native companion override installed: " .. tostring(msg))
    else
        -- the species the native side resolved, which is the one the getters
        -- report from here on - its own answer, never our guess
        Log("[worksuit] native override now reading as " .. tostring(msg))
    end
    return true
end

-- an unknown ordinal prints its number (%g: a tonumber'd enum may arrive as
-- a float, and %d would throw on a non-integral one)
local function suitName(s)
    return SUIT_LABELS[s] or string.format("%g", tonumber(s) or 0)
end

local function readSuitVector(param)
    local v = {}
    for s = 1, 13 do
        local r = nil
        pcall(function() r = param:GetWorkSuitabilityRank(s) end)
        v[s] = (type(r) == "number") and r or -1
    end
    return v
end

-- the whole 13-slot vector on one devMode line; an unreadable slot prints "?"
local function vecString(v)
    local parts = {}
    for s = 1, 13 do
        local r = v[s]
        parts[#parts + 1] = SUIT_LABELS[s]:sub(1, 3) .. ":"
            .. ((r == nil or r == -1) and "?" or string.format("%g", r))
    end
    return table.concat(parts, " ")
end

-- TArray access, house pattern (conditions.lua forEachInArray): GetArrayNum
-- first, # as the fallback; indexed access hands back RemoteUnrealParam
-- wrappers, so :get() before touching members. ForEach is deliberately NOT
-- used here - its element wrapper is only valid inside the callback, and the
-- write pass writes through the very element it reads.
local function arrLen(arr)
    local n = nil
    pcall(function() n = arr:GetArrayNum() end)
    if type(n) ~= "number" then pcall(function() n = #arr end) end
    return (type(n) == "number") and math.floor(n) or nil
end

local function arrAt(arr, i)
    local e = nil
    pcall(function() e = arr[i] end)
    if type(e) == "userdata" then
        local g = nil
        pcall(function() g = e:get() end)
        if g ~= nil then e = g end
    end
    return e
end

-- one row's (suitability, rank); -1 for either half that will not read
local function rowPair(entry)
    local s, r = nil, nil
    if entry ~= nil then
        pcall(function() s = tonumber(entry.WorkSuitability) end)
        pcall(function() r = tonumber(entry.Rank) end)
    end
    return s and math.floor(s) or -1, r and math.floor(r) or -1
end

-- Writing a row's Rank (v1.8.5). The v1.8.4 receipt CONVICTED the write
-- through arrAt's :get() copy (live 2026-07-30 01:35: static ranks
-- resolved, write ran, after-vector identical - the unwrap hands back a
-- by-value copy and the field write lands on the temporary). Writes now go
-- through a measured VARIANT LADDER, each rung confirmed by re-reading the
-- slot through a fresh arrAt before it counts:
--   field:   arr[i].Rank = t          (raw wrapper, no unwrap)
--   element: arr[i] = {WorkSuitability=s, Rank=t}  (whole-element table
--            marshal - the growth pass proved the APPEND form of it on 933;
--            the existing-index form is unproven until a rung receipt)
-- The first rung that confirms is latched for the session as a preference,
-- never a proof substitute - every write is still confirmed individually.
local worksuitWriteVariant = nil
local function writeRank(arr, i, s, t)
    -- BOTH halves confirm (fix-verify catch): the element rung replaces the
    -- whole row, and a marshal that sets Rank but mangles WorkSuitability
    -- would otherwise latch as "proven" and compound - the s=0 row escapes
    -- covered[] next evolve and the growth pass appends a duplicate
    local function confirm()
        local cs, cur = rowPair(arrAt(arr, i))
        return cs == s and cur == t
    end
    local variants = {
        { name = "field", try = function()
            pcall(function() arr[i].Rank = t end)
        end },
        { name = "element", try = function()
            pcall(function() arr[i] = { WorkSuitability = s, Rank = t } end)
        end },
    }
    if worksuitWriteVariant == "element" then
        variants[1], variants[2] = variants[2], variants[1]
    end
    for _, v in ipairs(variants) do
        v.try()
        if confirm() then
            if worksuitWriteVariant ~= v.name then
                worksuitWriteVariant = v.name
                if Config.devMode then
                    Log("[worksuit] write variant proven: " .. v.name)
                end
            end
            return true
        end
    end
    return false
end

-- census one FPalWorkSuitabilityInfo array. nil count = the array (or its
-- length) is unreadable, and nothing is ever written blind after that.
local function censusSuitArray(arr)
    if arr == nil then return nil, "unreadable" end
    local n = arrLen(arr)
    if n == nil then return nil, "length unreadable" end
    local parts = {}
    for i = 1, n do
        local s, r = rowPair(arrAt(arr, i))
        parts[#parts + 1] = string.format("%s:%g", suitName(s), r)
    end
    return n, (#parts > 0) and table.concat(parts, ", ") or "empty"
end

local function refreshWorkSuitability(param, playerCtx, actor)
    -- kill switch: false = stock behavior, new work styles at save & reload.
    -- It gates the companion too - "stock" has to mean the override is not
    -- installed either, or the switch would only turn off the half that never
    -- worked.
    if Config.worksuitRefresh == false then return end
    local okAll = pcall(function()
        if not (param and param:IsValid()) then return end
        -- repeat-guard belt (crash #7), FIRST thing after the validity gate:
        -- a repeat call must be turned away before ANY param walk, not after
        -- the 13-read before-vector (verify catch - the belt engaged ~15
        -- reads too late to shield the freed-param shape it exists for). The
        -- reveal finisher carries its own fired-latch; any future pump that
        -- re-enters here degrades to one skipped-log line.
        local cid = nil
        pcall(function() cid = param.SaveParameter.CharacterID:ToString() end)
        if type(cid) ~= "string" or cid == "" then cid = nil end
        local nowT = os.clock()
        if cid and worksuitLast.cid == cid and (nowT - worksuitLast.at) < 2.0 then
            if Config.devMode then
                Log("[worksuit] repeat call for " .. cid .. " within 2s - skipped")
            end
            return
        end
        worksuitLast.cid, worksuitLast.at = cid, nowT

        -- With the companion loaded, everything below this point is forensics
        -- rather than the fix: the override answers the getters directly, and
        -- the save-struct rebuild it replaced never reached a single reader.
        -- So outside devMode we go straight to it and the census/write/read-back
        -- stages are skipped whole - together with every receipt that measures
        -- them, because a receipt printed over stages that did not run would be
        -- claiming deltas nobody read. Without the companion nothing changes:
        -- the full pipeline runs regardless of devMode, since then the
        -- save-struct write is the only lever there is.
        if WorkNative.present() and not Config.devMode then
            WorkNative.apply(param)
            return
        end

        local before = readSuitVector(param)
        if Config.devMode then Log("[worksuit] before: " .. vecString(before)) end
        local function changes(after)
            local parts = {}
            for s = 1, 13 do
                -- a failed read (-1 sentinel) on EITHER side is never
                -- evidence of a change - phantom deltas must not latch proof
                if before[s] ~= -1 and after[s] ~= -1 and after[s] ~= before[s] then
                    parts[#parts + 1] = string.format("%s %g->%g",
                        SUIT_LABELS[s], before[s], after[s])
                end
            end
            return parts
        end

        -- ---- stage 0: census. Nothing is written that was not first read.
        local censusOk = false
        worksuitCrumb("entering craftspeeds census")
        local okCensus = pcall(function()
            local readable = 0
            for _, copyName in ipairs(SUIT_COPIES) do
                local arr = nil
                pcall(function() arr = param[copyName].CraftSpeeds end)
                local n, dump = censusSuitArray(arr)
                if n then readable = readable + 1 end
                if Config.devMode then
                    Log(string.format("[worksuit] %s.CraftSpeeds (%s): %s", copyName,
                        n and string.format("%d", n) or "?", dump))
                end
            end
            censusOk = readable > 0
        end)
        worksuitCrumb(okCensus and "craftspeeds census ok" or "craftspeeds census failed")
        -- The saved add-rank list, READ-ONLY forever. Censused AND kept: the
        -- rank getter may sum base + this paid list (SDK shape), so every
        -- after-vs-target comparison below tests against target + addRank -
        -- otherwise a pal with an Applied Technique book would false-report
        -- "write did not stick". A paid rank-up that momentarily reads low
        -- is Transient-only - a reload restores it.
        -- Own bracket: a fault HERE must never be pinned on the CraftSpeeds
        -- reads above (a shared bracket convicts the wrong call).
        local addRank = {}
        worksuitCrumb("entering addranklist census")
        local okRl = pcall(function()
            local rl = nil
            pcall(function() rl = param.SaveParameter.GotWorkSuitabilityAddRankList end)
            local nr, dumpr = censusSuitArray(rl)
            if nr and nr > 0 then
                for i = 1, nr do
                    local s, r = rowPair(arrAt(rl, i))
                    if s >= 1 and s <= 13 and r > 0 then
                        addRank[s] = (addRank[s] or 0) + r
                    end
                end
            end
            if Config.devMode then
                Log(string.format("[worksuit] SaveParameter.GotWorkSuitabilityAddRankList"
                    .. " (%s): %s [read-only - persisted save data]",
                    nr and string.format("%d", nr) or "?", dumpr))
            end
        end)
        worksuitCrumb(okRl and "addranklist census ok" or "addranklist census failed")
        if not okCensus then
            censusOk = false
            if Config.devMode then
                Log("[worksuit] craftspeeds census errored - nothing written")
            end
        end

        -- ---- stage 1: the rebuild SOURCE - the species ranks of the new
        -- CharacterID, from the DATABASE object's same-named getter. Only
        -- with a LIVE context object: the caller guarantees the actor (or
        -- player controller) is alive; the despawned-actor sites do not call
        -- this function at all (an internal actor deref inside a stub body
        -- would be a pcall-transparent native fault).
        local target, targetN, sourced = {}, 0, false
        local noWhy = "no species rank source"
        -- ---- stage 1: species truth from the GENERATED static table.
        -- Runtime routes stay RETIRED on this build (crash #7 session,
        -- 2026-07-30): the DB's TMap-out GetWorkSuitabilityRank ran CLEAN
        -- and returned EMPTY - both routes, both BOSS_ and base row ids
        -- (crumb-bracketed, "ok" closers, zero entries; the techcensus
        -- count-only marshal family). Alphas share the base form's ranks,
        -- so the lookup strips the BOSS_ prefix. PRESENCE in the table is
        -- what authorizes the write - a sourced-but-empty row (KingWhale
        -- has zero suitabilities) legitimately zeroes every stale rank,
        -- while an absent species must not be touched at all.
        if censusOk and cid then
            local tbl = worksuitStatic()
            if not tbl then
                noWhy = "static rank table unavailable"
            else
                local key = (cid:sub(1, #BOSS_PREFIX) == BOSS_PREFIX)
                    and cid:sub(#BOSS_PREFIX + 1) or cid
                local row = tbl[key]
                if row then
                    sourced = true
                    pcall(function()
                        for name, rank in pairs(row) do
                            local ord, r = SUIT_ORDINALS[name], tonumber(rank)
                            if ord and r and r > 0 and target[ord] == nil then
                                target[ord] = math.floor(r)
                                targetN = targetN + 1
                            end
                        end
                    end)
                else
                    -- the id is IN the line so a non-dev user can report
                    -- exactly which species the table lacks
                    noWhy = "species not in the static rank table: " .. key
                end
            end
        end
        if not censusOk then
            noWhy = "craftspeeds census unreadable"
        elseif not cid then
            noWhy = "character id unreadable"
        elseif not sourced then
            if Config.devMode then
                Log("[worksuit] " .. noWhy .. " - skipping write")
            end
        elseif Config.devMode then
            local list = {}
            for s = 1, 13 do
                if target[s] then
                    list[#list + 1] = string.format("%s:%g", SUIT_LABELS[s], target[s])
                end
            end
            Log(string.format("[worksuit] species ranks for %s (static): %s", cid,
                targetN > 0 and table.concat(list, ", ") or "(none - zero-suit species)"))
        end

        -- ---- stage 2: the write. Populated copies only, in place, existing
        -- rows first; growth (a work style the array has no row for) is a
        -- second pass. An EMPTY copy is skipped outright: the 01:35 receipt
        -- showed the mirror sits at 0 rows mid-sequence and the engine
        -- refills it later - growing rows into that window is uncontrolled
        -- state (and the appended fields were never verified), while the
        -- 13-slot-dense law says any POPULATED copy already has every row.
        local growthFailed = false
        if sourced then
            worksuitCrumb("entering craftspeeds write")
            pcall(function()
                for _, copyName in ipairs(SUIT_COPIES) do
                    local arr = nil
                    pcall(function() arr = param[copyName].CraftSpeeds end)
                    local n = arr and arrLen(arr) or nil
                    if n == nil or n == 0 then
                        if Config.devMode then
                            Log("[worksuit] " .. copyName .. " has no rows - "
                                .. "skipped (engine refills it)")
                        end
                    else
                        -- covered is booked PER COPY from that copy's own
                        -- rows: booking copy 1's rows against the mirror
                        -- would append duplicates whenever the copies diverge
                        local covered = {}
                        -- pass 1: rewrite the Rank of every row that exists,
                        -- via the confirmed variant ladder. A suitability the
                        -- new species does NOT have goes to 0 - the old
                        -- form's work style is genuinely gone.
                        local misses = 0
                        for i = 1, n do
                            local s, cur = rowPair(arrAt(arr, i))
                            if s >= 1 and s <= 13 then
                                covered[s] = true
                                local t = target[s] or 0
                                if cur ~= t and not writeRank(arr, i, s, t) then
                                    misses = misses + 1
                                end
                            end
                        end
                        if misses > 0 and Config.devMode then
                            Log(string.format("[worksuit] %d slot write(s) did "
                                .. "not stick on %s (all variants tried)",
                                misses, copyName))
                        end
                        -- pass 2: growth. ONE attempt, then never again on
                        -- either copy - length re-read confirms the append,
                        -- and the new row's FIELDS are confirmed too (the
                        -- 01:35 appends grew the array but their field
                        -- values were never verified - a zeroed junk row
                        -- must count as failure, not success).
                        local tail = n
                        for s = 1, 13 do
                            if (target[s] or 0) > 0 and not covered[s]
                                and not growthFailed then
                                worksuitCrumb(string.format(
                                    "entering craftspeeds growth (suit %d)", s))
                                local okGrow = pcall(function()
                                    arr[tail + 1] = { WorkSuitability = s, Rank = target[s] }
                                end)
                                worksuitCrumb(okGrow and "craftspeeds growth ok"
                                    or "craftspeeds growth failed")
                                local grewTo = arrLen(arr)
                                local grew = okGrow and grewTo and grewTo > tail
                                local gs, gr = -1, -1
                                if grew then
                                    gs, gr = rowPair(arrAt(arr, grewTo))
                                end
                                if gs == s and gr == target[s] then
                                    tail = grewTo
                                else
                                    growthFailed = true
                                    if Config.devMode then
                                        Log(string.format("[worksuit] craftspeeds growth"
                                            .. " unusable from Lua (%s: %s) - existing"
                                            .. " rows were still rewritten",
                                            SUIT_LABELS[s] or tostring(s),
                                            grew and ((gs == -1 and gr == -1)
                                                and "appended row unreadable"
                                                or "appended row fields wrong")
                                            or "no append"))
                                    end
                                end
                            end
                        end
                    end
                end
            end)
            worksuitCrumb("craftspeeds write done")
        end

        -- ---- read-back: a write is never trusted, only measured.
        -- slotMatches tolerates EITHER getter model (fix-verify catch): the
        -- array holds BASE ranks, but whether GetWorkSuitabilityRank sums
        -- the paid add list on top is undiscriminated (the only live
        -- evidence had an empty list). A booked pal must not burn one-shot
        -- receipts on a model guess - base and base+paid both count as
        -- complete when a paid rank exists; with an empty list the two
        -- models are bit-identical.
        local function slotMatches(s2, av)
            local base = target[s2] or 0
            if av == base + (addRank[s2] or 0) then return true end
            return (addRank[s2] or 0) > 0 and av == base
        end

        -- ---- stage 2b (v1.8.6, the DISCRIMINATOR): the 02:13 receipt was a
        -- contradiction - writeRank CONFIRMED (both halves, same handle) yet
        -- the getter and the panel read old ranks. Exactly one of three
        -- worlds is true, and a FRESH property access tells them apart:
        --   H1 the arr handle was a DETACHED COPY (the :get() law one level
        --      up) -> fresh census reads OLD -> try the whole-array
        --      write-back, the one deeper lever left;
        --   H2 the write persists but the getter reads a native cache ->
        --      fresh census reads NEW, getter stays old;
        --   H3 the engine clobbers the array post-reveal -> fresh census
        --      NEW now, OLD at the +1s recheck below.
        -- freshAgrees: a FRESH handle read the array back matching target -
        -- the write persisted in the save struct even if the getter (the
        -- native-cache surface, per the 03:14 H2 verdict) never shows it
        local freshAgrees = false
        if sourced then
            local function freshDump()
                local fn, fd = nil, nil
                pcall(function()
                    fn, fd = censusSuitArray(param.SaveParameter.CraftSpeeds)
                end)
                return fn, fd
            end
            local fn, fd = freshDump()
            if Config.devMode then
                Log(string.format("[worksuit] post-write fresh census (%s): %s",
                    fn and string.format("%d", fn) or "?", fd or "?"))
            end
            -- fresh handle disagrees with the confirmed writes = H1: attempt
            -- ONE whole-array write-back (table -> TArray property SET;
            -- unproven marshal - the growth append proved the ELEMENT form)
            local freshWrong = false
            if fn and fn > 0 then
                pcall(function()
                    local a2 = param.SaveParameter.CraftSpeeds
                    for i = 1, fn do
                        local s2, r2 = rowPair(arrAt(a2, i))
                        -- unreadable is never evidence: the unproven marshal
                        -- must not fire on an unmeasured rank (fix-verify)
                        if s2 >= 1 and s2 <= 13 and r2 ~= -1
                            and r2 ~= (target[s2] or 0) then
                            freshWrong = true
                        end
                    end
                end)
            end
            if freshWrong then
                local rows = {}
                for s2 = 1, 13 do
                    rows[#rows + 1] = { WorkSuitability = s2, Rank = target[s2] or 0 }
                end
                worksuitCrumb("entering whole-array write-back")
                local okWhole = pcall(function()
                    param.SaveParameter.CraftSpeeds = rows
                end)
                worksuitCrumb("whole-array write-back "
                    .. (okWhole and "ok" or "failed"))
                if Config.devMode then
                    local fn2, fd2 = freshDump()
                    Log(string.format("[worksuit] post-write-back fresh census (%s): %s",
                        fn2 and string.format("%d", fn2) or "?", fd2 or "?"))
                end
            elseif fn and fn > 0 then
                freshAgrees = true
            end
            -- +1s recheck (H3 clobber window): one-shot, latched per the
            -- crash-#7 law, devMode only, IsValid-guarded - pure logging
            if Config.devMode then
                local recheckFired = false
                LoopAsync(1000, function()
                    if recheckFired then return true end
                    recheckFired = true
                    ExecuteInGameThread(function()
                        pcall(function()
                            if not (param and param:IsValid()) then return end
                            local fn3, fd3 = nil, nil
                            pcall(function()
                                fn3, fd3 = censusSuitArray(param.SaveParameter.CraftSpeeds)
                            end)
                            Log(string.format("[worksuit] +1s fresh census (%s): %s"
                                .. " | getter: %s",
                                fn3 and string.format("%d", fn3) or "?", fd3 or "?",
                                vecString(readSuitVector(param))))
                        end)
                    end)
                    return true
                end)
            end
        end

        local after = readSuitVector(param)
        local parts = changes(after)
        if Config.devMode then Log("[worksuit] after: " .. vecString(after)) end

        -- The companion goes LAST, strictly after the after-vector is read: every
        -- before/after receipt below names the craftspeeds rebuild as the
        -- mechanism, and a delta the override produced would be booked to a write
        -- that never made it out of the save struct. Attribution law - the
        -- receipts may only claim what they measured.
        local nativeOk = WorkNative.apply(param)

        if #parts > 0 then
            -- a delta may only be CLAIMED by a write that actually ran: a
            -- rank that moved on its own (engine re-derive between the two
            -- reads) must neither latch the proof nor name a mechanism that
            -- never executed - misattributed receipts poison the forensics
            if not sourced then
                if Config.devMode or not worksuitQuietNoted then
                    worksuitQuietNoted = true
                    Log("[worksuit] ranks changed without a rebuild write "
                        .. "(engine re-derive?): " .. table.concat(parts, ", "))
                end
                return
            end
            if Config.devMode or not worksuitProven then
                worksuitProven = true
                local msg = "[worksuit] refreshed via craftspeeds rebuild: "
                    .. table.concat(parts, ", ")
                -- incomplete = ANY readable rank still off-expectation,
                -- whatever failed it - a stuck slot write counts, not just
                -- growth (unreadable is never evidence either way)
                local incomplete = false
                for s = 1, 13 do
                    if after[s] ~= -1 and not slotMatches(s, after[s]) then
                        incomplete = true
                    end
                end
                if incomplete then
                    -- with the override installed a stuck slot in the save
                    -- struct costs the player nothing in-session: the reads
                    -- the panel and the camp make never touch that array
                    msg = msg .. (nativeOk
                        and " (some ranks did not take in the save struct - the"
                            .. " native override serves the live reads)"
                        or " (some ranks did not take - a save & reload"
                            .. " completes them)")
                end
                Log(msg)
            end
            return
        end

        -- ---- stage 3 (OnRep_SaveParameter nudge), RETIRED (crash #7
        -- session, 2026-07-30): three live fires ran "ok", moved zero ranks,
        -- and visibly reconciled SaveParameterMirror from SaveParameter
        -- (census fingerprint: mirror 0 rows -> 13 between iterations) -
        -- i.e. manually invoking an OnRep handler re-enters native
        -- replication reconciliation on a live gameplay object mid-frame,
        -- for no measured benefit. Never call OnRep handlers manually on
        -- live objects; if a repaint nudge is ever needed again it must be
        -- a purpose-built notify, not replication machinery.

        -- no observable change: say so once (devMode: every time), naming
        -- WHICH kind of nothing happened. THREE distinct states - the
        -- v1.8.4 receipt conflated two of them and called a vanished write
        -- "already correct" (law: a no-delta receipt must MEASURE which
        -- nothing it is, never guess). None of these latch the PROOF flag.
        -- Every "not applied yet" tail below ends on a save & reload, which
        -- stops being the truth on offer the moment the override installs: the
        -- getters answer with the new species from this call on. Only the
        -- closing clause moves - the measured half of each line is untouched,
        -- and a companion-less run reads exactly as it always did.
        if Config.devMode or not worksuitQuietNoted then
            worksuitQuietNoted = true
            if not sourced then
                Log("[worksuit] rebuild not attempted (" .. noWhy .. ") - "
                    .. (nativeOk and "the native override serves the new work "
                        .. "styles live" or "new work styles apply after a "
                        .. "save & reload"))
            else
                local matched, readable = true, false
                for s = 1, 13 do
                    if after[s] ~= -1 then
                        readable = true
                        if not slotMatches(s, after[s]) then matched = false end
                    end
                end
                if not readable then
                    -- measure-never-guess: an all-unreadable vector proves
                    -- nothing about the write either way
                    Log("[worksuit] rank getter unreadable - cannot verify "
                        .. "the rebuild; " .. (nativeOk and "the native override "
                        .. "serves the live reads" or "work styles apply after "
                        .. "a save & reload"))
                elseif matched then
                    Log("[worksuit] ranks already match the species - "
                        .. "nothing to change")
                elseif freshAgrees then
                    -- the 03:14 H2 verdict, now the receipt tells the truth:
                    -- the save-struct array holds the new ranks (fresh-handle
                    -- read-back matched target) but the getter/panel read a
                    -- native-side cache built at construction - unreachable
                    -- from Lua data writes on this build. The companion is the
                    -- answer to exactly that: it hooks the READ, so the same
                    -- measurement now ends somewhere else entirely.
                    if nativeOk then
                        Log("[worksuit] ranks written to the save struct, and "
                            .. "the native override now serves the live reads - "
                            .. "no reload needed")
                    else
                        Log("[worksuit] ranks written to the save struct, but the "
                            .. "game displays a native-side copy this build won't "
                            .. "let us touch - the panel updates at next save & reload")
                    end
                else
                    Log("[worksuit] write did not stick - ranks unchanged "
                        .. "(all variants tried); " .. (nativeOk and "the native "
                        .. "override serves the live reads" or "new work styles "
                        .. "apply after a save & reload"))
                end
            end
        end
    end)
    if not okAll and (Config.devMode or not worksuitErrNoted) then
        worksuitErrNoted = true
        Log("[worksuit] refresh attempt errored - work styles apply after a save & reload")
    end
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
    -- Opt-in ON TOP of devMode (Config.diagReveal, default false). Each call
    -- leaves a LoopAsync closure running for 12s with an ExecuteInGameThread
    -- nested inside it; two evolutions in quick succession overlap two of them
    -- and the game dies with "Ref was not function" - the callback GC trap. Off
    -- by default so a devMode session can evolve repeatedly at all.
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

-- last moment the player manually reached for evolution (F2 or a radial
-- pick); the auto-evolve poller yields to manual interaction for a few
-- seconds so an invisible auto-send can never eat the per-sender net rate
-- budget out from under the player's own pick
local lastManualActionAt = 0

-- withdraw-to-cancel snooze: individualKey -> the level the pal had when
-- the player pulled it out of a running evolution. Auto-evolve skips the
-- pal until it levels PAST that; manual paths are never gated by this.
local autoSnooze = {}
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
-- requireFree additionally skips every pair whose resolved cost list is
-- non-empty (the auto-evolve poller only ever fires free evolutions).
local function findEligibleFor(playerCtx, requireFree)
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
                if requireFree and #Costs.resolve(cand, level, holder) > 0 then
                    -- log-only reason: the sole requireFree caller (the
                    -- auto-evolve poller) stays silent in chat
                    firstReason = firstReason or "free evolutions only: every eligible option has a cost"
                else
                    pair = cand
                    pairIndex = i
                    break
                end
            else
                firstReason = firstReason or I18n.msg("needsConditions", palDisplayName(cand.to), unmet)
            end
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
    -- DarnToasts progress panel for THIS sequence. Declared here, above every
    -- closure that reads it (house rule), and decided once: the panel belongs
    -- to the player watching their own pal transform, so it is opened only for
    -- a LOCAL owner on a machine that draws a HUD. A remote requester's
    -- sequence also runs here (dedicated host or listen host) and their panel
    -- would appear on the wrong screen; headless has no screen at all; base
    -- and wild sequences stay panel-less by design (nobody is watching).
    local panel = (not headless) and playerCtx ~= nil
        and playerCtx.isLocal == true and Evolution.Toasts.available()
    pending = nil
    sequenceRunning = true
    sequenceStartedAt = os.clock()

    -- Per-run cancellation token: once done is set (success, abort or
    -- watchdog), every still-pending async callback of THIS run bails out
    -- instead of mutating a finished or foreign sequence.
    local seq = { done = false }

    -- Damage protection for the whole transformation window. finishOk must
    -- NOT close it headless: there the lock is released right after the swap
    -- while the exposed presentation continues, so the MP state machine's
    -- exit sites (and the window's own deadline) own the close instead.
    local prot = startProtection(param, holder, p.key, pair.from .. ">" .. pair.to)
    local function stopProtection(restore)
        if prot then prot.stop(restore) end
    end

    -- true while the dissolve staging runs and our own teardown has not
    -- started; the withdraw-to-cancel watch below lives on this flag
    local dissolvePhase = true

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
    -- Both finishers (and abandonOnTeardown below) close the progress panel:
    -- between them they are EVERY terminal exit of this sequence - the
    -- watchdog reaches finishAbort through currentAbort, the fx prototypes
    -- reach both through ctx.completeOk/completeAbort, and the data-only
    -- reveal failures reach finishAbort too. A panel that outlives its
    -- sequence is a bug, so the close sits in the choke points, never at the
    -- individual return sites.
    local function finishOk()
        if seq.done then return end
        seq.done = true
        if panel then Evolution.Toasts.progressEnd("evolve") end
        currentAbort = nil
        -- headless: the MP presentation (and the exposure) continues past
        -- this point - its exit sites close the protection window instead
        if not headless then stopProtection(true) end
        sequenceRunning = false
    end
    local function finishAbort()
        if seq.done then return end
        seq.done = true
        if panel then Evolution.Toasts.progressEnd("evolve") end
        currentAbort = nil
        pcall(function() fx.cleanup(ctx) end)
        stopProtection(true)
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
                math.floor(tonumber(failedItem and failedItem.count) or 0),
                Costs.labelOf(failedItem))
            Log(msg)
            finishAbort()
            return false, msg
        end
        Log("Cost taken: " .. Costs.describe(costList))
    end

    Log(string.format("Evolving %s (Lv %d)...", pair.from, level))
    -- Panel opens HERE, not at function entry: every early abort above (dead
    -- handles, no manager, no handle, unaffordable cost) happens in the same
    -- frame as the entry, and a panel that appears and vanishes inside one
    -- frame is a flicker, not a progress report. From this line on the
    -- sequence is genuinely under way. Localized species names, the same ones
    -- the prompts use; ASCII arrow deliberately - the HUD font is the game's
    -- and nothing else in these scripts assumes a glyph beyond it.
    if panel then
        Evolution.Toasts.progressBegin("evolve",
            palDisplayName(pair.from) .. " -> " .. palDisplayName(pair.to))
    end
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
        if panel then
            Evolution.Toasts.progressUpdate("evolve", "Dissolving", 0.2)
        end
    end
    playFanfare(actor)

    -- Withdraw-to-cancel (Config.withdrawCancels): during the dissolve the
    -- pal is still the summoned otomo. If it stops being summoned BEFORE
    -- our own teardown begins, the PLAYER recalled it - treat that as a
    -- cancel gesture: finishAbort refunds the untaken evolution's cost
    -- exactly (the swap has not committed), and auto-evolve snoozes this
    -- individual until its next level-up. Headless has no such window (the
    -- swap commits immediately there), and the teardown timer below closes
    -- the watch by flipping dissolvePhase first thing on the game thread.
    if not headless and Config.withdrawCancels ~= false then
        LoopAsync(200, function()
            if seq.done or not dissolvePhase then return true end
            ExecuteInGameThread(function()
                if seq.done or not dissolvePhase then return end
                -- inline handle check: handlesAlive() is declared further
                -- down and would resolve as a nil GLOBAL from this closure
                if not (mgr and mgr:IsValid() and holder and holder:IsValid()) then
                    return -- world teardown owns this exit
                end
                local cur = nil
                pcall(function() cur = holder:TryGetSpawnedOtomo() end)
                if cur and cur:IsValid() then
                    -- still summoned - but only OUR pal counts: a lightning
                    -- withdraw-and-summon-another must also read as cancel
                    local same = false
                    pcall(function()
                        local cp = paramOf(cur)
                        same = (cp and cp:IsValid() and individualKey(cp) == key) == true
                    end)
                    if same then return end
                end
                dissolvePhase = false
                Log("Evolution cancelled: pal withdrawn during the dissolve")
                autoSnooze[key] = level
                -- mirror the despawn-exhausted abort's restore: a recalled
                -- actor is POOLED and must never re-summon frozen/ghosted
                pcall(function()
                    if actor:IsValid() then actor:SetActorEnableCollision(true) end
                end)
                setFrozen(actor, false)
                Role.chat(playerCtx, I18n.msg(txn
                    and "cancelWithdrawnRefunded" or "cancelWithdrawn"))
                finishAbort()
            end)
            return seq.done or not dissolvePhase
        end)
    end

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
        if panel then Evolution.Toasts.progressEnd("evolve") end
        currentAbort = nil
        pcall(function() fx.cleanup(ctx) end)
        stopProtection(false) -- dying world: end the window, touch nothing
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
                -- same moment the devMode line above reports: the old body is
                -- gone and the species swap is the next thing that happens
                if panel then
                    Evolution.Toasts.progressUpdate("evolve", "Reforming", 0.45)
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
        -- NO suitability refresh here: on the common SP path the old body is
        -- already DESTROYED (DirectTeardown) at this point, the same state
        -- the primed site rules out for an unprobed native call. The refresh
        -- runs at the fresh-actor moments instead: the SP reveal completion
        -- and the mpseq activation (fix-verify consistency catch).
        -- from here on the evolution HAPPENED: the protection window's final
        -- heal on close is legitimate (pre-swap aborts skip it)
        if prot then prot.swapCommitted = true end

        -- What this evolution ACTUALLY charged, so a rollback can hand it back.
        -- Recorded here rather than re-derived at rollback time: material
        -- prices are level-banded and the pal's level has moved on by then.
        -- Gated on the transaction, not on the list: txn is non-nil exactly
        -- when something was consumed (an empty list never opens one), so a
        -- free evolution records an empty list and refunds nothing. Bare
        -- id+count rows - the shape saveSnapshots serializes.
        local paidCost = {}
        if txn then
            for _, c in ipairs(costList or {}) do
                if c.id and c.count then
                    table.insert(paidCost, { id = c.id, count = c.count })
                end
            end
        end
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
            cost = paidCost,
        })
        saveSnapshots()
        -- Always the unprefixed id: the capture record is keyed by EPalTribeID, which has one
        -- entry per species and none for the BOSS_ (alpha) rows, exactly like the Paldeck.
        unlockCatchTech(pair.to, playerCtx)

        -- Tell the owner, at the one moment that is true on every path: the
        -- species is committed and snapshotted. This single site covers local
        -- manual (F2 and radial), local auto-evolve, and a REMOTE requester's
        -- manual/auto evolve on both a dedicated server and a listen host -
        -- the listen-host guest saw nothing at all before, because that path
        -- sends no phase signals and the success message is dropped upstream.
        --
        -- HEADLESS IS THE ONE EXCEPTION and it is an ORDERING one: on a
        -- dedicated server the client's "start" phase signal is what makes it
        -- chat "Evolving into X..." and begin the ~20s dissolve/respawn re-play.
        -- Both travel as reliable Client RPCs on the same connection, so they
        -- arrive in send order - announcing here would tell the player it
        -- FINISHED and only then that it is starting. The headless branch below
        -- announces immediately after sendSignal("start") instead.
        if not headless then
            announceEvolution(playerCtx, pair.from, targetId, level, "party")
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
            setRevealFrozen(actor, true)
            NetChannel.sendSignal(pcSender, "start")
            -- After the start signal, never before it: same connection, same
            -- reliable channel, so the player reads "Evolving into X..." first
            -- and the completion line second (see the note at the commit above).
            announceEvolution(playerCtx, pair.from, targetId, level, "party")
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
                        stopProtection(false) -- holder torn down: touch nothing
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
                            stopProtection(true)
                            -- post-commit exit with no reveal signal: the
                            -- success line already reached the requester, so
                            -- qualify it (pcSender passed IsValid at the top
                            -- of this tick; the swap itself is committed).
                            -- watcherDone is set FIRST so a raising announce
                            -- could never re-enter this exit every tick
                            watcherDone = true
                            announceEvolution(playerCtx, pair.from, targetId, level, "resummon")
                        end
                    elseif phase == "activate" then
                        local cand = nil
                        pcall(function() cand = handle:TryGetIndividualActor() end)
                        if not (cand and cand:IsValid()) then
                            stopProtection(true)
                            -- fresh actor vanished before the reveal: the same
                            -- post-commit no-reveal exit as the timeout above
                            -- (watcherDone first, same re-entry immunity)
                            watcherDone = true
                            announceEvolution(playerCtx, pair.from, targetId, level, "resummon")
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
                                refreshWorkSuitability(param, playerCtx, newActor)
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
                                        stopProtection(false) -- holder torn down: touch nothing
                                        held = true
                                        return true
                                    end
                                    local na = nil
                                    pcall(function() na = holder:TryGetSpawnedOtomo() end)
                                    if not (na and na:IsValid()) then
                                        stopProtection(true)
                                        held = true
                                        return true
                                    end
                                    if (os.clock() - holdStart) < 6.2 then
                                        if isAiActive(na) then setRevealFrozen(na, true) end
                                        return false
                                    end
                                    held = true
                                    setRevealFrozen(na, false)
                                    stopProtection(true)
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
                        stopProtection(true)
                        -- the reveal never went out (watcherDone was still
                        -- false): qualify the success line the requester
                        -- already read - the swap is committed either way
                        announceEvolution(playerCtx, pair.from, targetId, level, "resummon")
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
                -- deferred callback of the mod at once.
                -- LAW (crash #7, 2026-07-30): a "one-shot" LoopAsync is one-
                -- shot ONLY with an explicit fired-latch. `return true` alone
                -- silently depends on the body finishing inside the interval:
                -- v1.8.2's slower refresh pushed this body past the 100ms
                -- revealDelay and the loop re-fired the whole finisher every
                -- tick (seq.done stays false on the keepsFrozenUntilDone
                -- path until the FX prototype completes) - quadruple-running
                -- reveal FX until a census read hit freed memory. The remote
                -- reveal twin always carried this latch (its `rd`); every
                -- one-shot gets one now.
                local revealFired = false
                LoopAsync(fx.revealDelayMs(), function()
                    if revealFired then return true end
                    revealFired = true
                    ExecuteInGameThread(function()
                        if seq.done then return end
                        -- refetch: the reference may change after the spawn
                        local a = nil
                        pcall(function() a = holder:TryGetSpawnedOtomo() end)
                        if not (a and a:IsValid()) then a = newActor end
                        if not (a and a:IsValid()) then
                            Log(string.format("EVOLVED (data only): %s -> %s (level %d) - actor missing at reveal; please resummon manually",
                                pair.from, pair.to, level))
                            -- The owner already read the success prompt at the
                            -- commit; the pal will not come back on its own, so
                            -- qualify that line on screen instead of leaving a
                            -- UE4SS console entry no player will ever see.
                            announceEvolution(playerCtx, pair.from, targetId, level, "resummon")
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
                        -- the SUCCESS reveal: `a` is the revalidated fresh
                        -- actor of the NEW species - the one state where the
                        -- DB re-apply's unprobed internals cannot hit a dead
                        -- body. BEFORE the keepsFrozenUntilDone early return,
                        -- so every success sub-path refreshes (fix-verify
                        -- catch: the first placement sat in the FAILURE
                        -- fallback and the common path never refreshed).
                        refreshWorkSuitability(param, playerCtx, a)
                        pcall(function() param:FullRecoveryHP() end)
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
                    -- NO suitability refresh here: this is the respawn-not-
                    -- confirmed fallback, so this body is IsValid-but-NOT
                    -- proven to be the new species (fix-verify catch) - the
                    -- unverified-body state the hazard model excludes. The
                    -- resummoned pal shows its new styles after reload.
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
                -- Same retraction as the missing-actor branch above: the swap is
                -- committed and the owner has already been told it succeeded, but
                -- the body is unconfirmed. The wording holds whether or not the
                -- summon rescue put the pal back.
                announceEvolution(playerCtx, pair.from, targetId, level, "resummon")
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
                        -- landing settled (or the 10s cap gave up waiting):
                        -- the staged reveal starts inside finishRespawn
                        if panel then
                            Evolution.Toasts.progressUpdate("evolve", "Revealing", 0.9)
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
                    -- the two-phase activation took: the new species exists
                    -- as a hidden actor and only the settle is left
                    if panel then
                        Evolution.Toasts.progressUpdate("evolve", "Returning", 0.7)
                    end
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
    -- ("Ref was not function"), killing every deferred callback of the mod.
    -- Fired-latch per the crash-#7 law: dissolveMs is FX-supplied with no
    -- floor, and a re-fire here would start a second concurrent teardown
    -- chain - worst case a committed evolution refunded by its own twin.
    local teardownFired = false
    LoopAsync(dissolveMs, function()
        if teardownFired then return true end
        teardownFired = true
        ExecuteInGameThread(function()
            -- from here the despawn is OURS - the withdraw watch must stop
            -- reading absence as a player recall (same-thread, race-free)
            dissolvePhase = false
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

-- The anime beat (evolveNotify.flavorLine): announce "X is evolving?" first,
-- hold for flavorLeadMs, THEN start the real sequence. The gap runs under
-- the shared sequence lock - claimed here, before the first frame of delay -
-- so auto-evolve and the base sweep cannot slip a second sequence into it;
-- the watchdog's escape (currentAbort) is honored via the gap token and is
-- pure Lua (it can run off the game thread). The gap touches NO actor state:
-- performEvolution does its own freeze and position capture on entry, so
-- every gap abort is a pure lock release with nothing to restore, and no
-- cost or protection exists yet to unwind. A recall during the gap reads as
-- the dissolve window's cancel gesture (its snooze/chat extras honor the
-- withdrawCancels switch). With the feature off this is performEvolution
-- verbatim - zero behavioral change; with flavorLeadMs = 0 the line fires
-- and the sequence starts immediately.
local function startEvolutionWithFlavor(p)
    local en = Config.evolveNotify
    local leadMs = 0
    if en and en.enabled ~= false and en.flavorLine ~= false then
        -- config-derived number: math.floor + clamp, never %d
        leadMs = math.floor(tonumber(en.flavorLeadMs) or 1500)
        if leadMs < 0 then leadMs = 0 end
        if leadMs > 5000 then leadMs = 5000 end
    end
    -- flavor on, no pause requested: line first, sequence immediately (the
    -- documented flavorLeadMs = 0 contract)
    if leadMs == 0 then
        announceFlavor(p.playerCtx, p.pair,
            (p.isAlpha and (BOSS_PREFIX .. tostring(p.pair.from))) or p.pair.from)
        return performEvolution(p)
    end
    -- claim the lock for the gap; performEvolution re-stamps these on entry.
    -- The pal is deliberately NOT frozen during the beat: performEvolution
    -- captures position/height on entry (after the gap), so a wandering pal
    -- costs nothing but drama - while a wrapper-side freeze leaked its flag
    -- on every post-gap abort path and on dedicated servers (whose sequence
    -- never unfreezes; review majors x2). The beat is a toast and a pause.
    pending = nil
    sequenceRunning = true
    sequenceStartedAt = os.clock()
    local gap = { dead = false }
    currentAbort = function()
        -- watchdog escape; may run OFF the game thread (lockBusy runs in
        -- tick contexts) - pure Lua only, nothing to restore since the gap
        -- holds no actor state
        gap.dead = true
        sequenceRunning = false
        currentAbort = nil
    end
    announceFlavor(p.playerCtx, p.pair,
        (p.isAlpha and (BOSS_PREFIX .. tostring(p.pair.from))) or p.pair.from)
    LoopAsync(leadMs, function()
        ExecuteInGameThread(function()
            if gap.dead then return end
            gap.dead = true
            -- revalidate everything the gap could invalidate: the handles
            -- themselves and - the dissolve watcher's rule - that OUR pal is
            -- still the summoned otomo (a recall is the cancel gesture, and a
            -- recalled actor is pooled-but-valid, so IsValid alone is blind)
            local alive = false
            pcall(function()
                alive = (p.actor and p.actor:IsValid()
                    and p.param and p.param:IsValid()
                    and (not p.holder or p.holder:IsValid())) == true
            end)
            local recalled = false
            if alive and p.holder then
                local same = false
                pcall(function()
                    local cur = p.holder:TryGetSpawnedOtomo()
                    if cur and cur:IsValid() then
                        local cp = paramOf(cur)
                        same = (cp and cp:IsValid() and individualKey(cp) == p.key) == true
                    end
                end)
                recalled = not same
            end
            if alive and not recalled then
                -- a start failure here used to reach the requester
                -- synchronously (netchannel relayed the reason as a private
                -- [SYSTEM] line); with the beat in between, deliver it
                -- ourselves or the player sees a flavor toast and silence
                local started, reason = performEvolution(p)
                if not started and reason and p.playerCtx then
                    Role.chat(p.playerCtx, reason)
                end
                return
            end
            -- pure release: nothing was taken and nothing was touched during
            -- the gap, so there is nothing to restore
            sequenceRunning = false
            currentAbort = nil
            if recalled then
                Log("Evolution cancelled: pal withdrawn during the flavor beat")
                -- the cancel-gesture EXTRAS (snooze + chat) belong to the
                -- withdraw-to-cancel feature and honor its switch; the abort
                -- itself is unconditional - a pooled body cannot evolve
                if Config.withdrawCancels ~= false then
                    if p.key then
                        local lv = nil
                        pcall(function() lv = p.param:GetLevel() end)
                        if lv then autoSnooze[p.key] = lv end
                    end
                    if p.playerCtx then
                        Role.chat(p.playerCtx, I18n.msg("cancelWithdrawn"))
                    end
                end
            else
                Log("Evolution aborted: pal/holder no longer valid (flavor beat)")
            end
        end)
        return true
    end)
    return true
end

-- Guard for the connected-client transmit path: only hand an evolve request to a
-- host we have confirmed runs Palvolve. In the short window right after joining
-- the host's greet may not have arrived yet, and on a vanilla host the carrier
-- RPC would be interpreted as a plain otomo selection instead.
--
-- altMsg (FORK): the REJECTION callers route their reason through the host so it
-- arrives as a private [SYSTEM] line instead of an attributed one. When the
-- transmit is unavailable that reason has nowhere else to go, and telling the
-- player "the server check is pending" instead of "you have no Evolution Stone"
-- loses the only information they asked for. The pending state stays in the log;
-- the player gets the actual reason.
local function remoteTransmitReady(playerCtx, altMsg)
    if ServerCheck.remoteReady() then return true end
    local msg = I18n.msg("serverCheckPending")
    Log(msg)
    Role.chat(playerCtx, altMsg or msg)
    return false
end

-- ---------------------------------------------------------------- public API

function Evolution.check()
    if ServerCheck.blocked() then
        Role.chat(Role.localPlayerCtx(), I18n.msg("serverNoPalvolve"))
        return
    end
    -- stamped BEFORE the lock gate: a press that bounces off a running
    -- sequence is still player intent, and the pollers (auto-evolve, and the
    -- base sweep that shares the same lock) must yield to it rather than
    -- claim the lock the instant it frees
    lastManualActionAt = os.clock()
    if lockBusy() then
        Log(I18n.msg("evolutionRunning"))
        -- chatted, not just logged: during the flavor beat the only visible
        -- state is a toast, so a silent dead F2 reads as ignored input (the
        -- radial path already chats this same refusal)
        Role.chat(Role.localPlayerCtx(), I18n.msg("evolutionRunning"))
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
    local now = os.clock()
    local key = individualKey(param)
    if not costOk then
        local reason = I18n.msg("couldEvolveMissing",
            palDisplayName(pair.from), level, palDisplayName(pair.to), Costs.describeMissing(missing))
        Log(reason)
        local armedHere = pending and pending.key == key
            and (now - pending.armedAt) <= Config.confirmWindowSeconds
        if Role.hasWorldAuthority() then
            -- authority (single player / host): this check is final, show it here
            Role.chat(playerCtx, reason)
        elseif not armedHere then
            -- FORK: upstream transmits from here on the FIRST press too. The
            -- client-side inventory read fails CLOSED to zero (costs.lua
            -- countItem), so a read that only breaks on THIS machine would hand
            -- the host a live evolve request the host - reading the real
            -- inventory - accepts and charges, one press into a two-press
            -- confirm flow. The confirm gate is what stands between a mis-press
            -- and spent materials, so it holds on every path: press one shows
            -- the reason locally and arms, press two carries it to the host.
            Role.chat(playerCtx, reason)
            pending = { armedAt = now, key = key, pair = pair }
        elseif remoteTransmitReady(playerCtx, reason) then
            -- pure client, CONFIRM press: emitting the reason locally would
            -- attribute it to the player ("[Name]: ..."). Send the request
            -- instead so the host rejects it and delivers the reason as a
            -- private [SYSTEM] line; the host re-checks and consumes nothing on
            -- a rejected evolve. lastRemotePair is armed for the case the host
            -- DISAGREES and evolves: it is read only on acceptance, and leaving
            -- it nil (or stale from an earlier pal) would make the client reveal
            -- announce the wrong species with no element bursts.
            pending = nil
            lastRemotePair = pair
            NetChannel.sendEvolve(playerCtx, pairIndex or 0)
        end
        return
    end

    if pending and (now - pending.armedAt) <= Config.confirmWindowSeconds then
        if pending.key == key then
            if Role.hasWorldAuthority() then
                -- use FRESH handles (the pal may have been resummoned since arming)
                startEvolutionWithFlavor({ actor = actor, param = param, pair = pair, holder = holder,
                    key = key, isAlpha = isAlpha, playerCtx = playerCtx })
            else
                -- connected client: the confirm travels to the host, which
                -- re-derives and consumes authoritatively
                if not remoteTransmitReady(playerCtx) then return end
                pending = nil
                -- the host-driven local re-play reads this for the element
                -- staging and the announced name (same as executeOption)
                lastRemotePair = pair
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

-- Why the radial entry was last greyed, and which causes the player has already
-- been told about. canOffer runs on every wheel rebuild, so the reason is written
-- only when it CHANGES - logging every call would put one line per frame in the
-- file, and logging nothing is what shipped the bug this replaces: "not your
-- pal", "nothing configured for this species" and "host not confirmed" all
-- render the same grey entry and were otherwise indistinguishable.
-- ONE table, not four locals: this chunk sits near Lua's 200 top-level-local
-- ceiling and every name spent here is a name the next feature cannot have.
local Diag = {
    lastOfferReason = nil,  -- the log reason currently in force, nil while offered
    toldReasons = {},       -- player-facing lines already spent, keyed by text
}

-- Player-facing half of the verdict. The log line names the cause for support;
-- this names it for the person looking at a grey entry, who otherwise gets
-- nothing to act on. Once per distinct cause per session - at wheel-rebuild rate
-- anything less selective is chat spam - and through the same surfaces (and the
-- same evolveNotify truth table) announceEvolution uses, so a player who turned
-- prompts off does not start getting these instead. Always the LOCAL player:
-- canOffer only ever judges this machine's own wheel.
-- ATTRIBUTION, not caution: canOffer is called by the radial wheel from INSIDE
-- its bracketed injection window (radialmenu.lua pcalls it between an "entering
-- canOffer" crumb and its closer). A native fault in a toast or a chat line
-- fired from here would therefore be read off the crash-#8 ladder as "canOffer
-- killed the process", and the wrong suspect would be convicted. So this half
-- runs no native at all: it decides in pure Lua and hands the announce to a
-- one-tick deferral - the chatcommands shape, fired-latch per the crash-#7 law -
-- by which time the wheel's window is long closed.
function Diag.tell(msg)
    if type(msg) ~= "string" or msg == "" or Diag.toldReasons[msg] then return end
    local off = not Config.evolveNotify or Config.evolveNotify.enabled == false
    if off then return end
    -- Latched BEFORE scheduling, exactly as the synchronous version latched
    -- before it announced: canOffer runs at wheel-rebuild rate, and a second
    -- call arriving before the tick fires must not queue the same line twice.
    -- The cause is still spent only once a surface was actually TRIED, so the
    -- deferred half puts it back when the world has no local player yet -
    -- otherwise the one line the player was owed would be eaten silently.
    Diag.toldReasons[msg] = true
    local told = false
    LoopAsync(1, function()
        if told then return true end
        told = true
        ExecuteInGameThread(function()
            pcall(function()
                local playerCtx = Role.localPlayerCtx()
                if not playerCtx then
                    Diag.toldReasons[msg] = nil
                    -- verdict() only re-tells on a CHANGED reason string; an
                    -- identical reason recurring after this un-latch would
                    -- otherwise never be delivered (fix-verify 7b).
                    Diag.lastOfferReason = nil
                    return
                end
                -- no target species here, so the toast goes out without a
                -- portrait (the helper's icon step is guarded on the id and
                -- simply skips)
                pcall(localEvolutionToast, playerCtx, msg, nil)
                if Config.evolveNotify.chatFallback ~= false then
                    pcall(Role.chat, playerCtx, "[Palvolve] " .. msg)
                end
            end)
        end)
        return true
    end)
end

function Diag.verdict(reason, playerMsg)
    if reason ~= Diag.lastOfferReason then
        Diag.lastOfferReason = reason
        Log(reason and ("Evolve unavailable: " .. reason) or "Evolve available")
        if reason then Diag.tell(playerMsg) end
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
        Diag.verdict("this host is not confirmed as a Palvolve host",
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
        -- ownership is judged AFTER the id is read, so the refusal can name the
        -- pal it is about; a traded or gifted pal keeps the original catcher in
        -- its save record and reads as someone else's while sitting in this
        -- player's own party
        local id = baseCharacterId(param:GetCharacterID():ToString())
        if not isOwnedBy(param, playerCtx and playerCtx.playerUId) then
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
        Diag.verdict("availability check failed: " .. tostring(reason))
        return false
    end
    Diag.verdict(reason, playerMsg)
    -- the external contract is unchanged: radialmenu pcalls this and wants a
    -- plain boolean, never the reason
    return reason == nil
end

-- The middle of the radial is a circle, not a line. A pair with six conditions
-- and nine materials produces roughly 200 characters, so the text is wrapped per
-- kind instead of being handed over as one run that would leave the circle on
-- both sides.
local CENTER_WIDTH = 30
-- The circle has room for a handful of lines, not for a shopping list. Past this
-- the price is summarised instead, so an absurd config cannot push the text out
-- of the ring.
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

-- The requirements of one target as wrapped lines: level, then conditions, then
-- price. The target's own name is left out because the wheel segment already
-- carries it. Costs resolve against the pair's MINIMUM level, the earliest point
-- the price applies, which is the level the guide pages quote too - not the
-- pal's current level, which would price the same route differently on the wheel
-- than in the guide.
-- I18n.msg hands back the bare key when a catalog has no row for it, and the two
-- short keys here arrive with the guide pages; until then the format falls back
-- to plain English rather than printing "guideLevelShort" into the ring.
local function requirementLine(pair, level, worldCtx)
    local function short(key, fallback, ...)
        local text = I18n.msg(key, ...)
        if text == key then return string.format(fallback, ...) end
        return text
    end
    local lines = {}
    local minLevel = math.floor(tonumber(pair.minLevel) or 0)
    -- config-derived number: never %d (a float throws in 5.4)
    if minLevel > 0 then
        wrapText(short("guideLevelShort", "Lv %g", minLevel), CENTER_WIDTH, lines)
    end

    local okCond, cond = pcall(Conditions.describe, pair)
    if okCond and cond and cond ~= "" then wrapText(cond, CENTER_WIDTH, lines) end

    -- where the price starts, so the cap below knows which tail is which
    local priceAt = #lines + 1
    local okCost, costList = pcall(Costs.resolve, pair, minLevel, worldCtx)
    if okCost and type(costList) == "table" and #costList > 0 then
        local before = #lines
        local okDesc, text = pcall(Costs.describe, costList)
        if okDesc and text and text ~= "" then
            wrapText(text, CENTER_WIDTH, lines)
            -- A price that does not fit is replaced by its own summary rather
            -- than cut mid-list, so the player still learns there IS a cost and
            -- how big it is. The full list is on the guide page.
            if #lines > CENTER_MAX_LINES then
                for i = #lines, before + 1, -1 do lines[i] = nil end
                wrapText(short("costItemCount", "%g items", #costList),
                    CENTER_WIDTH, lines)
            end
        end
    end

    -- The cap is on the WHOLE text, not on the price alone. Summarising the
    -- price bounds the price; a pair with a wall of conditions fills the ring on
    -- its own and pushed that summary straight back out of it, which is how a
    -- line meant to keep the text inside the circle ended up outside it. The cut
    -- therefore comes out of the tail of the CONDITIONS - the price (or its
    -- summary) is the one thing the player cannot read anywhere else on this
    -- screen - and the summary counts inside the cap like every other line.
    while #lines > CENTER_MAX_LINES do
        if priceAt > 2 then
            table.remove(lines, priceAt - 1)
            priceAt = priceAt - 1
        else
            -- nothing left to give: the price itself is what overflows
            table.remove(lines)
        end
    end

    if #lines == 0 then return nil end
    return table.concat(lines, "\n")
end

-- All evolution/adaptation options for the currently summoned pal with
-- affordability info - feeds the radial submenu. Returns nil, reason when
-- nothing is available.
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
        -- What this target asks for, short enough for a wheel segment and phrased
        -- the way the guide pages phrase it. Without it the wheel names targets
        -- and nothing else, so the only way to learn what an evolution costs was
        -- to try it and read the refusal. Rendering is the radial's business;
        -- the contract here is just "string or nil".
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
            -- the requirement text belongs to the pair, so it moves with it:
            -- leaving the loser's line in place would price the surviving
            -- variant by the conditions of the one it replaced
            existing.requirement = opt.requirement
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
-- freeOnly marks a client's auto-evolve request: it may not consume anything,
-- so a non-empty host-resolved cost list is rejected instead of charged.
local function handleEvolveRequest(playerCtx, fromId, toId, freeOnly)
    -- A MANUAL request is player intent, whoever sent it: on a host the
    -- requester may be a connected client, whose F2/radial press the local
    -- lastManualActionAt would otherwise never see - and the base sweep
    -- (which takes the same shared lock) must yield to it exactly as it does
    -- for the local player. Stamped BEFORE the lock gate so a busy-rejected
    -- press still registers the intent. Auto-evolve requests (freeOnly) are
    -- not manual and must never extend their own yield window.
    if freeOnly ~= true then lastManualActionAt = os.clock() end
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
                -- freeOnly must mirror findEligibleFor's requireFree gate
                -- INSIDE the candidate loop: with either/or variants a
                -- costed sibling can precede the free one the client
                -- actually picked, and rejecting here would break MP
                -- auto-evolve on configs that work fine in SP
                if freeOnly and #Costs.resolve(cand, level, holder) > 0 then
                    failReason = failReason
                        or "Auto-evolve skipped: this evolution has a cost on the server"
                else
                    pair = cand
                    break
                end
            else
                failReason = failReason or I18n.msg("needsConditions", palDisplayName(cand.to), unmet)
            end
        end
    end
    if not pair then
        return false, failReason or "Conditions not met"
    end
    -- fresh cost pre-check for a readable message; the transaction inside
    -- performEvolution is the authoritative consume
    local costList = Costs.resolve(pair, level, holder)
    if freeOnly and #costList > 0 then
        -- belt over the loop gate above: an auto request may never charge
        return false, "Auto-evolve skipped: this evolution has a cost on the server"
    end
    local costOk, missing = Costs.check(playerCtx, costList)
    if not costOk then
        return false, I18n.msg("couldEvolveMissing",
            palDisplayName(id), level, palDisplayName(pair.to), Costs.describeMissing(missing))
    end
    -- ok = the sequence STARTED; asynchronous stage failures surface via
    -- the sequence's own logging/abort handling (the network layer sends
    -- no completion acknowledgements)
    local started, reason = startEvolutionWithFlavor({ actor = actor, param = param, pair = pair,
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
local function handleEvolveByIndex(playerCtx, pairIndex, freeOnly)
    -- same manual-intent stamp as handleEvolveRequest, at the FIRST host-side
    -- line a remote press reaches: the early returns below (no pal summoned,
    -- stale option index) exit before that handler ever runs
    if freeOnly ~= true then lastManualActionAt = os.clock() end
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
    local ok, msg = handleEvolveRequest(playerCtx, baseId, pair.to, freeOnly)
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
    lastManualActionAt = os.clock()
    local playerCtx = Role.localPlayerCtx()
    -- the option was greyed out in the wheel (missing materials, too low a
    -- level, no Alpha form): the reason goes to the player chat, not
    -- only to the log
    if opt.blocked then
        Log(opt.blocked)
        if Role.hasWorldAuthority() then
            Role.chat(playerCtx, opt.blocked)
        elseif remoteTransmitReady(playerCtx, opt.blocked) then
            -- pure client: don't attribute the reason locally ("[Name]: ..."). Send
            -- the picked option so the host re-validates and rejects it with a
            -- private [SYSTEM] line; the host consumes nothing on a rejected evolve.
            -- Unlike the F2 path there is no confirm to protect here - the submenu
            -- click IS the confirmation (see the function header), so a host that
            -- reads a greyed-out gate differently and accepts is doing what the
            -- player asked for. Arm lastRemotePair for exactly that case: it is
            -- read only on acceptance, and a nil (or stale) pair would make the
            -- client reveal name the wrong species and drop its element bursts.
            lastRemotePair = opt.pair
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
            Role.chat(playerCtx, msg)
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
            Role.chat(playerCtx, msg)
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
    -- NO DarnToasts progress panel on this path, deliberately - see the note
    -- on Evolution.onNetSignal below. The relayed prompt itself still goes
    -- through the channel (netchannel.lua's showRelayedToast); it is only the
    -- sticky panel that stays singleplayer/listen-host-owner side.
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
--
-- NO DarnToasts progress panel here, and the reason is termination, not
-- taste. This presentation has no bounded end: three of the host watcher's
-- exits (reload timeout, fresh actor vanished, the 20s hard deadline) send NO
-- reveal signal at all, and the only stall guard on this side is armed inside
-- the reveal branch - so a sequence that dies before the reveal leaves nothing
-- to close a panel with. Covering that needs either a new watchdog loop (the
-- house rules forbid one) or re-timing the existing stall loop, which is
-- shipped MP lifecycle logic and not something a cosmetic panel gets to move.
-- A panel that outlives its sequence is a bug, so this path shows none: the
-- relayed prompt and the flavor line still ride the DarnToasts channel through
-- netchannel.lua, which is where the MP player actually reads them.
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
        -- Every client path that can make the host signal "start" arms
        -- lastRemotePair first (confirm press, radial pick, auto-evolve, and the
        -- rejection sends that the host may still accept). If it is somehow nil
        -- anyway, stay silent instead of dropping a hard-coded English "its new
        -- form" into a localized sentence - the host's own announce names the
        -- real species, so nothing is lost and nothing contradicts it.
        if lastRemotePair then
            -- notification-class chat: honors the SAME contract as every
            -- other unsolicited line (enabled first, then chatFallback -
            -- announceEvolution's wantChat; v1.7.4)
            local en = Config.evolveNotify
            if en and en.enabled ~= false and en.chatFallback ~= false then
                Role.chat(playerCtx, I18n.msg("evolvingInto", palDisplayName(lastRemotePair.to)))
            end
        end
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

-- ------------------------------------------------------------- poller caches

-- Both long-lived pollers below (auto-evolve, primed pals) used to re-derive
-- everything they touch from the global object array on EVERY tick. FindAllOf
-- is a linear sweep over ALL loaded UObjects - its cost scales with the total
-- object count, not with the number of matches - so a scanner doing one (in
-- combat: two) of them on the game thread every couple of seconds is exactly
-- the periodic hitch a player feels. The fix is the one that killed the
-- Palpedia tab stutter in 1.4.3: capture the refs once, let the ticks touch
-- cached refs only, and rescan ONLY when a cache misses. An IsValid miss is
-- precisely what a despawn, a logout or a world change produces, so
-- refresh-on-miss IS the invalidation - no extra teardown hook is needed to
-- keep a dead world's refs out of the ticks.
--
-- Module state, declared ABOVE every closure that captures it (house rule).

-- The local player's controller, shared by both pollers. HasAuthority() is a
-- property of that controller INSTANCE (a world change builds a new one), so
-- the authority answer is cached alongside it instead of being re-scanned for.
local localPcCache = nil
local localAuthorityCache = false

-- The one FindAllOf both pollers used to pay on every tick, now paid only when
-- the cached ref dies (world change, relog, disconnect).
local function refreshLocalPc()
    localPcCache = Role.getLocalPlayerController()
    localAuthorityCache = false
    if localPcCache and localPcCache:IsValid() then
        pcall(function() localAuthorityCache = localPcCache:HasAuthority() == true end)
    else
        localPcCache = nil
    end
    if Config.devMode then
        Log(string.format("[cache] local controller refreshed (%s, authority %s)",
            localPcCache and "found" or "none", tostring(localAuthorityCache)))
    end
end

local function localPc()
    if not (localPcCache and localPcCache:IsValid()) then refreshLocalPc() end
    return localPcCache
end

-- Same answer as Role.hasWorldAuthority(), without its per-call scan (role.lua
-- keeps its scanning semantics for every other caller).
local function cachedWorldAuthority()
    if Role.isDedicated() then return true end
    local pc = localPc()
    if not pc then return false end
    if not localAuthorityCache then
        -- a NEGATIVE answer is never latched: an actor's HasAuthority is not
        -- settled the instant a world comes up (servercheck.lua documents the
        -- same trap for its own classification), so caching a "no" read at
        -- world entry would silently disable the scanner on a host for the
        -- whole session. Re-reading it is one property call on a ref we
        -- already hold - no scan - and it stops the moment it answers yes.
        pcall(function() localAuthorityCache = pc:HasAuthority() == true end)
    end
    return localAuthorityCache
end

-- Same as Role.localPlayerCtx(); playerCtxFor is property reads only, so only
-- the controller lookup it wraps ever needed caching.
local function cachedLocalPlayerCtx()
    local pc = localPc()
    if not pc then return nil end
    return Role.playerCtxFor(pc)
end

-- devMode tick-cost telemetry: per-60s-window tick count, total and max
-- duration. Pure Lua (two adds and a compare per tick), one log line a minute,
-- and the reporting loops are not started at all when devMode is off.
local tickStats = {
    primed = { n = 0, sum = 0, max = 0 },
    autoevolve = { n = 0, sum = 0, max = 0 },
    baseevolve = { n = 0, sum = 0, max = 0 },
}

local function recordTick(name, seconds)
    local s = tickStats[name]
    if not s then return end
    s.n = s.n + 1
    s.sum = s.sum + seconds
    if seconds > s.max then s.max = seconds end
end

-- mirrors wildfilter.lua's 60s window: silent when nothing ran. `gate` exists
-- only while the primed situational gate is active (armed at primedGate), so
-- the suffix is absent for every other window and every other loop.
local function reportTicks(name)
    local s = tickStats[name]
    if not (s and s.n > 0) then return end
    local extra = ""
    if s.gate then
        extra = string.format(", gate-blocked %g", s.gate)
        s.gate = 0
    end
    Log(string.format("[%s] 60s: %g ticks, avg %.2f ms, max %.2f ms%s",
        name, s.n, (s.sum / s.n) * 1000, s.max * 1000, extra))
    s.n, s.sum, s.max = 0, 0, 0
end

-- ---------------------------------------------------------------- auto-evolve

-- Config-gated poller (Config.autoEvolve): evolves the local player's
-- summoned pal without any prompt the moment every gate passes AND the
-- evolution is completely free (findEligibleFor's requireFree gate - an
-- empty resolved cost list). Costed pairs never auto-fire; they keep the
-- radial/F2 prompt flows. Runs on the player's own machine only, exactly
-- like the confirm keybind: a dedicated server has no local player, and
-- every connected client polls its own pal and requests over the net -
-- flagged free-only, so a host with different cost config rejects instead
-- of silently charging (see handleEvolveRequest).
local autoAttemptAt = {} -- individualKey -> { t, id, tries }

local function autoEvolveTick()
    -- in-game options: pure-Lua generation check, self-throttled to ~2s, before
    -- any gameplay work. One of SEVERAL independent drivers - this one is armed
    -- only while autoEvolve.enabled, itself a row in that menu (modoptions.lua)
    if ModOptions then pcall(ModOptions.pump) end
    local cfg = Config.autoEvolve or {}
    if ServerCheck.blocked() then return end
    if lockBusy() then return end
    -- yield to the player: never race a manual F2/radial interaction (the
    -- per-sender net rate budget must stay theirs), never fire while an F2
    -- confirm is armed, and never while a remote reveal is still playing
    -- (a second 'start' signal would be swallowed by remoteRevealBusy).
    -- The busy check mirrors the start-handler's 20s staleness escape: a
    -- lost 'reveal' signal must not disable auto-evolve for the session.
    if Evolution.isArmed() then return end
    if remoteRevealBusy and (os.clock() - remoteRevealStart) < 20 then return end
    if (os.clock() - lastManualActionAt) < 10 then return end
    -- cached controller: Role.localPlayerCtx() and Role.hasWorldAuthority()
    -- each do their own FindAllOf("PalPlayerController"), so this tick used to
    -- sweep the whole object array TWICE. Same gate order, same values - only
    -- the source of the controller changed.
    local playerCtx = cachedLocalPlayerCtx()
    if not playerCtx then return end
    local authority = cachedWorldAuthority()
    -- connected client: transmit only to a CONFIRMED Palvolve host. During
    -- the join-greet window an auto-fire would vanish silently on a vanilla
    -- host - the exact half-working state servercheck exists to prevent.
    if not authority and not ServerCheck.remoteReady() then return end
    local actor, param, pair, level, holder, isAlpha, pairIndex =
        findEligibleFor(playerCtx, true)
    if not actor then return end
    local key = individualKey(param)
    -- withdraw-to-cancel snooze: the player pulled this pal out of an
    -- evolution at this level - hands off until it levels past that
    local snoozedLvl = autoSnooze[key]
    if snoozedLvl then
        if level <= snoozedLvl then return end
        autoSnooze[key] = nil
    end
    local now = os.clock()
    local cd = math.max(1, tonumber(cfg.cooldownSeconds) or 30)
    -- per-individual spacing with backoff: if the species has NOT changed
    -- since the last attempt, that attempt failed or was rejected (e.g.
    -- host-side condition or cost-config skew) - double the wait each time,
    -- capped, so a standing rejection cannot spam the host or the chat
    local entry = autoAttemptAt[key]
    if entry then
        local wait = cd
        if entry.id == pair.from then
            -- never below the base cooldown: with a large user cooldown the
            -- 300s cap must not turn the failure path into a SPEED-UP
            wait = math.max(cd, math.min(300, cd * (2 ^ math.min(entry.tries - 1, 8))))
        end
        if (now - entry.t) < wait then return end
    end
    -- prune before insert so a long session cannot grow the table unbounded
    local pruneAfter = math.max(900, cd * 4)
    for k, e in pairs(autoAttemptAt) do
        if (now - e.t) > pruneAfter then autoAttemptAt[k] = nil end
    end
    autoAttemptAt[key] = {
        t = now, id = pair.from,
        tries = (entry and entry.id == pair.from) and (entry.tries + 1) or 1,
    }
    if authority then
        Log(string.format("Auto-evolve: %s -> %s (Lv %d, free)", pair.from, pair.to, level))
        local started = startEvolutionWithFlavor({ actor = actor, param = param, pair = pair,
            holder = holder, key = key, isAlpha = isAlpha, playerCtx = playerCtx })
        if started then
            -- notification-class chat: honors the full contract (enabled,
            -- then chatFallback; v1.7.4). It also names the TARGET during
            -- the flavor beat's pause, so with the beat on it was a spoiler
            -- as well as a duplicate.
            local en = Config.evolveNotify
            if en and en.enabled ~= false and en.chatFallback ~= false then
                Role.chat(playerCtx, I18n.msg("evolvingInto", palDisplayName(pair.to)))
            end
        end
    else
        -- fire-and-forget, like the radial path: the host re-derives and
        -- re-validates everything from the option index (and, for this
        -- free-flagged opcode, additionally refuses to consume anything);
        -- a rejection comes back as a private chat line
        Log(string.format("Auto-evolve request: %s -> %s (option %d)",
            pair.from, pair.to, pairIndex or 0))
        -- the host-driven local re-play reads this for the element staging
        -- and the announced name (same as executeOption)
        lastRemotePair = pair
        NetChannel.sendEvolve(playerCtx, pairIndex or 0, true)
    end
end

-- --------------------------------------------------------------- primed pals

-- Primed Pals (Config.primedPals): some wild pals are primed to evolve -
-- their level already satisfies one of their species' evolutions - and when
-- a fight pushes their HP below the threshold, they evolve on the spot.
-- Primed status is a DETERMINISTIC per-individual roll (djb2 of the
-- instance id against the configured chance), so the same pal is primed in
-- every session with zero saved state; environmentChance entries raise or
-- lower the bar while the pal itself satisfies that condition (a Mau that
-- is not primed in grassland can be primed in the desert).
--
-- Authority-only, combat-gated, and deliberately CATCHABLE: through the
-- telegraph the pal keeps its low HP (sphere odds stay juicy) and is only
-- death-flagged, and every deferred stage re-checks ownership - a sphere
-- that lands cancels the evolution and the player keeps the UN-evolved pal.
-- The swap itself is the same param rewrite as player evolutions (identity,
-- gender, Lucky and Alpha preserved; IV bonus + full heal applied); the
-- actor is rebuilt through the character manager's own handle respawn
-- (SpawnCharacterByHandle - DespawnCharacterByHandle's sibling, nil
-- callback exactly like that proven call). No costs, no snapshot: wild
-- pals pay nothing and are not the player's to roll back.
local primedTriggered = {}   -- individualKey -> true (one evolution per session)
local primedBusyAt = nil     -- os.clock() while a wild sequence runs (single
                           -- flight; the scanner watchdogs a stale stamp)
local primedRunSeq = 0       -- run token so a stale run's finish cannot clear
                           -- a newer run's busy stamp
local primedActorClass = nil -- resolved once: which FindAllOf name yields pals
local primedScanOffset = 0   -- rotating scan start so a horde at the head of
                           -- the actor list cannot starve later candidates

-- Build-variant FindAllOf names, in preference order, for SEEDING the registry
-- and for the legacy per-tick list: BP_MonsterBase_C is what the level-up hook
-- targets, the native base is the fallback when the BP yields nothing.
local PRIMED_CLASSES = { "BP_MonsterBase_C", "PalMonsterCharacter" }

-- The registry notify attaches to the NATIVE base and NEVER to the BP class.
-- NotifyOnNewObject cannot be unregistered, so a notify armed on
-- BP_MonsterBase_C in world A would still be attached for the title screen's
-- menu-pal construction and for every later world-load actor storm - the
-- documented process-abort trap (the same reason the level-up hook may only be
-- attached behind the two-stable-polls gate). UE4SS' notify dispatch is
-- inheritance-aware in this build - benchvisual.lua catches derived BP bench
-- actors off native PalBuildObject - so the native base still sees every
-- BP_MonsterBase_C instance, and its class object is process-stable.
local PRIMED_NOTIFY_PATH = "/Script/Pal.PalMonsterCharacter"

-- ---- scanner caches (declared ABOVE every closure that captures them) ------
local primedUtilCache = nil      -- PalUtility CDO
local primedBattleMgrCache = nil -- per-world battle manager
-- CONTROLLERS, not pawns: a pawn ref caches a player's CURRENT body, and a
-- death/respawn or a joiner whose pawn possesses a moment after its controller
-- was built would then stay invisible until the next refresh. Controllers are
-- the stable identity; the pawn list is derived from them fresh every tick
-- through property reads only (no scan), so respawn and join freshness is
-- automatic on the very next tick.
local primedPcCache = {}
local primedPcAt = 0             -- os.clock() of the last controller rebuild
local primedStandalone = false   -- single player: one controller, for the
                                 -- life of the world - never goes stale
local primedPcDirty = false      -- set by the PalPlayerController notify: a
                                 -- controller appeared (a join, or the local
                                 -- player entering a new world), so the list
                                 -- needs rebuilding even though every ref
                                 -- already in it is still valid

-- Monster-actor registry: replaces the in-combat FindAllOf. Fed by
-- NotifyOnNewObject (armed behind the two-stable-polls gate in Evolution.init
-- on hosts, or by the bounded in-tick attempt in primedTick for dedicated
-- servers and a client-turned-host session) and seeded from a single FindAllOf
-- for the actors that already existed when the notify was armed.
local primedRegistry = {}
local primedRegistryArmed = false -- false = no notify -> legacy per-tick scan
local primedTickArmTries = 0      -- bounded in-tick arming: covers dedicated servers
                                  -- (init's arm machine is non-dedicated-only) and a
                                  -- client-turned-host session whose budget lapsed
local primedRegistryStale = true  -- a re-seed is pending (arm / world change)
local primedSeedAt = 0            -- os.clock() of the last seed SCAN
-- Hard cap for the notify callback. On a connected client the scanner never
-- runs, so nothing there ever sweeps the registry; the cap bounds it instead
-- of leaking one ref per wild pal for the rest of the session.
local PRIMED_REGISTRY_MAX = 4096
-- Out of combat nothing reads the registry, so it is only swept once it has
-- grown past this (in combat every tick sweeps it anyway).
local PRIMED_SWEEP_BOUND = 768
-- Join-detection safety net UNDER the controller notify: a listen host or a
-- dedicated server can gain a player at any moment, so the controller list is
-- rebuilt at least this often even when every cached ref is still valid.
-- Standalone is exempt (one controller per world), which is where the stutter
-- was reported - there the steady state is genuinely scan-free.
local PRIMED_PC_MAX_AGE_S = 30
-- Floor between MISS-driven seeds, so an in-combat registry that is genuinely
-- empty cannot turn refresh-on-miss into a scan every single tick.
local PRIMED_MISS_SEED_MIN_S = 10

-- ONE FindAllOf; every other tick reads primedPcCache directly.
local function primedRefreshControllers(why)
    primedPcDirty = false
    local pcs = {}
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        if pc:IsValid() then pcs[#pcs + 1] = pc end
    end
    primedPcCache = pcs
    primedPcAt = os.clock()
    -- net mode via the world context, exactly as servercheck classifies a
    -- world entry; unreadable biases to "not standalone" (keeps the net)
    primedStandalone = false
    pcall(function()
        local k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if k and k:IsValid() and pcs[1] then
            primedStandalone = k:IsStandalone(pcs[1]) == true
        end
    end)
    if Config.devMode then
        Log(string.format("[primed] controller cache refreshed (%g, %s)", #pcs,
            tostring(why)))
    end
    return #pcs
end

-- Pawn/controller cache invalidation without a scan: a controller appearing
-- means a player joined, or the local player entered a new world. Native
-- class, a handful of instances, no BP class-load storm to ride - the same
-- init-time notify pattern benchfilter.lua ships. The monster registry's
-- notify is NOT safe here; it rides the two-polls gate in Evolution.init. The
-- callback is minimal: flip a flag, nothing else. Shared by the primed
-- scanner and the base auto-evolve sweep, so it is armed by whichever of the
-- two is enabled (idempotent - the second call is free).
local pcNotifyArmed = false
local function armPcNotify()
    if pcNotifyArmed then return end
    pcNotifyArmed = true
    local ok = pcall(NotifyOnNewObject, "/Script/Pal.PalPlayerController",
        function()
            pcall(function() primedPcDirty = true end)
        end)
    if not ok then
        Log("[primed] controller notify unavailable - pawn cache relies on "
            .. "empty/age refresh")
    end
end

-- The live player CONTROLLERS for one tick: the cached list compacted in
-- place, with a scan paid only when the cache is empty, the notify flagged a
-- join, or the multiplayer staleness net expires. Shared by both authority
-- pollers so the cost is paid once no matter how many of them run.
--
-- Cadence note for the SLOW reader: PRIMED_PC_MAX_AGE_S is 30s and the base
-- sweep runs at 45s, so on a non-standalone host (where the age net applies at
-- all) every base sweep finds the cache stale and pays one
-- FindAllOf("PalPlayerController"). That is the pre-existing join-detection
-- precedent, not something the base feature added - but it does mean "no scan
-- in the steady state" is only literally true for standalone, and for the
-- MONSTER list everywhere. Cheap either way: a handful of controllers.
--
-- World-change invalidation, without a dedicated teardown hook: ONLY "empty" -
-- every controller in the process gone - means the world itself went away, and
-- a world reload always passes through that state, so it is the one reason
-- that re-seeds the monster registry. A mid-session join ("newpc") cannot
-- invalidate a monster ref, and the periodic "age" refresh is join detection
-- only; re-seeding on either would just buy a spurious full scan.
local function livePlayerControllers()
    local pcs = primedPcCache
    local live = 0
    for i = 1, #pcs do
        local pc = pcs[i]
        if pc and pc:IsValid() then
            live = live + 1
            if live ~= i then pcs[live] = pc end
        end
    end
    for i = #pcs, live + 1, -1 do pcs[i] = nil end
    local refreshWhy = nil
    if live == 0 then
        refreshWhy = "empty"
    elseif primedPcDirty then
        refreshWhy = "newpc"
    elseif not primedStandalone
        and (os.clock() - primedPcAt) > PRIMED_PC_MAX_AGE_S then
        refreshWhy = "age"
    end
    if refreshWhy then
        if refreshWhy == "empty" then primedRegistryStale = true end
        primedRefreshControllers(refreshWhy)
        pcs = primedPcCache
    end
    return pcs
end

-- Drop dead refs in place, order-preserving: primedScanOffset is an index into
-- this list, so a stable order keeps the round-robin fair.
local function primedSweepRegistry()
    local reg = primedRegistry
    local live = 0
    for i = 1, #reg do
        local a = reg[i]
        if a and a:IsValid() then
            live = live + 1
            if live ~= i then reg[live] = a end
        end
    end
    for i = #reg, live + 1, -1 do reg[i] = nil end
    return live
end

-- Re-seed from a single FindAllOf. Clearing FIRST is what makes a dedupe pass
-- unnecessary: this and the notify callback both run on the game thread, so no
-- spawn can slip in between the clear and the scan. A scan that legitimately
-- finds NOTHING still counts as seeded (the stale flag clears either way) -
-- an empty world must not re-scan on every following tick.
local function primedSeedRegistry()
    primedRegistryStale = false
    primedSeedAt = os.clock()
    local list = {}
    local name = primedActorClass
    if name then
        for _, a in ipairs(FindAllOf(name) or {}) do
            if a and a:IsValid() then list[#list + 1] = a end
        end
    else
        -- class not resolved yet: the seed scan doubles as the resolution
        -- (first name that yields instances wins, exactly as before)
        for _, cname in ipairs(PRIMED_CLASSES) do
            local all = FindAllOf(cname) or {}
            if #all > 0 then
                primedActorClass = cname
                name = cname
                for _, a in ipairs(all) do
                    if a and a:IsValid() then list[#list + 1] = a end
                end
                break
            end
        end
    end
    primedRegistry = list
    if Config.devMode then
        Log(string.format("[primed] registry seeded from %s (%g)",
            tostring(name), #list))
    end
    return true
end

-- The actor list for one tick. Steady state: a pure-Lua sweep over cached
-- refs, ZERO object-array scans. A scan happens only on a pending re-seed
-- (arm / world change) or, at most once every PRIMED_MISS_SEED_MIN_S, when the
-- registry came up empty in combat - the refresh-on-miss net under a notify
-- that somehow never fired. Returns nil when the registry is not armed, so the
-- caller keeps the legacy scan.
local function primedScanList()
    if not primedRegistryArmed then return nil end
    local seeded = false
    if primedRegistryStale then seeded = primedSeedRegistry() end
    primedSweepRegistry()
    if #primedRegistry == 0 and not seeded
        and (os.clock() - primedSeedAt) > PRIMED_MISS_SEED_MIN_S then
        primedSeedRegistry()
    end
    return primedRegistry
end

-- Arms the registry: attach the notify to the native base, then seed. MUST NOT
-- be called before a world is up and settled - see the caller's trap note.
-- Idempotent: the armed early-return makes repeated attempts free.
local function armPrimedRegistry()
    if primedRegistryArmed then return true end
    local ok = pcall(NotifyOnNewObject, PRIMED_NOTIFY_PATH, function(obj)
        -- fires DURING object construction on the game thread: stash the ref,
        -- nothing else. Sweeping and validation happen in the tick.
        pcall(function()
            local n = #primedRegistry
            if n < PRIMED_REGISTRY_MAX then primedRegistry[n + 1] = obj end
        end)
    end)
    if not ok then
        Log("[primed] registry notify unavailable - per-tick scan stands")
        return false
    end
    primedRegistryArmed = true
    -- actors that spawned before the notify was armed. A world that has none
    -- loaded yet (or whose class name has not resolved) leaves the registry
    -- stale, so the first tick that needs the list seeds it once more.
    primedSeedRegistry()
    if #primedRegistry == 0 then primedRegistryStale = true end
    Log(string.format("[primed] monster registry armed on %s (%g seeded)",
        PRIMED_NOTIFY_PATH, #primedRegistry))
    return true
end

local function primedHash(key)
    local h = 5381
    for i = 1, #key do
        h = (h * 33 + key:byte(i)) % 4294967296
    end
    return h % 100
end

-- HP fraction via the fixed-point read conditions.lua documents
-- (GetHP().Value is FixedPoint64 at 1000 units per HP; GetMaxHP is plain)
local function primedHpFraction(param)
    local frac = nil
    pcall(function()
        local hp = param:GetHP().Value
        local max = param:GetMaxHP()
        if max and max > 0 then frac = hp / (max * 1000) end
    end)
    return frac
end

-- the HIGHEST matching environmentChance entry replaces the base chance;
-- non-string keys are skipped (an array-style user table must fail closed
-- per entry, not kill the scanner - splitParamId indexes the id raw)
local function primedEffectiveChance(cfg, condCtx)
    local base = tonumber(cfg.chance) or 10
    local best = nil
    for condId, c in pairs(cfg.environmentChance or {}) do
        local n = tonumber(c)
        if n and type(condId) == "string" then
            local ok = Conditions.evaluate({ conditions = { condId } }, condCtx)
            if ok and (not best or n > best) then best = n end
        end
    end
    return best or base
end

-- The GLOBAL situational gate (Config.primedPals.conditions/.anyOf) as a
-- synthetic pair table Conditions.evaluate/describe can read. Built on first
-- use and then frozen: both keys are file-only (no menu row writes them), so
-- config is static from load. `empty` is the default and collapses the whole
-- gate to one field test per candidate. The devMode block counter is armed
-- here so every 60s window of an ACTIVE gate carries the suffix - the report
-- loop reads devMode at this same arming moment.
local primedGate = (function()
    local cache = nil
    return function()
        if not cache then
            local cfg = Config.primedPals or {}
            local andList = type(cfg.conditions) == "table" and cfg.conditions or {}
            local anyList = type(cfg.anyOf) == "table" and cfg.anyOf or {}
            cache = { conditions = andList, anyOf = anyList,
                empty = (#andList == 0 and #anyList == 0) }
            if Config.devMode and not cache.empty then tickStats.primed.gate = 0 end
        end
        return cache
    end
end)()

-- first pair passing the wild gates; conditions evaluate against the WILD
-- pal (fail closed: player-dependent conditions simply never match here)
local function primedPickPair(id, isAlpha, level, condCtx, grace)
    for _, cand in ipairs(Config.findPairs(id)) do
        if isAlpha and not swapTargetId(cand, true) then
            -- no alpha form for this target: next candidate
        elseif (level + grace) < cand.minLevel then
            -- out of reach even with the grace band
        elseif Conditions.evaluate(cand, condCtx) then
            return cand
        end
    end
    return nil
end

local function primedSpawnParams(x, y, z, yaw)
    return {
        SpawnLocation = { X = x, Y = y, Z = z + 20 },
        SpawnRotation = { Pitch = 0, Yaw = yaw or 0, Roll = 0 },
        SpawnScale = { X = 1, Y = 1, Z = 1 },
        -- 2 = AdjustIfPossibleButAlwaysSpawn
        SpawnCollisionHandlingOverride = 2,
        bAlwaysRelevant = false,
        bNeedAdjustToFloor = true,
        AdjustUpOffset = 0,
        bAdjustShortRayLength = false,
        bStartAsInactivePalCharacter = false,
    }
end

local function primedFlash(a)
    pcall(function()
        local vec = a.VisualEffectComponent
        if vec and vec:IsValid() then
            vec:AddVisualEffect_ToALL(2, { FloatValues = {} }, 0)
        end
    end)
end

-- One wild transformation. Every deferred stage re-checks its handles and
-- the CAPTURE rule: the moment the individual becomes owned, the evolution
-- is off and the player keeps the un-evolved pal.
local function primedEvolve(mgr, handle, actor, param, pair, isAlpha, level, key)
    primedRunSeq = primedRunSeq + 1
    local myRun = primedRunSeq
    primedBusyAt = os.clock()
    -- consumed at LAUNCH, not at finish: after a watchdog release the
    -- scanner must never relaunch the same individual while a stale run's
    -- callbacks may still be queued (shared-handle churn, and the stale
    -- run's belt-restore would de-protect the new telegraph)
    primedTriggered[key] = true
    local cfg = Config.primedPals or {}
    local targetId = swapTargetId(pair, isAlpha) or pair.to
    local done = false
    local committed = false -- true once the species swap verified
    local function finishWild()
        if done then return end
        done = true
        primedTriggered[key] = true -- win or lose, this individual is done
        if not committed then
            -- belt: on a cancel the original body may still exist without
            -- having passed a restore site (e.g. capture tore it down
            -- between our checks) - a pooled body must never re-enter the
            -- world undamageable
            pcall(function()
                if actor and actor:IsValid() then setActorDamageable(actor, true) end
            end)
        end
        -- only this run's finish may clear the busy stamp (the scanner's
        -- watchdog can have started a newer run over a stale one)
        if primedRunSeq == myRun then primedBusyAt = nil end
    end

    local oldX, oldY, oldZ, oldYaw = nil, nil, nil, 0
    pcall(function()
        local loc = actor:K2_GetActorLocation()
        oldX, oldY, oldZ = loc.X, loc.Y, loc.Z
    end)
    pcall(function() oldYaw = actor:K2_GetActorRotation().Yaw end)
    if not (oldX and oldY and oldZ) then
        finishWild()
        return
    end

    -- telegraph: freeze + death-flag, deliberately NO heal (capture odds
    -- stay those of a low-HP pal), flash so the player can read the moment
    -- and choose: sphere it now, or face the evolved form
    setFrozen(actor, true)
    setActorDamageable(actor, false)
    primedFlash(actor)
    Log(string.format("Primed Pal: %s (Lv %d) is evolving into %s...",
        pair.from, level, pair.to))

    local telegraphMs = math.floor(math.max(400, tonumber(cfg.telegraphMs) or 1800))
    -- fired-latch per the crash-#7 law: `done` only lands at finishWild, so
    -- without the latch a re-fire mid-chain would double-despawn the wild
    local telegraphFired = false
    LoopAsync(telegraphMs, function()
        if telegraphFired then return true end
        telegraphFired = true
        ExecuteInGameThread(function()
            if done then return end
            -- the stage body is pcall-shielded: an unexpected engine error
            -- must release the single-flight stamp and unfreeze the pal,
            -- never strand the feature for the session
            local okStage, errStage = pcall(function()
            if not (mgr and mgr:IsValid() and handle and handle:IsValid()
                and param and param:IsValid()) then
                finishWild()
                return
            end
            if isOwned(param) then
                -- sphered during the telegraph: the catch wins
                Log("Primed Pal: captured during the telegraph - evolution cancelled")
                local a = nil
                pcall(function() a = handle:TryGetIndividualActor() end)
                if a and a:IsValid() then
                    setActorDamageable(a, true)
                    setFrozen(a, false)
                end
                finishWild()
                return
            end
            local a = nil
            pcall(function() a = handle:TryGetIndividualActor() end)
            if not (a and a:IsValid()) then
                -- killed or despawned during the telegraph
                finishWild()
                return
            end
            local inSphere = false
            pcall(function() inSphere = a:IsHidden() == true end)
            if inSphere then
                -- mid-capture shake: never yank the pal out of the ball;
                -- whatever the sphere decides, this evolution is over. But
                -- a FAILED capture breaks the pal back out - check back
                -- once after the shakes resolve and unfreeze a still-wild
                -- survivor so no statue is left standing.
                Log("Primed Pal: capture in progress - evolution cancelled")
                setActorDamageable(a, true)
                local checked = false
                LoopAsync(4000, function()
                    if checked then return true end
                    checked = true
                    ExecuteInGameThread(function()
                        pcall(function()
                            if not (handle and handle:IsValid()) then return end
                            local cur = handle:TryGetIndividualActor()
                            if cur and cur:IsValid() and param and param:IsValid()
                                and not isOwned(param) then
                                setActorDamageable(cur, true)
                                setFrozen(cur, false)
                            end
                        end)
                    end)
                    return true
                end)
                finishWild()
                return
            end
            -- tear the old body down, swap in the despawned state (the
            -- safest write moment, mirroring the player path)
            pcall(function() mgr:DespawnCharacterByHandle(handle, nil) end)
            pollUntil(150, 2000, function()
                -- the handle can be freed under us (leaving for the title
                -- screen mid-sequence): a UFunction call on a torn-down UObject
                -- faults natively, past this pcall. Ending the poll routes into
                -- the doneFn below, whose handle check finishes safely.
                if not (handle and handle:IsValid()) then return true end
                local cur = nil
                pcall(function() cur = handle:TryGetIndividualActor() end)
                return not (cur and cur:IsValid())
            end, function(despawned)
                if done then return end
                if not (mgr and mgr:IsValid() and handle and handle:IsValid()) then
                    finishWild() -- world/handles died mid-teardown: touch nothing
                    return
                end
                if not despawned then
                    local cur = nil
                    pcall(function() cur = handle:TryGetIndividualActor() end)
                    if cur and cur:IsValid() then
                        setActorDamageable(cur, true)
                        setFrozen(cur, false)
                    end
                    finishWild()
                    return
                end
                if not (param and param:IsValid()) then finishWild() return end
                if isOwned(param) then
                    Log("Primed Pal: captured at the swap boundary - evolution cancelled")
                    finishWild()
                    return
                end
                local okId, curId, curAlpha = pcall(function()
                    return baseCharacterId(param:GetCharacterID():ToString())
                end)
                if not okId or curId ~= pair.from or curAlpha ~= isAlpha then
                    -- identity unreadable or changed mid-teardown: put the
                    -- world back instead of deleting the pal
                    Log("Primed Pal: identity check failed after despawn - respawning as-is")
                    pcall(function()
                        mgr:SpawnCharacterByHandle(handle,
                            primedSpawnParams(oldX, oldY, oldZ, oldYaw), nil)
                    end)
                    finishWild()
                    return
                end
                local okSwap = pcall(function()
                    param.SaveParameter.CharacterID = FName(targetId)
                    param.SaveParameterMirror.CharacterID = FName(targetId)
                end)
                local idNow = ""
                pcall(function() idNow = param:GetCharacterID():ToString() end)
                if not okSwap or idNow ~= targetId then
                    Log("Primed Pal: swap failed - respawning the old form")
                    pcall(function()
                        mgr:SpawnCharacterByHandle(handle,
                            primedSpawnParams(oldX, oldY, oldZ, oldYaw), nil)
                    end)
                    finishWild()
                    return
                end
                committed = true
                -- same benefits as player evolutions
                applyIvBonus(param)
                pcall(function() param:FullRecoveryHP() end)
                -- NO suitability refresh here: the actor is despawned at this
                -- point, and the DB re-apply is an unprobed native call that
                -- may deref the owning actor internally (pcall-transparent
                -- fault risk - review major). A primed-evolved wild caught
                -- later shows its new work styles after the next reload.
                -- rebuild the actor as the new species at the same spot
                pcall(function()
                    mgr:SpawnCharacterByHandle(handle,
                        primedSpawnParams(oldX, oldY, oldZ, oldYaw), nil)
                end)
                pollUntil(150, 5000, function()
                    -- same freed-handle guard as the despawn poll above
                    if not (handle and handle:IsValid()) then return true end
                    local na = nil
                    pcall(function() na = handle:TryGetIndividualActor() end)
                    return (na and na:IsValid()) == true
                end, function(spawned)
                    if done then return end
                    if not (handle and handle:IsValid()) then
                        finishWild() -- world died during the respawn wait
                        return
                    end
                    if not spawned then
                        -- the individual persists despawned; the area
                        -- respawns wild pals naturally, same as a culled one
                        Log("Primed Pal: respawn did not confirm (" .. targetId .. ")")
                        finishWild()
                        return
                    end
                    local na = nil
                    pcall(function() na = handle:TryGetIndividualActor() end)
                    if na and na:IsValid() then
                        -- brief reveal grace, then it is a normal wild pal
                        setActorDamageable(na, false)
                        primedFlash(na)
                        local released = false
                        LoopAsync(1500, function()
                            if released then return true end
                            released = true
                            ExecuteInGameThread(function()
                                local cur = nil
                                pcall(function()
                                    if handle and handle:IsValid() then
                                        cur = handle:TryGetIndividualActor()
                                    end
                                end)
                                if cur and cur:IsValid() then
                                    setActorDamageable(cur, true)
                                end
                            end)
                            return true
                        end)
                    end
                    Log(string.format("EVOLVED (primed): %s -> %s (Lv %d)",
                        pair.from, targetId, level))
                    finishWild()
                end)
            end)
            end) -- pcall: stage shield
            if not okStage then
                Log("Primed stage FAIL: " .. tostring(errStage))
                pcall(function()
                    if actor and actor:IsValid() then
                        setActorDamageable(actor, true)
                        setFrozen(actor, false)
                    end
                end)
                finishWild()
            end
        end)
        return true
    end)
end

-- Combat-gated scanner. In the steady state a tick touches CACHED refs only:
-- an IsValid sweep over the player CONTROLLERS, their pawns re-derived from
-- them by property read, one battle-manager boolean, and in combat an IsValid
-- sweep over the monster registry - no object-array scan anywhere. The
-- per-pal work only happens for nearby, low-HP, unowned pals -
-- and the expensive tail (conditions + pair pick) only for the rare one that
-- won its primed roll.
-- Returns "nopawns" so the arming loop can back off on an empty server.
local function primedTick()
    -- in-game options first: pure Lua, self-throttled, and it must not be
    -- skipped by the busy/watchdog returns below. One of SEVERAL independent
    -- drivers - this one needs authority AND primedPals.enabled, both of which
    -- can leave it unarmed (modoptions.lua)
    if ModOptions then pcall(ModOptions.pump) end
    if primedBusyAt then
        -- watchdog: a dropped callback must not kill the feature for the
        -- session (the player path has lockBusy for the same reason)
        if (os.clock() - primedBusyAt) > 30 then
            Log("Primed sequence stuck - watchdog releasing the slot")
            primedBusyAt = nil
        else
            return
        end
    end
    local cfg = Config.primedPals or {}
    if not cachedWorldAuthority() then return end
    -- PalUtility is a CDO (StaticFindObject is a name lookup, not a sweep) but
    -- it is process-stable, so it is captured all the same
    if not (primedUtilCache and primedUtilCache:IsValid()) then
        primedUtilCache = palUtility()
    end
    local util = primedUtilCache
    if not util then return end
    -- controllers: cached refs, compacted in place by the shared helper. Only
    -- an empty cache, a controller the notify flagged as new, or the
    -- multiplayer staleness net pays for a scan.
    local pcs = livePlayerControllers()
    -- pawns are derived FRESH from the cached controllers every tick: property
    -- reads only, no scan, so a respawned player (controller survived, pawn
    -- did not) and a joiner whose pawn possessed after its controller was
    -- built are both picked up on the very next tick. pawns[1] remains the
    -- battle manager's world context, exactly as before.
    local pawns = {}
    for _, pc in ipairs(pcs) do
        local ctx = Role.playerCtxFor(pc)
        local pawn = ctx and ctx.pawn
        if pawn and pawn:IsValid() then pawns[#pawns + 1] = pawn end
    end
    if #pawns == 0 then return "nopawns" end
    local inBattle = false
    pcall(function()
        -- the battle manager is per-world stable: resolved once, re-resolved
        -- only when the ref dies
        if not (primedBattleMgrCache and primedBattleMgrCache:IsValid()) then
            primedBattleMgrCache = util:GetBattleManager(pawns[1])
        end
        local bm = primedBattleMgrCache
        if bm and bm:IsValid() then inBattle = bm:IsBattleModeAnyPlayer() == true end
    end)
    if not inBattle then
        if #primedRegistry > PRIMED_SWEEP_BOUND then primedSweepRegistry() end
        return
    end

    -- late/bounded registry arming: reaching this line proves authority, valid
    -- pawns and live combat - the world is settled, so the native-class notify
    -- attach is storm-safe here. Covers dedicated servers and a client-turned-
    -- host session; idempotent via the armed early-return.
    if not primedRegistryArmed and primedTickArmTries < 8 then
        primedTickArmTries = primedTickArmTries + 1
        pcall(armPrimedRegistry)
    end

    -- pal actors on the map: the NotifyOnNewObject registry when it is armed
    -- (cached refs, no scan), else the legacy per-tick scan - BP_MonsterBase_C
    -- is the class the level-up hook targets; fall back to the native base if
    -- it yields nothing.
    local list = primedScanList()
    if not list then
        if primedActorClass then
            list = FindAllOf(primedActorClass)
        else
            for _, cname in ipairs(PRIMED_CLASSES) do
                list = FindAllOf(cname)
                if list and #list > 0 then
                    primedActorClass = cname
                    if Config.devMode then
                        Log(string.format("[primed] actor class %s (%d)", cname, #list))
                    end
                    break
                end
            end
        end
    end
    if not list then return end

    local range2 = (tonumber(cfg.range) or 8000) ^ 2
    local threshold = tonumber(cfg.hpThreshold) or 0.35
    local grace = tonumber(cfg.levelGrace) or 0
    local budget = math.max(1, tonumber(cfg.maxPerScan) or 12)
    -- resolved once per tick, not per candidate: the default (both lists
    -- empty) then costs the sweep one field test and nothing else
    local gate = primedGate()

    local function consider(actor)
        if not (actor and actor:IsValid()) then return false end
        local nearPawn = nil
        pcall(function()
            local loc = actor:K2_GetActorLocation()
            for _, pawn in ipairs(pawns) do
                local pl = pawn:K2_GetActorLocation()
                local dx, dy, dz = loc.X - pl.X, loc.Y - pl.Y, loc.Z - pl.Z
                if (dx * dx + dy * dy + dz * dz) <= range2 then
                    nearPawn = pawn
                    return
                end
            end
        end)
        if not nearPawn then return false end
        local param = paramOf(actor)
        if not (param and param:IsValid()) then return false end
        if isOwned(param) then return false end
        local key = individualKey(param)
        if key == "" or primedTriggered[key] then return false end
        -- budget counts genuine wild candidates; the cheap disqualifiers
        -- above stay unbudgeted and the rotating start below guarantees a
        -- crowd cannot starve candidates later in the actor list
        budget = budget - 1
        local frac = primedHpFraction(param)
        if not frac or frac <= 0 or frac > threshold then return false end
        local hidden = false
        pcall(function() hidden = actor:IsHidden() == true end)
        if hidden then return false end -- inside a sphere or otherwise staged
        local id, isAlpha = baseCharacterId(param:GetCharacterID():ToString())
        local pairList = Config.findPairs(id)
        if not pairList or #pairList == 0 then return false end
        -- region conditions resolve through a PLAYER's region id; this pal
        -- is fighting within range of nearPawn, so that player's region is
        -- a faithful proxy. Pawn-based conditions (playerLevel, isGliding,
        -- inOwnBase, inCombat) therefore read that player too - a
        -- playerLevel-gated pair means "a nearby player at least this
        -- strong". Party/trust/riding conditions still fail closed.
        -- wildProxy marks the ctx as exactly that - a stand-in, not the pal's
        -- owner. Conditions that describe the PAL's own body (inWater) must
        -- not fall back to the proxy player: a nearby swimmer would otherwise
        -- water-evolve a wild pal standing on dry land.
        local condCtx = { actor = actor, param = param, wildProxy = true,
            playerCtx = { pawn = nearPawn }, holder = actor }
        if primedHash(key) >= primedEffectiveChance(cfg, condCtx) then return false end
        local level = 0
        pcall(function() level = param:GetLevel() end)
        -- global situational gate, on the SAME ctx the pair conditions get.
        -- A block is not latched into primedTriggered: the pal only failed
        -- the world as it is right now and must be reconsidered once night
        -- falls or the weather turns.
        if not gate.empty and not Conditions.evaluate(gate, condCtx) then
            local s = tickStats.primed
            if s.gate then s.gate = s.gate + 1 end
            return false
        end
        local pair = primedPickPair(id, isAlpha, level, condCtx, grace)
        if not pair then return false end
        local mgr = findManager(actor)
        if not mgr then return false end
        local handle = nil
        pcall(function() handle = mgr:GetIndividualHandleFromCharacterParameter(param) end)
        if not (handle and handle:IsValid()) then return false end
        primedEvolve(mgr, handle, actor, param, pair, isAlpha, level, key)
        return true
    end

    -- circular sweep from a rotating start: the next tick resumes right
    -- after the last actor examined, so every pal gets its turn within a
    -- few ticks no matter how crowded the head of the list is
    local n = #list
    if n == 0 then return end
    local start = primedScanOffset % n
    local advanced = 0
    for step = 0, n - 1 do
        if budget <= 0 then break end
        advanced = step + 1
        if consider(list[((start + step) % n) + 1]) then break end
    end
    primedScanOffset = (start + advanced) % n
end

-- ----------------------------------------------------- base-pal auto-evolve

-- Base workers (Config.autoEvolve.basePals): a pal assigned to a camp
-- transforms on its own the moment it reaches the level of a FREE pair that
-- carries NO conditions. Conditioned pairs are deliberately excluded - a
-- condition is a moment the player should witness, not something that happens
-- while they are three biomes away - and costed pairs never auto-fire (the
-- same law the summoned-pal poller obeys).
--
-- An AUTHORITY feature, like the wild scanner: camps are world simulation, so
-- this runs where the base actually ticks and connected clients just see the
-- result replicate. The sweep is slow on purpose - nobody is waiting on it -
-- and reuses the wild scanner's caches wholesale (controller cache + monster
-- registry), so it adds no MONSTER scan at all once the registry is armed.
-- (The shared controller cache's own 30s staleness net still costs a
-- PalPlayerController scan per sweep on a multiplayer host - pre-existing join
-- detection, documented at livePlayerControllers.)
--
-- No distance gate, deliberately: an owner is not supposed to have to stand
-- there for it. What bounds it instead is the actor list itself - only a
-- LOADED camp has spawned worker bodies, so an unloaded base is naturally out
-- of scope and its pals evolve the next time it streams in.
local BASE_SCAN_BUDGET = 16        -- camp workers fully examined per sweep
local BASE_WATCHDOG_S = 30         -- stale single-flight stamp release
local BASE_SEQUENCE_BUDGET_S = 30  -- shared sequence-lock budget for one run
local BASE_SETTLE_MS = 1500        -- protection grace on the fresh body

local baseBusyAt = nil    -- os.clock() while a base sequence runs (single
                          -- flight; the tick watchdogs a stale stamp)
local baseRunSeq = 0      -- run token so a stale run's finish cannot clear a
                          -- newer run's stamps
local baseScanOffset = 0  -- rotating scan start: a camp larger than the
                          -- budget still gets every worker its turn
local baseAttemptAt = {}  -- individualKey -> { t, id, tries }

-- THE DISCRIMINATOR. UPalIndividualCharacterParameter carries the camp a pal
-- is assigned to (PalworldModdingKit/Source/Pal/Public/
-- PalIndividualCharacterParameter.h):
--     UPROPERTY(BlueprintReadWrite, EditAnywhere, Replicated, Transient,
--         meta=(AllowPrivateAccess=true))
--     FGuid BaseCampId;
--     UFUNCTION(BlueprintCallable, BlueprintPure)
--     FGuid GetBaseCampId() const;
-- (UPalCharacterParameterComponent mirrors the getter.) A pal ASSIGNED to a
-- camp carries a non-zero camp guid; a party pal, the summoned otomo and every
-- wild pal carry the zero guid - which makes this a single property read that
-- answers "is this a base worker" exactly, with no container walking.
-- The property is the primary path (property reads are the reliable surface in
-- this build - isOwned reads OwnerPlayerUId the same way); the BlueprintPure
-- getter is the fallback, and an unreadable value FAILS CLOSED: an unknown pal
-- is never treated as a base worker.
-- true / false, or NIL when the marker is not readable at all (no actor to ask
-- the getter, or a build without the field).
local function baseCampAssigned(param, actor)
    local assigned = nil
    pcall(function()
        local g = param.BaseCampId
        if g then assigned = (g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0) end
    end)
    if assigned == nil and actor then
        pcall(function()
            local comp = actor.CharacterParameterComponent
            if comp and comp:IsValid() then
                local g = comp:GetBaseCampId()
                if g then assigned = (g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0) end
            end
        end)
    end
    return assigned
end

-- Candidate gate: an unreadable marker FAILS CLOSED (an unknown pal is never
-- treated as a base worker) and says so once, so a build that moved the field
-- shows up in the log as an inert feature instead of silent nothing.
local baseCampReadWarned = false
local function isBaseAssigned(param, actor)
    local assigned = baseCampAssigned(param, actor)
    if assigned == nil then
        if not baseCampReadWarned then
            baseCampReadWarned = true
            Log("[baseevolve] BaseCampId unreadable on this build - base "
                .. "auto-evolve stays inert")
        end
        return false
    end
    return assigned
end

-- Cheap per-actor party-pal guard, from the same header family:
--     UFUNCTION(BlueprintCallable, BlueprintPure) bool IsOtomo() const;
-- (UPalCharacterParameterComponent). A camp worker is not an otomo, so this
-- only ever fires if a build ever set both markers - belt over the camp id.
local function isOtomoPal(actor)
    local otomo = false
    pcall(function()
        local comp = actor.CharacterParameterComponent
        if comp and comp:IsValid() then otomo = comp:IsOtomo() == true end
    end)
    return otomo
end

-- The authoritative "currently summoned party pal" answer: every player's own
-- otomo holder, asked directly. Built at most ONCE per sweep and only when a
-- genuine camp worker was found, so an idle tick never pays for it. This is
-- the check that guarantees the feature can never touch a pal the player is
-- actively adventuring with, whatever the camp id says.
local function summonedOtomoKeys(pcs)
    local keys = {}
    for _, pc in ipairs(pcs) do
        if pc and pc:IsValid() then
            local ctx = Role.playerCtxFor(pc)
            local holder = ctx and findHolderFor(ctx, nil) or nil
            if holder and holder:IsValid() then
                local a = nil
                pcall(function() a = holder:TryGetSpawnedOtomo() end)
                if a and a:IsValid() then
                    local p = paramOf(a)
                    if p then
                        local k = individualKey(p)
                        if k ~= "" then keys[k] = true end
                    end
                end
            end
        end
    end
    return keys
end

local function ownerUidString(param)
    local uid = nil
    pcall(function() uid = guidString(param.SaveParameter.OwnerPlayerUId) end)
    return uid
end

-- The owning player's context, if they are in the process right now (they may
-- be offline on a server, or across the map - neither blocks the evolution).
-- Deferred call site: every cached controller is re-validated here.
local function baseOwnerCtx(ownerUid)
    if not ownerUid or ownerUid == "" then return nil end
    for _, pc in ipairs(primedPcCache) do
        if pc and pc:IsValid() then
            local ctx = Role.playerCtxFor(pc)
            local uid = nil
            if ctx and ctx.playerUId then
                pcall(function() uid = guidString(ctx.playerUId) end)
            end
            if uid == ownerUid then return ctx end
        end
    end
    return nil
end

-- It happened OFF-SCREEN, so it must be told. Identity resolution stays here
-- (baseOwnerCtx depends on the primed controller cache, which lives far below
-- the shared helper); the localized sentence and the toast/notify/log routing -
-- including the offline-owner degradation to a log line - belong to
-- announceEvolution, so a base prompt looks like every other one.
local function announceBaseEvolution(pair, targetId, level, ownerUid)
    local ownerCtx = baseOwnerCtx(ownerUid)
    announceEvolution(ownerCtx, pair.from, targetId, level, "base")
    if Config.devMode then
        Log(string.format("[baseevolve] committed %s -> %s (Lv %d, owner %s)",
            pair.from, targetId, level, tostring(ownerUid)))
    end
end

-- Effectively free, WITHOUT paying for a price resolution in the common case:
-- a pair marked `free` costs nothing at all, and while the global stone switch
-- is on every other pair carries a stone - which is exactly the first entry
-- Costs.resolve inserts. Only the stone-free configuration needs the real
-- resolve, and that path never reaches the adaptation-stone branch, so this
-- can never write a fallback-stone guess into the shared price cache from the
-- weak world context a camp worker offers (the trap describeEvolutionsFor
-- documents).
local function pairIsFree(pair, level, worldCtx)
    if pair.free then return true end
    if Config.requireStone then return false end
    return #Costs.resolve(pair, level, worldCtx) == 0
end

-- First pair in map order that a camp worker may take on its own: free, and
-- WITHOUT conditions of either kind (`conditions` or an `anyOf` group).
-- Conditions are never evaluated here - their presence alone disqualifies the
-- pair, so a night-only or in-water evolution keeps waiting for the player to
-- trigger it deliberately.
local function basePickPair(pairList, isAlpha, level, worldCtx)
    for _, cand in ipairs(pairList) do
        local conds = cand.conditions
        if isAlpha and not swapTargetId(cand, true) then
            -- no alpha form for this target: next candidate
        elseif (type(conds) == "table" and #conds > 0)
            or (type(cand.anyOf) == "table" and #cand.anyOf > 0) then
            -- conditioned pairs deserve their moment - never automatic here
        elseif level < cand.minLevel then
            -- not there yet
        elseif pairIsFree(cand, level, worldCtx) then
            return cand
        end
    end
    return nil
end

-- One camp-worker transformation. Adapted from primedEvolve's
-- despawn -> swap -> verify -> respawn skeleton, WITH the player-evolution
-- benefits (IV bonus, full heal, damage protection through the swap,
-- work-suitability refresh, rollback snapshot - this is the player's pal) and
-- WITHOUT the wild baggage (no telegraph, no catch cancellation, no
-- primedTriggered bookkeeping).
--
-- Accepted cost: rebuilding the body drops the pal's CURRENT WORK ASSIGNMENT.
-- There is no Lua path that re-assigns a specific work slot, and the camp AI
-- re-picks a task for the new body within moments - exactly what every worker
-- does after a world reload.
local function baseEvolve(mgr, handle, actor, param, pair, isAlpha, level, key, ownerUid)
    baseRunSeq = baseRunSeq + 1
    local myRun = baseRunSeq
    baseBusyAt = os.clock()
    -- The SHARED sequence lock. Every player-initiated path (F2, radial, net
    -- request, auto-evolve, rollback) gates on lockBusy(), so taking it here
    -- is what makes a base evolution unable to interleave with one of theirs -
    -- and lockBusy's watchdog can free ours through currentAbort if a callback
    -- of this run is ever lost.
    sequenceRunning = true
    sequenceStartedAt = os.clock()
    sequenceBudgetS = BASE_SEQUENCE_BUDGET_S

    local targetId = swapTargetId(pair, isAlpha) or pair.to
    local done = false
    local committed = false
    -- snapshot inputs, read BEFORE the IV bonus lands on the param
    local nickname = ""
    pcall(function()
        nickname = param.SaveParameter.NickName
            and param.SaveParameter.NickName:ToString() or ""
    end)
    local talentsBefore = readTalents(param)

    -- Damage protection for the whole swap window, resolved through the
    -- HANDLE instead of an otomo holder (a camp worker has none): the old
    -- body, the actor-less gap and the fresh body are all covered, with the
    -- same HP re-top the player path gets. Registered per individual, so a
    -- player-initiated evolution of the same pal supersedes it cleanly.
    local prot = startProtection(param, nil, key,
        "base " .. pair.from .. ">" .. pair.to,
        function()
            if handle and handle:IsValid() then return handle:TryGetIndividualActor() end
            return nil
        end)

    -- restore=false: the world (or the handle) is tearing down - end the
    -- window without touching anything the dying side owns, exactly the rule
    -- performEvolution's abandonOnTeardown follows. Closing with restore=true
    -- there would re-top HP on a mid-teardown param, which is the native-fault
    -- class this whole file guards against. Default (no argument, including
    -- the watchdog's pcall(currentAbort)) is a normal restoring close.
    local function finishBase(restore)
        if done then return end
        done = true
        local restoring = (restore ~= false)
        if prot then pcall(function() prot.stop(restoring) end) end
        if restoring and not committed then
            -- belt, mirroring the wild path: a body that never passed a
            -- restore site must never be left in the world undamageable
            pcall(function()
                local a = nil
                if handle and handle:IsValid() then a = handle:TryGetIndividualActor() end
                if a and a:IsValid() then setActorDamageable(a, true) end
            end)
        end
        -- only THIS run's finish may clear the stamps: the tick's watchdog can
        -- have started a newer run over a stale one
        if baseRunSeq == myRun then
            baseBusyAt = nil
            sequenceRunning = false
            currentAbort = nil
        end
    end
    currentAbort = finishBase

    if not (mgr and mgr:IsValid() and handle and handle:IsValid()
        and actor and actor:IsValid() and param and param:IsValid()) then
        finishBase()
        return
    end

    local oldX, oldY, oldZ, oldYaw = nil, nil, nil, 0
    pcall(function()
        local loc = actor:K2_GetActorLocation()
        oldX, oldY, oldZ = loc.X, loc.Y, loc.Z
    end)
    pcall(function() oldYaw = actor:K2_GetActorRotation().Yaw end)
    if not (oldX and oldY and oldZ) then
        finishBase()
        return
    end

    -- No telegraph and no freeze. There is no capture window to open here,
    -- and skipping the freeze means the "despawn not confirmed" branch has
    -- NOTHING to restore - the worker simply carries on working - while the
    -- success path destroys the body a moment later anyway.
    Log(string.format("Base pal evolving: %s (Lv %d) -> %s", pair.from, level, pair.to))
    pcall(function() mgr:DespawnCharacterByHandle(handle, nil) end)
    pollUntil(150, 2000, function()
        -- the handle can be freed under us (leaving for the title screen
        -- mid-sequence): a UFunction call on a torn-down UObject faults
        -- natively, past this pcall. Ending the poll routes into the doneFn
        -- below, whose handle check finishes without touching anything.
        if not (handle and handle:IsValid()) then return true end
        local cur = nil
        pcall(function() cur = handle:TryGetIndividualActor() end)
        return not (cur and cur:IsValid())
    end, function(despawned)
        if done then return end
        -- stage shield: an unexpected engine error must release the stamps and
        -- the shared lock, never strand the feature for the session
        local okStage, errStage = pcall(function()
            if not (mgr and mgr:IsValid() and handle and handle:IsValid()) then
                finishBase(false) -- world/handles died mid-teardown: touch nothing
                return
            end
            if not despawned then
                Log("Base pal: despawn not confirmed - evolution abandoned")
                finishBase()
                return
            end
            -- Everything that made this pal a candidate is re-checked at the
            -- mutation boundary: ownership, camp assignment and species can
            -- all change while the teardown runs (the player can pull the pal
            -- out of the camp). A surprise that leaves the pal camp-resident
            -- puts the OLD form back rather than leave the individual
            -- bodiless; the one that hands the pal to ANOTHER flow (the camp
            -- id clearing) deliberately does not - see there.
            local function respawnOldForm(why)
                Log("Base pal: " .. why .. " - respawning the old form")
                pcall(function()
                    mgr:SpawnCharacterByHandle(handle,
                        primedSpawnParams(oldX, oldY, oldZ, oldYaw), nil)
                end)
                finishBase()
            end
            if not (param and param:IsValid()) then
                finishBase()
                return
            end
            if not isOwned(param) then
                respawnOldForm("no longer owned")
                return
            end
            -- The ACTOR is gone here, so only the property can answer; an
            -- unreadable marker is not evidence of a change (the candidate
            -- gate already proved this pal was assigned) - only a definite
            -- false aborts. And this abort does NOT respawn: the camp id
            -- cleared because the player pulled the pal into their party or
            -- box during the despawn window, so that flow owns the body now -
            -- spawning one here would leave a ghost/duplicate in the world.
            -- (The wild path's analogous ownership-changed branch declines to
            -- respawn for the same reason.)
            if baseCampAssigned(param, nil) == false then
                Log("Base pal: left the camp mid-sequence - evolution abandoned")
                finishBase()
                return
            end
            local okId, curId, curAlpha = pcall(function()
                return baseCharacterId(param:GetCharacterID():ToString())
            end)
            if not okId or curId ~= pair.from or curAlpha ~= isAlpha then
                respawnOldForm("identity check failed after despawn")
                return
            end
            local okSwap = pcall(function()
                param.SaveParameter.CharacterID = FName(targetId)
                param.SaveParameterMirror.CharacterID = FName(targetId)
            end)
            local idNow = ""
            pcall(function() idNow = param:GetCharacterID():ToString() end)
            if not okSwap or idNow ~= targetId then
                respawnOldForm("swap failed")
                return
            end
            committed = true
            if prot then prot.swapCommitted = true end
            -- the player's own pal: the same benefits an F2 evolution grants.
            -- (No suitability refresh here: no live context object exists at
            -- this point - the respawn path below runs it with the fresh
            -- actor, then re-tops HP against any re-derived max.)
            applyIvBonus(param)
            pcall(function() param:FullRecoveryHP() end)
            -- Rollback entry, identical in shape to performEvolution's. The
            -- uid is the pal's OWNER (which is what rollbackLast matches
            -- against), not a requester - nobody asked for this one. The cost
            -- column is EMPTY by construction and not by omission: baseEvolve
            -- is only ever handed a basePickPair result, and that gate takes
            -- free pairs only, so nothing was charged and a rollback of this
            -- entry must hand nothing back.
            table.insert(snapshots, {
                key = key,
                from = isAlpha and (BOSS_PREFIX .. pair.from) or pair.from,
                to = targetId, level = level, nickname = nickname,
                ivHP = talentsBefore.Talent_HP, ivMelee = talentsBefore.Talent_Melee,
                ivShot = talentsBefore.Talent_Shot, ivDefense = talentsBefore.Talent_Defense,
                uid = ownerUid,
                cost = {},
            })
            saveSnapshots()
            -- Same commit point performEvolution uses, and for the same reason:
            -- the species is committed and snapshotted. Always the UNPREFIXED
            -- id - the capture record is keyed by EPalTribeID, which has no
            -- BOSS_ (alpha) rows. ownerUid is already a guid string; the helper
            -- takes it directly, which is what lets an OFFLINE owner's camp
            -- evolution unlock the same technologies an F2 one does. An
            -- UNREADABLE owner is skipped rather than passed as nil: on the
            -- manual path a nil uid still means "the player who asked", but here
            -- nobody asked, and an unaddressed unlock could land on whichever
            -- player the native resolves by default. (An all-zeros uid is the
            -- same non-identity and the helper drops it for the same reason.)
            -- No PlayerState travels from here either - the owner may not be in
            -- the process at all - so this stays a uid-addressed unlock on the
            -- new companion exactly as it is on the old one.
            if type(ownerUid) == "string" and ownerUid ~= "" then
                unlockCatchTech(pair.to, ownerUid)
            end
            -- rebuild the body as the new species at the same spot (this is
            -- the step that drops the work assignment - see the header note)
            pcall(function()
                mgr:SpawnCharacterByHandle(handle,
                    primedSpawnParams(oldX, oldY, oldZ, oldYaw), nil)
            end)
            pollUntil(150, 5000, function()
                -- same freed-handle guard as the despawn poll above
                if not (handle and handle:IsValid()) then return true end
                local na = nil
                pcall(function() na = handle:TryGetIndividualActor() end)
                return (na and na:IsValid()) == true
            end, function(spawned)
                if done then return end
                local okDone, errDone = pcall(function()
                    if not (handle and handle:IsValid()) then
                        finishBase(false) -- world died during the respawn wait
                        return
                    end
                    if not spawned then
                        -- the swap is committed AND saved; the individual
                        -- persists and the camp brings its workers back
                        Log("Base pal: respawn did not confirm (" .. targetId .. ")")
                        finishBase()
                        return
                    end
                    local na = nil
                    pcall(function() na = handle:TryGetIndividualActor() end)
                    if na and na:IsValid() then
                        refreshWorkSuitability(param, nil, na)
                        -- re-top against a possibly re-derived max (the
                        -- commit-time heal used the stale max)
                        pcall(function() param:FullRecoveryHP() end)
                    end
                    announceBaseEvolution(pair, targetId, level, ownerUid)
                    -- the protection window rides onto the fresh body through
                    -- the handle resolver; hold it a moment longer so the new
                    -- form cannot be shot down while it settles into the camp
                    local released = false
                    LoopAsync(BASE_SETTLE_MS, function()
                        if released then return true end
                        released = true
                        ExecuteInGameThread(function()
                            local okFin, errFin = pcall(finishBase)
                            if not okFin then
                                Log("base finish FAIL: " .. tostring(errFin))
                            end
                        end)
                        return true
                    end)
                end)
                if not okDone then
                    Log("Base respawn stage FAIL: " .. tostring(errDone))
                    finishBase()
                end
            end)
        end)
        if not okStage then
            Log("Base swap stage FAIL: " .. tostring(errStage))
            finishBase()
        end
    end)
end

-- One sweep. Steady state (registry armed): an IsValid sweep over the cached
-- player controllers, an IsValid sweep over the cached monster registry, and
-- per actor a param fetch plus TWO property reads (owner guid, camp guid)
-- before anything else is touched - zero MONSTER scans, and on standalone zero
-- scans of any kind (a multiplayer host still pays the shared controller
-- cache's 30s join-detection refresh, see livePlayerControllers). The
-- per-worker tail (otomo set, pair pick, cost check) is paid only for actual
-- camp workers, at most BASE_SCAN_BUDGET of them, and at most ONE evolution
-- is launched per sweep.
-- Returns "noplayers" so the arming loop can back off on an empty server.
local function baseEvolveTick()
    -- in-game options first, same reasoning as the other pollers. One of
    -- SEVERAL independent drivers - this one needs authority AND
    -- autoEvolve.basePals, so it too can be unarmed. Free on a dedicated
    -- server: the menu is never registered there, so pump returns at its
    -- first line (modoptions.lua)
    if ModOptions then pcall(ModOptions.pump) end
    if baseBusyAt then
        -- watchdog: a dropped callback must not kill the feature for the
        -- session (primedTick and lockBusy exist for the same reason)
        if (os.clock() - baseBusyAt) > BASE_WATCHDOG_S then
            Log("Base evolution stuck - watchdog releasing the slot")
            baseBusyAt = nil
        else
            return
        end
    end
    if ServerCheck.blocked() then return end
    if not cachedWorldAuthority() then return end
    -- never interleave: the player's own sequence lock and the wild scanner's
    -- single-flight stamp both win over a base evolution nobody is waiting for
    if lockBusy() then return end
    if primedBusyAt then return end
    -- yield to the player exactly as the summoned-pal poller does: this
    -- sweep takes the SHARED lock, so firing it while an F2 confirm is armed
    -- (or seconds after a manual pick) would answer their press with
    -- "evolution already running". Pure Lua reads, no scan.
    if Evolution.isArmed() then return end
    if (os.clock() - lastManualActionAt) < 10 then return end

    local pcs = livePlayerControllers()
    if #pcs == 0 then return "noplayers" end

    local cfg = Config.autoEvolve or {}
    local intervalS = math.max(15, tonumber(cfg.baseIntervalSeconds) or 45)

    -- actor list: the monster registry when it is armed (cached refs, no
    -- scan), else ONE FindAllOf - affordable at this cadence, and it is the
    -- dedicated-server case, where the registry only ever arms from the
    -- combat-gated wild tick. Same fallback shape primedTick uses.
    local list = primedScanList()
    if not list then
        if primedActorClass then
            list = FindAllOf(primedActorClass)
        else
            for _, cname in ipairs(PRIMED_CLASSES) do
                list = FindAllOf(cname)
                if list and #list > 0 then
                    primedActorClass = cname
                    break
                end
            end
        end
    end
    if not list then return end
    local n = #list
    if n == 0 then return end

    local now = os.clock()
    local budget = BASE_SCAN_BUDGET
    local otomoKeys = nil -- built once, on the first genuine camp worker

    local function consider(actor)
        if not (actor and actor:IsValid()) then return false end
        local param = paramOf(actor)
        if not (param and param:IsValid()) then return false end
        -- the INVERSE of the wild filter: base pals are OWNED
        if not isOwned(param) then return false end
        if not isBaseAssigned(param, actor) then return false end
        -- a player character carries no camp id and the list is monster-shaped
        -- by construction, but the save parameter answers it outright:
        -- FPalIndividualCharacterSaveParameter { bool IsPlayer; }
        local isPlayerChar = false
        pcall(function() isPlayerChar = param.SaveParameter.IsPlayer == true end)
        if isPlayerChar then return false end
        if isOtomoPal(actor) then return false end
        -- from here the work is per-CAMP-WORKER, which is what the budget
        -- bounds; every disqualifier above is cheap and stays unbudgeted
        budget = budget - 1
        local key = individualKey(param)
        if key == "" then return false end
        -- mid-sequence: a live protection window means this individual is
        -- already inside somebody's evolution
        if activeProtections[key] then return false end
        if otomoKeys == nil then otomoKeys = summonedOtomoKeys(pcs) end
        if otomoKeys[key] then return false end
        local hidden = false
        pcall(function() hidden = actor:IsHidden() == true end)
        if hidden then return false end -- inside a sphere or otherwise staged
        local id, isAlpha = baseCharacterId(param:GetCharacterID():ToString())
        local pairList = Config.findPairs(id)
        if not pairList or #pairList == 0 then return false end
        local level = 0
        pcall(function() level = param:GetLevel() end)
        -- withdraw-to-cancel snooze, honoured exactly as the summoned-pal
        -- poller honours it: the player pulled THIS individual out of an
        -- evolution at this level, and assigning it to a camp afterwards must
        -- not perform the very evolution they just cancelled, off-screen.
        -- Hands off until it levels past that.
        local snoozedLvl = autoSnooze[key]
        if snoozedLvl then
            if level <= snoozedLvl then return false end
            autoSnooze[key] = nil
        end
        local pair = basePickPair(pairList, isAlpha, level, actor)
        if not pair then return false end
        -- per-individual spacing with the same id-aware backoff auto-evolve
        -- uses: a standing failure doubles the wait instead of retrying every
        -- sweep, while a pal that SUCCEEDED (its species changed) is back to
        -- base spacing for the next stage of its chain
        local entry = baseAttemptAt[key]
        if entry then
            local wait = intervalS
            if entry.id == pair.from then
                wait = math.max(intervalS,
                    math.min(900, intervalS * (2 ^ math.min(entry.tries - 1, 6))))
            end
            if (now - entry.t) < wait then return false end
        end
        local mgr = findManager(actor)
        if not mgr then return false end
        local handle = nil
        pcall(function() handle = mgr:GetIndividualHandleFromCharacterParameter(param) end)
        if not (handle and handle:IsValid()) then return false end
        -- prune before insert so a long session cannot grow the table unbounded
        local pruneAfter = math.max(1800, intervalS * 8)
        for k, e in pairs(baseAttemptAt) do
            if (now - e.t) > pruneAfter then baseAttemptAt[k] = nil end
        end
        baseAttemptAt[key] = {
            t = now, id = pair.from,
            tries = (entry and entry.id == pair.from) and (entry.tries + 1) or 1,
        }
        baseEvolve(mgr, handle, actor, param, pair, isAlpha, level, key,
            ownerUidString(param))
        return true
    end

    -- circular sweep from a rotating start, exactly like the wild scanner: a
    -- camp bigger than the budget still gets every worker examined within a
    -- few sweeps, no matter how crowded the head of the actor list is
    local start = baseScanOffset % n
    local advanced = 0
    for step = 0, n - 1 do
        if budget <= 0 then break end
        advanced = step + 1
        if consider(list[((start + step) % n) + 1]) then break end
    end
    baseScanOffset = (start + advanced) % n
    if Config.devMode and budget < BASE_SCAN_BUDGET then
        Log(string.format("[baseevolve] examined %g camp workers of %g actors",
            BASE_SCAN_BUDGET - budget, n))
    end
end

function Evolution.rollbackLast(playerCtx)
    -- rolling back IS reaching for evolution: the pollers must yield for the
    -- usual window afterwards, or the base sweep can re-evolve a camp pal the
    -- player just undid. Stamped before the lock gate, like Evolution.check.
    lastManualActionAt = os.clock()
    -- Role.ack, not Role.chat (upstream 1.4.2 fix): EnterChat runs on BOTH
    -- sides of a dedicated connection, and the client-side run would answer
    -- "no snapshot" against its own empty list - ack replies only where the
    -- authority actually evaluated the command
    local function say(msg)
        Log(msg)
        if playerCtx then Role.ack(playerCtx, msg) end
        -- DarnToasts is ADDITIVE here, unlike the notice-class prompts: these
        -- receipts have always been chat-class, so the toast rides ALONGSIDE
        -- the ack instead of replacing it - nothing is taken away from a
        -- player without the framework. Local requester only: a remote one
        -- reads their ack on their own machine, where their own copy of this
        -- mod would have to draw it.
        if playerCtx and playerCtx.isLocal then
            Evolution.Toasts.notify(msg)
        end
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
                    -- Re-point the work-suitability override at the species the
                    -- pal is again, or the camp keeps assigning the evolved
                    -- form's jobs for the rest of the session. The earlier
                    -- nil-ctx call was pulled because the save-struct rebuild
                    -- had no live context object here and only burned the
                    -- honest-line latch; the companion needs nothing but the
                    -- parameter, and the forward path's own 2s per-cid belt is
                    -- what makes a repeat harmless (the CharacterID has just
                    -- changed back, so this call is not one).
                    if p:IsValid() then
                        refreshWorkSuitability(p, nil, nil)
                    end
                    reverted = true
                    -- Presentation, entirely optional: the revert above is
                    -- already done and durable, so a failure here only means
                    -- the player recalls the pal by hand to see the old form.
                    pcall(function() resummonAfterRollback(playerCtx, p) end)
                end
                break
            end
        end
    end
    if reverted then
        -- Give the price back: the evolution is undone, so keeping the stones
        -- would charge for something that no longer happened. Only after the
        -- restore actually succeeded, and only what THIS evolution recorded -
        -- re-pricing it now would price it at the level the pal has since
        -- reached. A free evolution (and every base-camp one, which is free by
        -- construction) recorded nothing, and says so by staying on the plain
        -- line rather than claiming a refund it never made.
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
        -- console-only detail: the entry SURVIVES a miss, so the retry the
        -- player needs to hear about is still available
        Log("Rollback: snapshot kept - bring the pal nearby and retry")
    end
end

-- Localized readout of a pal's configured evolutions for UI surfaces
-- (statuspage.lua): one line per target, either/or variants collapsed the
-- same way the radial submenu does. Pure read - no gates are evaluated;
-- requirements render as text, with costs priced at the pal's current
-- level (material prices are level-banded).
function Evolution.describeEvolutionsFor(param)
    if not (param and param:IsValid()) then return nil end
    local okAll, result = pcall(function()
        local id, isAlpha = baseCharacterId(param:GetCharacterID():ToString())
        local pairList = Config.findPairs(id)
        if not pairList or #pairList == 0 then return nil end
        local level = 0
        pcall(function() level = param:GetLevel() end)
        -- the same world context listOptions uses: cost resolution must
        -- never write a weaker-context (fallback-stone) guess into the
        -- shared price cache that the charging path reads later
        local worldCtx = nil
        pcall(function() worldCtx = findHolderFor(Role.localPlayerCtx(), nil) end)
        worldCtx = worldCtx or param
        local order, byTarget = {}, {}
        for _, pair in ipairs(pairList) do
            -- floored: minLevel is config-derived and %d throws on floats
            local minLv = math.floor(tonumber(pair.minLevel) or 1)
            local entry
            if isAlpha and not swapTargetId(pair, true) then
                entry = string.format("Lv %d (no Alpha form)", minLv)
            else
                local reqs = { string.format("Lv %d", minLv) }
                local condText = Conditions.describe(pair)
                if condText then table.insert(reqs, condText) end
                pcall(function()
                    local costList = Costs.resolve(pair, level, worldCtx)
                    if #costList > 0 then
                        table.insert(reqs, Costs.describe(costList))
                    end
                end)
                entry = table.concat(reqs, ", ")
            end
            local bucket = byTarget[pair.to]
            if bucket then
                table.insert(bucket, entry)
            else
                byTarget[pair.to] = { entry }
                table.insert(order, pair.to)
            end
        end
        local lines = {}
        for _, to in ipairs(order) do
            table.insert(lines, string.format("%s: %s",
                palDisplayName(to), table.concat(byTarget[to], I18n.msg("orJoiner"))))
        end
        return lines
    end)
    if okAll then return result end
    return nil
end

-- Species-level readout for the Palpedia (palpedia.lua): keyed by
-- CharacterID string - there is no individual, so costs are priced at each
-- pair's own minimum level and alpha-form notes do not apply (Paldex
-- entries are base species). Returns structured entries, one per target:
-- { name, reqs, kind, element } where kind is "adaptation" (same-species
-- element variant) or "evolution", classified by the pair's CATEGORY - not
-- by its stone: under the primed-stone economy an evolution pair may charge
-- an elemental (primed) stone while remaining an evolution on every display
-- surface. element names the adaptation's element when one resolves.
-- A species with no configured pairs returns {} (a legitimate blank);
-- nil means the lookup itself FAILED - the caller may retry, never cache
-- an error-shaped nil as "has no evolutions".
function Evolution.describeEvolutionsForSpecies(rawId)
    if type(rawId) ~= "string" or rawId == "" or rawId == "None" then return nil end
    local okAll, result = pcall(function()
        local id = baseCharacterId(rawId)
        local pairList = Config.findPairs(id)
        if not pairList or #pairList == 0 then return {} end
        local worldCtx = nil
        pcall(function() worldCtx = findHolderFor(Role.localPlayerCtx(), nil) end)
        local order, byTarget = {}, {}
        for _, pair in ipairs(pairList) do
            local minLv = math.floor(tonumber(pair.minLevel) or 1)
            local reqs = { string.format("Lv %d", minLv) }
            local condText = Conditions.describe(pair)
            if condText then table.insert(reqs, condText) end
            pcall(function()
                if worldCtx then
                    local costList = Costs.resolve(pair, minLv, worldCtx)
                    if #costList > 0 then
                        table.insert(reqs, Costs.describe(costList))
                    end
                end
            end)
            local entry = table.concat(reqs, ", ")
            local bucket = byTarget[pair.to]
            if bucket then
                table.insert(bucket.variants, entry)
            else
                -- either/or variants of one target share the kind, so the
                -- first pair classifies the whole bucket. Kind comes from the
                -- pair CATEGORY, not the stone: under the primed-stone economy
                -- evolution-category pairs may carry stone="adaptation" (they
                -- charge the target-element primed stone) yet must still read
                -- "(Evolution)" on the Palpedia/status surfaces, not
                -- "(X Adaptation)". With primedNaming OFF the fork reverts to
                -- the classic tag-by-stone (pre-economy): the tag then names
                -- which stone the pair charges.
                bucket = { variants = { entry }, kind = "evolution", element = nil }
                local tagAsAdaptation
                if Config.stoneNames.primedNaming == false then
                    tagAsAdaptation = (pair.stone == "adaptation")
                else
                    tagAsAdaptation = (pair.category == "adaptation")
                end
                if tagAsAdaptation then
                    bucket.kind = "adaptation"
                    pcall(function()
                        bucket.element = Elements.adaptationElement(pair, worldCtx)
                    end)
                end
                byTarget[pair.to] = bucket
                table.insert(order, pair.to)
            end
        end
        local entries = {}
        for _, to in ipairs(order) do
            local b = byTarget[to]
            table.insert(entries, {
                name = palDisplayName(to),
                reqs = table.concat(b.variants, I18n.msg("orJoiner")),
                kind = b.kind,
                element = b.element,
            })
        end
        return entries
    end)
    if okAll then return result end
    return nil
end

function Evolution.init()
    loadSnapshots()

    -- authority entry for in-process and network requests
    Authority.bind({ evolve = handleEvolveRequest })

    -- host side of the net channel: decode connected-client evolve requests
    -- and run them through the fully-revalidating index handler. The hook
    -- fires only where the game routes _ToServer RPCs (the authority); on a
    -- pure client it registers but never fires.
    NetChannel.initHost(function(senderCtx, pairIndex, freeOnly)
        return handleEvolveByIndex(senderCtx, pairIndex, freeOnly)
    end)

    -- client side of the net channel: the host drives the presentation with
    -- phase signals (start/ready/reveal) which we play locally (no local
    -- player = no-op, so this is harmless on a dedicated server)
    NetChannel.initClient(function(kind)
        Evolution.onNetSignal(kind)
    end, ServerCheck.onPong)

    -- keybinds are player input - meaningless on a dedicated server
    if not Role.isDedicated() then
        local lastPress = 0
        RegisterKeyBind(Key[Config.confirmKey], function()
            -- options sync, FIRST and before every early return below: pump has
            -- several independent drivers because any single one can be
            -- config-disabled (the three pollers all are), and this handler is
            -- armed on every non-dedicated session no matter what the menu
            -- says. Rate-limited inside, pure Lua, pcall'd - it can neither
            -- cost this press anything nor break it.
            if ModOptions then pcall(ModOptions.pump) end
            -- the options menu is capturing a key for a rebind: this is the
            -- framework's GLOBAL capture flag, true while ANY mod's keybind row
            -- is capturing - not only ours - which is exactly what we want,
            -- since the press belongs to whoever is rebinding until they pick
            -- or cancel (one shared-variable read, no timer - the framework's
            -- documented guard for a shared key)
            if ModOptions and ModOptions.captureActive() then return end
            local now = os.clock()
            if (now - lastPress) < Config.debounceSeconds then return end
            lastPress = now
            ExecuteInGameThread(function()
                local ok, err = pcall(Evolution.check)
                if not ok then Log("check FAIL: " .. tostring(err)) end
            end)
        end)

        -- auto-evolve poller: player-side only, same reasoning as the
        -- keybind - a dedicated server has no local player, and each
        -- connected client polls its own summoned pal. Idle ticks stay OFF
        -- the game thread (house rule: forever-churned transient
        -- ExecuteInGameThread refs are what UE4SS's callback GC occasionally
        -- frees while still scheduled) - the pre-checks below are pure Lua.
        local autoCfg = Config.autoEvolve or {}
        if autoCfg.enabled then
            local intervalMs = math.floor(math.max(1000,
                (tonumber(autoCfg.intervalSeconds) or 5) * 1000))
            LoopAsync(intervalMs, function()
                -- ServerCheck settles "local"/"remote" only once a world is
                -- entered and classified: at the title screen and during a
                -- join's resolving window nothing enters the game thread
                local st = ServerCheck.getStatus()
                if st ~= "local" and st ~= "remote" then return false end
                if sequenceRunning then return false end
                ExecuteInGameThread(function()
                    local t0 = Config.devMode and os.clock() or nil
                    local ok, err = pcall(autoEvolveTick)
                    if t0 then recordTick("autoevolve", os.clock() - t0) end
                    if not ok then Log("auto-evolve FAIL: " .. tostring(err)) end
                end)
                return false
            end)
            -- devMode tick-cost telemetry: pure-Lua logging, no
            -- ExecuteInGameThread, loop not started at all when devMode is off
            if Config.devMode then
                LoopAsync(60000, function()
                    reportTicks("autoevolve")
                    return false
                end)
            end
            Log(string.format("auto-evolve armed (every %gs, free evolutions only)",
                intervalMs / 1000))
        end
    end

    -- primed-pal scanner: an AUTHORITY feature (single player, listen host
    -- or dedicated server - wild pals are world simulation; clients just
    -- see the result replicate, so this arms OUTSIDE the keybind gate).
    -- Off-thread pre-gates keep idle ticks off the game thread: on a pure
    -- client ServerCheck never settles "local", and an empty dedicated
    -- server backs off via the nopawns skip counter.
    local primedCfg = Config.primedPals or {}
    if primedCfg.enabled then
        local primedMs = math.floor(math.max(1000,
            (tonumber(primedCfg.scanIntervalSeconds) or 2) * 1000))
        armPcNotify()
        local idleSkips = 0
        LoopAsync(primedMs, function()
            if idleSkips > 0 then
                idleSkips = idleSkips - 1
                return false
            end
            if not Role.isDedicated() and ServerCheck.getStatus() ~= "local" then
                return false
            end
            ExecuteInGameThread(function()
                local t0 = Config.devMode and os.clock() or nil
                local ok, res = pcall(primedTick)
                if t0 then recordTick("primed", os.clock() - t0) end
                if not ok then
                    Log("primed FAIL: " .. tostring(res))
                elseif res == "nopawns" then
                    idleSkips = 14 -- empty server: ease off for ~30s
                end
            end)
            return false
        end)
        if Config.devMode then
            LoopAsync(60000, function()
                reportTicks("primed")
                return false
            end)
        end
        Log(string.format("Primed Pals armed (every %gs, %g%% base chance)",
            primedMs / 1000, tonumber(primedCfg.chance) or 10))
        -- first use of the gate: builds it, so the scanner's own lazy check
        -- is already satisfied by the time the first tick runs
        local gate = primedGate()
        if not gate.empty then
            Log("[primed] situational gate: " .. (Conditions.describe(gate) or "?"))
        end
    end

    -- base-pal auto-evolve: an AUTHORITY feature like the wild scanner (camps
    -- are world simulation), so it arms OUTSIDE the keybind gate and runs on
    -- dedicated servers too. It also respects the master autoEvolve switch.
    -- Same off-thread pre-gates: a pure client never settles "local", and an
    -- empty server backs off through the noplayers skip counter.
    local baseCfg = Config.autoEvolve or {}
    local baseArmed = (baseCfg.enabled == true) and (baseCfg.basePals ~= false)
    if baseArmed then
        local baseMs = math.floor(math.max(15000,
            (tonumber(baseCfg.baseIntervalSeconds) or 45) * 1000))
        armPcNotify()
        local baseIdleSkips = 0
        LoopAsync(baseMs, function()
            if baseIdleSkips > 0 then
                baseIdleSkips = baseIdleSkips - 1
                return false
            end
            if not Role.isDedicated() and ServerCheck.getStatus() ~= "local" then
                return false
            end
            -- pure-Lua lock peek: while any evolution runs there is nothing
            -- for this sweep to do, and entering the game thread just to be
            -- turned away churns transient callback refs. Bounded by the
            -- sequence budget so a leaked lock cannot strand the feature -
            -- past it the tick runs and lockBusy's watchdog frees it.
            if sequenceRunning
                and (os.clock() - sequenceStartedAt) < sequenceBudgetS then
                return false
            end
            ExecuteInGameThread(function()
                local t0 = Config.devMode and os.clock() or nil
                local ok, res = pcall(baseEvolveTick)
                if t0 then recordTick("baseevolve", os.clock() - t0) end
                if not ok then
                    Log("base auto-evolve FAIL: " .. tostring(res))
                elseif res == "noplayers" then
                    baseIdleSkips = 4 -- empty server: ease off
                end
            end)
            return false
        end)
        if Config.devMode then
            LoopAsync(60000, function()
                reportTicks("baseevolve")
                return false
            end)
        end
        Log(string.format("base auto-evolve armed (every %gs, free condition-less pairs)",
            baseMs / 1000))
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
    -- The monster registry rides the SAME two-stable-polls gate, but has its
    -- own completion state: it additionally waits for world authority to
    -- settle. Attempts are bounded so a process that never gets authority (a
    -- pure client - where both scanners' pre-gates mean the registry would
    -- never be read or swept anyway) stops polling instead of churning
    -- transient ExecuteInGameThread refs forever. BOTH readers arm it: with
    -- Primed Pals off, the base sweep is the one that would otherwise be left
    -- paying a FindAllOf every pass.
    local registryDone = not (primedCfg.enabled or baseArmed)
    local registryAttempts = 0
    local REGISTRY_ATTEMPT_BUDGET = 24 -- ~2 minutes at the 5s cadence below
    local function tryArmRegistry()
        if registryDone then return true end
        if primedRegistryArmed then
            registryDone = true
            return true
        end
        registryAttempts = registryAttempts + 1
        if registryAttempts > REGISTRY_ATTEMPT_BUDGET then
            registryDone = true -- give up quietly; the legacy scan stands
            return true
        end
        -- authority only: the scanner is an authority feature, so a connected
        -- client must never attach the notify (nothing there would ever sweep
        -- the registry). A listen host that still reads false right after
        -- world entry flips true within a few passes.
        if not cachedWorldAuthority() then return false end
        pcall(armPrimedRegistry)
        if primedRegistryArmed then registryDone = true end
        return registryDone
    end
    local function tryHook()
        if hookRegistered and registryDone then return true end
        local player = FindFirstOf("PalPlayerCharacter")
        if not (player and player:IsValid()) then
            stablePolls = 0
            return false
        end
        stablePolls = stablePolls + 1
        if stablePolls < 2 then return false end
        if hookRegistered then
            tryArmRegistry()
            return hookRegistered and registryDone
        end
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
        -- The registry arming rides this same settled-world gate: even though
        -- its notify targets the native base (never the BP - see
        -- PRIMED_NOTIFY_PATH), attaching anything to the monster hierarchy
        -- during a world-load actor storm is the documented process-abort trap.
        -- Failure is soft: the scanner keeps its per-tick FindAllOf.
        tryArmRegistry()
        return hookRegistered and registryDone
    end
    -- The notification is client-side UX (fanfare + on-screen hint); on a
    -- dedicated server the poll would churn transient callback refs forever
    -- (no local player pawn ever exists), so it must not run there.
    if not Role.isDedicated() then
        if not tryHook() then
            LoopAsync(5000, function()
                if hookRegistered and registryDone then return true end
                ExecuteInGameThread(function() tryHook() end)
                return hookRegistered and registryDone
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
            -- Which tree is this world running. Answers the support question
            -- "are we even playing by the same rules" in one line, and it is the
            -- same identity a host and a client can hold up against each other.
            -- NOT dev-gated: it names no CharacterID, only the hash, the pair
            -- count and where the map came from. config.lua owns treeHash and
            -- builtinMap; an older config still resident (load order, a partial
            -- update) degrades to a plain "unavailable" ack rather than throwing
            -- inside a chat handler.
            tree = function(senderCtx)
                if type(Config.treeHash) ~= "function" then
                    Role.ack(senderCtx, "[Palvolve] tree info unavailable")
                    return
                end
                local okHash, hash, n = pcall(Config.treeHash)
                if not (okHash and hash) then
                    Role.ack(senderCtx, "[Palvolve] tree info unavailable")
                    return
                end
                -- no built-in map to compare against means nothing replaced it
                local origin = "custom"
                if not Config.builtinMap then
                    origin = "built-in"
                else
                    local okB, builtinHash = pcall(Config.treeHash, Config.builtinMap)
                    if okB and builtinHash == hash then origin = "built-in" end
                end
                -- pair count comes from another module: floor + %g, never %d
                Role.ack(senderCtx, string.format("[Palvolve] tree %s / %g pairs / %s",
                    tostring(hash), math.floor(tonumber(n) or 0), origin))
            end,
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
                    local raw = param:GetCharacterID():ToString()
                    local id, isAlpha = baseCharacterId(raw)
                    table.insert(out, string.format("raw='%s' id='%s' alpha=%s", raw, id, tostring(isAlpha)))
                    local pairs_ = Config.findPairs(id)
                    table.insert(out, "findPairs=" .. #pairs_)
                    for i, p in ipairs(pairs_) do
                        table.insert(out, string.format("  [%d] ->%s cat=%s stone=%s lvl=%d en=%s",
                            i, p.to, tostring(p.category), tostring(p.stone), p.minLevel or -1, tostring(p.enabled)))
                    end
                    -- canOffer keeps its own reason now, so the probe reads that
                    -- instead of re-deriving a breadcrumb list beside it: one
                    -- source of truth, and it is the same string the log line
                    -- and the player's chat line carry
                    local canOk, canRes = pcall(Evolution.canOffer)
                    table.insert(out, string.format("canOffer pcallOk=%s result=%s reason=%s",
                        tostring(canOk), tostring(canRes),
                        Diag.lastOfferReason or "(none - offered)"))
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

    Log(string.format("Evolution core active: %s = check/confirm, chat: !palvolve rollback",
        Config.confirmKey))
end

return Evolution
