-- Palvolve prestige marker: a prestiged Pal shimmers, permanently.
--
-- It spawns its OWN Niagara system attached to the Pal's mesh. The first attempt
-- reused the game's Lucky Pal status (EPalStatusID::RarePalEffect), which was
-- cheap and wrong in three ways at once:
--
--   * it is the LUCKY look, and a prestige is supposed to read as its own thing
--   * the status carries the Lucky shimmer SOUND, audible for a Pal that is not
--     even out
--   * the player character is an APalCharacter too, and it got marked as well
--
-- So the marker is drawn here instead of borrowed. That means it runs on every
-- process that DRAWS, not on the authority: a Niagara system spawned on a
-- dedicated server is seen by nobody. Each client marks the Pals it can see,
-- reading the prestige stage off the replicated save parameter.
--
-- Timing: NotifyOnNewObject on PalCharacter, drained by ONE loop with retries.
-- The obvious hook, PalCharacter:BroadcastOnCompleteInitializeParameter, was
-- tried first and never fired once: it is invoked natively, and a reflected hook
-- does not see a native call. Object notification does not go through UFunction
-- dispatch at all.
--
-- The retries are the price: a Pal is announced at construction, and both its
-- individual parameter and its replicated passive list arrive later. Same shape
-- as benchfilter.lua - a single drain loop rather than a callback per Pal,
-- because per-call closures feed UE4SS' callback collector.

local Role = require("role")
local PalPassives = require("palpassives")
local Config = require("config")
-- CharacterID -> paldex number, for every species the game ships. Used here as
-- the answer to "is this actually a Pal": the notification fires for every
-- PalCharacter, and the humans walking around a base are PalCharacters too.
local okPaldex, PALDEX = pcall(require, "paldex_static")
if not okPaldex then PALDEX = nil end

local PrestigeMark = {}

-- Which system the marker wears. Swappable at runtime through
-- `!palvolve glow <name>`, because deciding this by restarting the game once per
-- candidate is the slowest possible way to answer a question about how something
-- looks.
local GLOW = "/Game/Pal/Effect/Common/Glow/"
local BOSSAURA = "/Game/Pal/Effect/Common/BossAura/"
local RAID = "/Game/Pal/Effect/Common/RaidBoss/"

local GLOW_CHOICES = {
    fishgreen  = GLOW .. "NS_RareFishGlow_Green.NS_RareFishGlow_Green",
    fish       = GLOW .. "NS_RareFishGlow_Purple.NS_RareFishGlow_Purple",
    kingfish   = GLOW .. "NS_RareKingFishGlow.NS_RareKingFishGlow",
    lucky      = GLOW .. "NS_RarePalGlow.NS_RarePalGlow",
    crystal    = GLOW .. "NS_CrystalGlow_Rainbow.NS_CrystalGlow_Rainbow",
    goddess    = GLOW .. "NS_GoddessStatue_Glow.NS_GoddessStatue_Glow",
    bossbody   = BOSSAURA .. "NS_BossAura_Body.NS_BossAura_Body",
    bossbodyp  = BOSSAURA .. "NS_BossAura_Body_Purple.NS_BossAura_Body_Purple",
    boss       = BOSSAURA .. "NS_BossAura.NS_BossAura",
    bosspurple = BOSSAURA .. "NS_BossAura_Purple.NS_BossAura_Purple",
    statusup   = BOSSAURA .. "NS_StatusUpAura.NS_StatusUpAura",
    awaken     = "/Game/Pal/Effect/Common/AwakeningAura/NS_AwakeningAura.NS_AwakeningAura",
    -- the enhanced-mode auras a raid boss wears AFTER its transformation
    buffice    = RAID .. "NS_RaidBossModeChange_Ice_Buff.NS_RaidBossModeChange_Ice_Buff",
    buffelec   = RAID .. "NS_RaidBossModeChange_Electric_Buff.NS_RaidBossModeChange_Electric_Buff",
    deerloop   = RAID .. "NS_RaidBoss_LegendDeer_ModeChange_Loop.NS_RaidBoss_LegendDeer_ModeChange_Loop",

    -- Second sweep, after the first round was mostly rejected. These are the
    -- ones the game already attaches to a BODY and keeps there, which is the
    -- same job the marker has: soul lights and status auras.
    -- The souls are authored around a point, not around a body, so they land at
    -- the mesh origin - the feet. MID lifts them to the middle of the Pal.
    soulblue   = { path = GLOW .. "NS_PalSoul_Blue.NS_PalSoul_Blue", mid = true },
    soulgold   = { path = GLOW .. "NS_PalSoul_Gold.NS_PalSoul_Gold", mid = true },
    soulpink   = { path = GLOW .. "NS_PalSoul_Pink.NS_PalSoul_Pink", mid = true },
    dark       = "/Game/Pal/Effect/Common/StatusEffect/Darkness/NS_Status_Darkness.NS_Status_Darkness",
    flame      = "/Game/Pal/Effect/Common/StatusEffect/Flamed/NS_Status_Flamed.NS_Status_Flamed",
    shock      = "/Game/Pal/Effect/Common/StatusEffect/Electricshock/NS_Status_Electricshock.NS_Status_Electricshock",
    poison     = "/Game/Pal/Effect/Common/StatusEffect/Poisoned/NS_Status_Poisoned.NS_Status_Poisoned",
    ghost      = "/Game/Pal/Effect/Common/PalMeshEffect/NS_GhostDragonParticle.NS_GhostDragonParticle",
    stackbuff  = "/Game/Pal/Effect/CoopSkill/StackBuff/NS_CoopSkill_StackBuff.NS_CoopSkill_StackBuff",
    holy       = "/Game/Pal/Effect/Material_Instances/Particle_basic_color/NS_HolyPilar.NS_HolyPilar",
}

-- Which look a stage wears, weakest to strongest, one per stage. The author's
-- five anchor it - fishgreen < fish < lucky < statusup < awaken - and the rest
-- fill the gaps so no two prestiges look alike.
--
-- The top three are the enhanced-mode auras a raid boss wears after its own
-- transformation, because awaken was the ceiling and the ceiling had to move.
--
-- Sound cannot be turned off per marker, so it is chosen away: measured asset by
-- asset in the running game, only fish and lucky still carry a Wwise event, and
-- they hold the two rungs where nothing silent looked right yet.
local STAGE_GLOW = {
    "soulblue",    -- I    silent
    "fish",        -- II   carries a sound
    "soulgold",    -- III  silent
    "soulpink",    -- IV   silent
    "lucky",       -- V    carries a sound
    "bossbody",    -- VI   silent
    "bossbody",    -- VII  silent
    "bossbodyp",   -- VIII silent
    "awaken",      -- IX   silent
    "awaken",      -- X    silent
}

-- Set by the debug key to force ONE look on every marked Pal regardless of its
-- stage, so the five can be compared side by side. nil means "follow the stage".
local glowOverride = nil

-- Set by the debug key to PLAY a stage on an already marked Pal, so the whole
-- ladder can be walked without prestiging ten times. nil means "the Pal's own".
local stageOverride = nil

-- Layers that switch on at a stage and then STAY, under whatever that stage
-- adds on top. stackbuff is the whole marker at stage 1 and still there at
-- stage 10; shock joins it from VIII and rides along to the end.
--
-- This is what makes the ladder read as accumulation rather than as ten
-- unrelated looks: a stage 10 Pal wears everything the stages before it earned.
-- Both were chosen for how they look and both carry a Wwise event, which made
-- every rung audible, including the five that use silent assets on purpose.
-- Measured in the running game, asset by asset: statusup, crystal, goddess,
-- ghost, awaken, the three PalSoul lights and the BossAura bodies carry no
-- event; stackbuff, shock, lucky and the two fish glows do.
local PERSISTENT = {
    { name = "stackbuff", from = 1 },
    { name = "shock",     from = 8 },
}

local function glowNameFor(stage)
    if glowOverride then return glowOverride end
    local n = math.max(1, math.min(math.floor(tonumber(stage) or 1), #STAGE_GLOW))
    return STAGE_GLOW[n]
end

local MAX_TRIES = 20

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- The queue is drained for every Pal in the world, so it cannot log per call.
-- The first few outcomes answer "did it run" and "which gate closed"; after that
-- it goes quiet.
local traced = 0
local TRACE_LIMIT = 40

local function trace(reason)
    if traced >= TRACE_LIMIT then return end
    traced = traced + 1
    Log(string.format("prestige marker [%d/%d]: %s", traced, TRACE_LIMIT, reason))
end

local function isLive(object)
    return object ~= nil and object:IsValid()
end

--- The player is an APalCharacter too, and the shimmer landed on them twice.
---
--- Asked in TWO ways on purpose. SaveParameter.IsPlayer is the flag the game
--- itself uses, but it sits behind two pcalls and a nil there reads as false -
--- which is precisely how the player got marked again. The class name cannot
--- fail that way.
--- A recalled Pal is not destroyed, it is HIDDEN and parked at the player. Its
--- attached systems keep drawing and keep making noise, which is what put an
--- effect over the player's head that stayed after the Pal was called back.
-- NAMED readers, not `pcall(function() ... end)`.
--
-- UE4SS-LESSONS.md rule 2, the 18.07 hardening: an anonymous closure allocated
-- per tick or per spawn feeds the callback collector, and when it frees a ref
-- that is still scheduled the process dies with an access violation. This file
-- ran forty Pals through ten such closures each on world load and ended every
-- time on `[FCallbackGarbageCollector] Freed invalid callbacks!`.
--
-- The header of this file already claimed the loop shape avoided that. It did;
-- the reads inside it did not.
local function readHidden(actor) return actor.bHidden end
local function readClassName(actor) return actor:GetClass():GetFullName() end
local function readIsPlayer(param) return param.SaveParameter.IsPlayer end
local function readCharacterId(param) return param:GetCharacterID():ToString() end
local function readAddress(actor) return actor:GetAddress() end
local function readFullName(actor) return actor:GetFullName() end
local function readMainMesh(actor) return actor:GetMainMesh() end

local function hideComp(comp) comp:SetVisibility(false, true) end
local function deactivateComp(comp) comp:SetActive(false, true) end
local function stopComp(comp) comp:Deactivate() end
local function destroyCompNow(comp) comp:K2_DestroyComponent(comp) end

local function readIndividualParameter(actor)
    local component = actor:GetCharacterParameterComponent()
    if not isLive(component) then return nil end
    return component:GetIndividualParameter()
end

local function readCapsuleHalf(actor)
    local spc = actor.StaticCharacterParameterComponent
    if not isLive(spc) then return nil end
    return spc.MeshCapsuleHalfHeight
end

local NIAGARA_LIB = "/Script/Niagara.Default__NiagaraFunctionLibrary"

--- SnapToTarget (2) for a system authored around a body, KeepRelativeOffset (0)
--- for one authored around a point, which is then lifted to the middle of the Pal
--- instead of sitting at its feet.
---
--- It was KeepWorldPosition (1) once, which with a zero location put the system
--- at the world origin: attached, reported as success, kilometres away. Two
--- assets were blamed for that before the argument was.
local function spawnAttached(system, mesh, mid, half)
    local lib = StaticFindObject(NIAGARA_LIB)
    if not isLive(lib) then return nil end
    local locationType = mid and 0 or 2
    local offset = mid and { X = 0, Y = 0, Z = half } or { X = 0, Y = 0, Z = 0 }
    return lib:SpawnSystemAttached(system, mesh, FName("None"),
        offset, { Pitch = 0, Yaw = 0, Roll = 0 },
        locationType, false, true, 0, false)
end

local function applyScale(comp, half)
    local scale = math.max(0.4, math.min(half / 90, 1.6))
    comp:SetRelativeScale3D({ X = scale, Y = scale, Z = scale })
end

local PAL_UTILITY = "/Script/Pal.Default__PalUtility"

local function palUtilityUnsafe() return StaticFindObject(PAL_UTILITY) end
local function holderOfUnsafe(util, actor) return util:GetOtomoHolderByOtomoPal(actor) end
local function spawnedOtomoUnsafe(holder) return holder:TryGetSpawnedOtomo() end

--- True only for a Pal that sits in a party without being the one that is out.
---
--- The owner is asked, not the actor, because no flag on the actor answers this.
--- Measured on one Pal, summoned and recalled: bHidden is false either way. The
--- main mesh reads invisible even when the Pal is standing in front of you, so
--- gating on it put out every shimmer in the world. bIsPalActiveActor looked
--- right once and then flickered between true and false on a Pal that had not
--- moved, alongside ImportanceType: it tracks actor activation, not deployment.
---
--- The holder does answer it, and steadily. Measured:
---   summoned  holder=true  otomoOut=true   sameActor=true
---   parked    holder=true  otomoOut=false  sameActor=false
---   base camp holder=false
--- A Pal with no holder is in nobody's party, which covers base camp workers and
--- other players' Pals, and those keep their marker.
local function isParkedPartyPal(actor)
    local okUtil, util = pcall(palUtilityUnsafe)
    if not okUtil or not isLive(util) then return false end
    local okHolder, holder = pcall(holderOfUnsafe, util, actor)
    if not okHolder or not isLive(holder) then return false end
    local okSpawned, spawned = pcall(spawnedOtomoUnsafe, holder)
    if not okSpawned then return false end
    if not isLive(spawned) then return true end
    local okMine, mine = pcall(readAddress, actor)
    local okOut, out = pcall(readAddress, spawned)
    if not (okMine and okOut) then return false end
    return mine ~= out
end

--- Whether this Pal should be wearing its marker right now.
---
--- Every unreadable answer keeps the marker. The cosmetic is what this module is
--- for, so a read that fails costs one Pal its shimmer at worst, never all of them.
local function isVisibleActor(actor)
    local ok, hidden = pcall(readHidden, actor)
    if ok and (hidden == true or hidden == 1) then return false end
    local okParked, parked = pcall(isParkedPartyPal, actor)
    if okParked and parked == true then return false end
    return true
end

local function isPlayerActor(actor, param)
    local okName, className = pcall(readClassName, actor)
    if okName and type(className) == "string" and className:find("PlayerCharacter", 1, true) then
        return true
    end
    if not isLive(param) then return false end
    local okFlag, flag = pcall(readIsPlayer, param)
    return okFlag and flag == true
end

--- True only for a species the game ships as a Pal.
---
--- NotifyOnNewObject fires for every PalCharacter, and the NPCs are PalCharacters:
--- soldiers, merchants, villagers. Marking them was never wanted, and reaching
--- into forty of them on world load is forty chances to touch an actor that is
--- still being built. The last line before both crash dumps was one of them
--- (Female_Soldier01), which is what put this gate here.
---
--- Without the roster the gate opens rather than closes: a missing generated
--- file must not silently switch the marker off for everyone.
local function isPalSpecies(param)
    if not PALDEX then return true end
    local okId, id = pcall(readCharacterId, param)
    if not okId or type(id) ~= "string" or id == "" then return false end
    local canonical = Config.canonicalId(id)
    if PALDEX[canonical] then return true end
    -- Alphas carry a BOSS_ prefix that the paldex index does not.
    local base = tostring(canonical):match("^[Bb][Oo][Ss][Ss]_(.+)$")
    return base ~= nil and PALDEX[Config.canonicalId(base)] ~= nil
end

local function prestigeStageOf(param)
    local ok, states = pcall(PalPassives.resolve, param)
    if not ok or type(states) ~= "table" then return 0 end
    local prestige = states.prestige
    if type(prestige) ~= "table" then return 0 end
    return tonumber(prestige.stage) or 0
end

-- One entry per marked Pal, so a second pass does not stack a second system on
-- the same body.
--
-- Keyed by the object's ADDRESS, not by the actor. UE4SS hands out a fresh Lua
-- wrapper per access, so two lookups of the same UObject are different table
-- keys: an actor key looked marked when it was written and unmarked at every
-- later pass, which is why re-marking found zero pals to re-mark.
local marked = {}

local function keyOf(actor)
    local ok, key = pcall(readAddress, actor)
    if ok and key ~= nil then return tostring(key) end
    ok, key = pcall(readFullName, actor)
    return (ok and key) and tostring(key) or nil
end

local function countChoices()
    local n = 0
    for _ in pairs(GLOW_CHOICES) do n = n + 1 end
    return n
end

local function sortedNames()
    local names = {}
    for name in pairs(GLOW_CHOICES) do names[#names + 1] = name end
    table.sort(names)
    return names
end

local function indexOf(name)
    for i, candidate in ipairs(sortedNames()) do
        if candidate == name then return i end
    end
    return 0
end

local function alreadyMarked(actor)
    local key = keyOf(actor)
    if not key then return false end
    local entry = marked[key]
    if not (entry and entry.comps) then return false end
    for _, comp in ipairs(entry.comps) do
        if isLive(comp) then return true end
    end
    entry.comps = nil
    return false
end

local function bodyHalf(actor)
    local ok, value = pcall(readCapsuleHalf, actor)
    if ok and type(value) == "number" and value > 0 then return value end
    return 50
end

-- No attempt is made to silence these.
--
-- Several carry an Ak event, and the sound is posted natively through
-- UPalNiagaraDataInterfaceSoundPlayer's PlaySoundOneShot - there is no child
-- AkComponent under the Niagara component to turn down. Three versions of a
-- component-side mute were written here before that was established; all of
-- them were reaching for something that does not exist.
--
-- There IS a lever, and it is the wrong one to pull. The interface carries an
-- AkEvent pointer (Pal.hpp:30496) that could be cleared. Measured in the running
-- game: of 186 live sound interfaces, ZERO belong to a spawned component. Every
-- one of them hangs on the system asset itself, for instance
-- NS_CoopSkill_StackBuff:SystemSpawnScript.PalNiagaraDataInterfaceSoundPlayer_13.
-- Clearing that pointer silences the asset for the whole game, so the electric
-- shock status and the coop skill would go mute for the player everywhere. A
-- cosmetic does not get to do that.
--
-- The only reliable way to a silent marker is a silent ASSET. NS_PalSoul_* and
-- NS_AwakeningAura carry no event, which is why five of the ten rungs use them;
-- the rest do, and wear their sound.

--- Attaches ONE named system to the Pal's mesh. Returns the component or nil.
local function attachOne(actor, mesh, name)
    local choice = GLOW_CHOICES[name]
    if not choice then return nil end
    local path = type(choice) == "table" and choice.path or choice
    local mid = type(choice) == "table" and choice.mid == true

    local system = StaticFindObject(path)
    if not isLive(system) then
        pcall(LoadAsset, path)
        system = StaticFindObject(path)
    end
    if not isLive(system) then
        trace(string.format("'%s' is missing in this build", name))
        return nil
    end

    local half = bodyHalf(actor)
    local okSpawn, comp = pcall(spawnAttached, system, mesh, mid, half)
    if not okSpawn or not isLive(comp) then return nil end

    -- Authored for bosses and for objects, so everything is scaled to the body.
    pcall(applyScale, comp, half)

    return comp
end

--- The base layer plus whatever this stage adds. A stage that repeats the base
--- gets one layer, not two.
local function spawnGlow(actor, stage)
    local okMesh, mesh = pcall(readMainMesh, actor)
    if not okMesh or not isLive(mesh) then return false end

    local wanted, seen = {}, {}
    local function want(name)
        if not name or seen[name] then return end
        seen[name] = true
        wanted[#wanted + 1] = name
    end
    for _, layer in ipairs(PERSISTENT) do
        if stage >= layer.from then want(layer.name) end
    end
    want(glowNameFor(stage))

    local comps = {}
    for _, name in ipairs(wanted) do
        local comp = attachOne(actor, mesh, name)
        if comp then comps[#comps + 1] = comp end
    end
    if #comps == 0 then return false end

    local key = keyOf(actor)
    if key then
        local entry = marked[key] or { actor = actor }
        entry.comps = comps
        entry.stage = stage
        entry.actor = actor
        marked[key] = entry
    end
    trace(string.format("stage %d wears %s", stage, table.concat(wanted, " + ")))
    return true
end

local function destroyComp(comp)
    if not isLive(comp) then return end
    -- Deactivate alone lets a system finish what it has already emitted, and a
    -- looping aura kept drawing after a swap. Hidden, stopped and destroyed, in
    -- that order: the destroy is the one that matters and the other two make the
    -- frame in between look right. K2_DestroyComponent is the reflected name -
    -- DestroyComponent is not a UFunction on this build.
    pcall(hideComp, comp)
    pcall(deactivateComp, comp)
    pcall(stopComp, comp)
    pcall(destroyCompNow, comp)
end

--- Silences the sound OUR systems post, and nothing else the Pal owns.
---
--- The sound does not come from a component we create. UPalNiagaraDataInterface
--- SoundPlayer posts it, and the engine hangs a PalAkComponent off the Niagara
--- component that is playing. Measured on a marked Pal:
---
---   PalAkComponent attachedTo=CharacterMesh0        the Pal's own voice
---   PalAkComponent attachedTo=CollisionCylinder     the Pal's own
---   PalAkComponent attachedTo=NiagaraComponent_...  ours
---
--- So the attach parent is the whole test, and it is exact. Silencing by actor
--- instead would mute the Pal itself, and clearing the AkEvent on the data
--- interface would mute the asset for the entire game, coop skill and electric
--- shock status included: all 186 of those interfaces live on the asset, none on
--- an instance.
---
--- GetAttachChildren cannot be read from Lua here, it returns a TArray by value,
--- so the search runs the other way round: over the AkComponents, asking each
--- for its parent.
local function readAttachParent(comp) return comp:GetAttachParent() end
local function muteComp(comp) comp:SetOutputBusVolume(0.0) end
local function allAkComponents() return FindAllOf("AkComponent") or {} end

local function hushMarkerSounds(entries)
    local mine, any = {}, false
    for _, entry in ipairs(entries) do
        for _, comp in ipairs(entry.comps or {}) do
            if isLive(comp) then
                mine[comp:GetFullName()] = true
                any = true
            end
        end
    end
    if not any then return 0 end

    local okAll, all = pcall(allAkComponents)
    if not okAll then
        Log("prestige marker: could not enumerate audio components, marker stays audible")
        return 0
    end

    local hushed = 0
    for _, ak in ipairs(all) do
        if isLive(ak) then
            local okParent, parent = pcall(readAttachParent, ak)
            if okParent and isLive(parent) and mine[parent:GetFullName()] then
                if pcall(muteComp, ak) then hushed = hushed + 1 end
            end
        end
    end
    return hushed
end

--- Takes the layers off. The ENTRY stays: the Pal is still prestiged, and
--- dropping it here is what made the cycle key stop working after one failed
--- spawn - nothing was left to re-mark.
local function removeGlow(actor)
    local key = keyOf(actor)
    if not key then return end
    local entry = marked[key]
    if not entry then return end
    for _, comp in ipairs(entry.comps or {}) do destroyComp(comp) end
    entry.comps = nil
end

--- Drops a Pal from the table entirely, layers and all.
local function forget(actor)
    local key = keyOf(actor)
    if not key then return end
    local entry = marked[key]
    if not entry then return end
    for _, comp in ipairs(entry.comps or {}) do destroyComp(comp) end
    marked[key] = nil
end

--- True when this Pal is remembered at a different stage than the one it now
--- reads. The layers belong to the old stage and have to go.
local function stageChanged(actor, stage)
    local key = keyOf(actor)
    if not key then return false end
    local entry = marked[key]
    if not (entry and entry.stage) then return false end
    return entry.stage ~= stage
end

--- Records a prestige Pal without attaching anything, so the caretaker loop
--- below can find it again. Needed because the actors are pooled: a Pal that is
--- summoned later is never announced a second time.
local function remember(actor, stage)
    local key = keyOf(actor)
    if not key then return end
    local entry = marked[key] or { actor = actor }
    entry.actor = actor
    entry.stage = stage
    marked[key] = entry
end

--- Brings one Pal's marker in line with its prestige stage. Safe to call again.
function PrestigeMark.reconcile(actor)
    if not isLive(actor) then return end

    local okParam, param = pcall(readIndividualParameter, actor)
    if not okParam or not isLive(param) then return end

    if isPlayerActor(actor, param) then return end
    if not isPalSpecies(param) then return end
    -- With the debug override set, every pal wears the rung regardless of what
    -- it has earned. Without it, its own stage decides as usual.
    local stage = stageOverride or prestigeStageOf(param)
    local id = "?"
    local okId; okId, id = pcall(readCharacterId, param)
    if not okId then id = "?" end
    trace(string.format("%s reads stage %d", id, stage))
    if stage > 0 then
        -- Uncapped from here down. The trace limit exists because the queue runs
        -- for every Pal in the world, but a Pal WITH a stage is a handful at
        -- most, and these are the lines that say whether the marker works.
        --
        -- Remembered BEFORE the visibility gate, and that order is the whole
        -- point. Palworld pools its Pal actors: summoning one reuses the actor
        -- that already existed, so object notification fires once, during world
        -- load, while the Pal is still sitting in the party. Turned away at that
        -- moment without an entry, it was never looked at again and stayed dark
        -- for the session. With an entry, the caretaker loop below picks it up
        -- the moment it is actually out.
        -- A stage that moved has to redraw. alreadyMarked only asks whether
        -- ANY layer is still alive, so without this a Pal that prestiged from
        -- IX to X kept the ninth look while the table said ten.
        if stageChanged(actor, stage) then removeGlow(actor) end
        remember(actor, stage)
        if not isVisibleActor(actor) then
            removeGlow(actor)
            return
        end
        if alreadyMarked(actor) then return end
        if spawnGlow(actor, stage) then
            local key = keyOf(actor)
            if key and marked[key] then marked[key].hushed = nil end
            Log(string.format("prestige marker: %s shimmer on, stage %d", id, stage))
        else
            Log(string.format("prestige marker: %s stage %d but the shimmer could not be attached", id, stage))
        end
        return
    end
    -- Stage zero means this Pal wears nothing, so the entry goes too. Keeping it
    -- would leave a positive stage in the table that the caretaker below revives
    -- on its next tick, which is how a debug cycle put markers back on Pals that
    -- had never prestiged.
    forget(actor)
end

--- Re-marks every visible Pal as if it were at `stage`. nil restores the real
--- one. This is what the debug key drives: one press, one rung of the ladder.
---
--- The WORLD, not only the pals already marked: a pal that has never prestiged
--- is not in that list, so stepping the ladder on a freshly summoned one showed
--- nothing at all.
function PrestigeMark.setStage(stage)
    stageOverride = stage and math.max(1, math.min(math.floor(stage), #STAGE_GLOW)) or nil

    local actors = {}
    pcall(function() actors = FindAllOf("PalCharacter") or {} end)
    local count = 0
    local skipped = 0

    for _, actor in ipairs(actors) do
        if not isLive(actor) then
            skipped = skipped + 1
        elseif isPlayerActor(actor, nil) then
            -- The player character IS a PalCharacter subclass. It wore the
            -- shimmer twice before this guard existed, the second time at the
            -- height of the mesh capsule, which put a looping effect over the
            -- player's head with no way to take it off.
            skipped = skipped + 1
        else
            -- the marker always comes OFF, hidden or not: that is how a parked
            -- actor loses one it should never have had
            removeGlow(actor)
            if isVisibleActor(actor) then
                PrestigeMark.reconcile(actor)
                count = count + 1
            else
                skipped = skipped + 1
            end
        end
    end
    local label = stageOverride and tostring(stageOverride) or "real"
    Log(string.format("prestige marker: stage %s, %d pal(s) re-marked, %d skipped",
        label, count, skipped))
    pcall(function()
        Role.chat(Role.localPlayerCtx(), string.format("Palvolve prestige stage: %s", label))
    end)
    return true, label
end

function PrestigeMark.setGlow(name)
    if name == "stage" then
        glowOverride = nil
    elseif not GLOW_CHOICES[name] then
        local names = {}
        for key in pairs(GLOW_CHOICES) do names[#names + 1] = key end
        table.sort(names)
        return false, "stage " .. table.concat(names, " ")
    end
    if name ~= "stage" then glowOverride = name end

    -- Re-marked from the entries themselves rather than from a world scan: the
    -- entry already holds the actor it was made for.
    local entries = {}
    for _, entry in pairs(marked) do entries[#entries + 1] = entry end
    local count = 0
    for _, entry in ipairs(entries) do
        if isLive(entry.actor) then
            removeGlow(entry.actor)
            PrestigeMark.reconcile(entry.actor)
            count = count + 1
        end
    end
    Log(string.format("prestige marker: glow is now '%s', %d pal(s) re-marked", name, count))
    -- Into the chat, not only the log: choosing between eight looks means
    -- knowing which one is on screen right now.
    pcall(function()
        Role.chat(Role.localPlayerCtx(),
            string.format("Palvolve glow: %s (%d/%d)", name, indexOf(name), countChoices()))
    end)
    return true, name
end

--- true when the Pal is settled enough to answer, false to try again later.
local function tryReconcile(actor)
    -- Checked before EVERY reach into the actor, not once at the top. An actor
    -- is announced at construction and this runs up to MAX_TRIES ticks later, so
    -- it can be gone between two lines of this function. A pcall does not help
    -- there: reading through a destroyed UObject faults in native code and takes
    -- the process with it, which is what the two 0xffffffffffffffff dumps were.
    if not isLive(actor) then return true end

    local okParam, param = pcall(readIndividualParameter, actor)
    if not okParam or not isLive(param) then return false end

    if isPlayerActor(actor, param) then return true end
    -- Settled, and deliberately not a retry: an NPC never becomes a Pal, so
    -- retrying it would keep it in the queue for MAX_TRIES ticks for nothing.
    if not isPalSpecies(param) then return true end

    if not isLive(actor) then return true end
    local okMesh, mesh = pcall(readMainMesh, actor)
    if not okMesh or not isLive(mesh) then return false end

    if not isLive(actor) then return true end
    PrestigeMark.reconcile(actor)
    return true
end

function PrestigeMark.init()
    -- A dedicated server draws nothing, and a Niagara system spawned there is
    -- seen by no one. Every client marks what it can see.
    if Role.isDedicated() then
        Log("Prestige marker skipped: a dedicated server draws no effects")
        return true
    end

    local pending = {}

    -- Every callback below is a NAMED function, and the same object is handed to
    -- UE4SS every time. An anonymous one here is not a style question: this file
    -- used `ExecuteInGameThread(function() ... end)` inside the loop, so a fresh
    -- closure was registered on every tick that had work. UE4SS' callback
    -- collector eventually freed them, and it took the loop's own callback with
    -- it: the log then shows `[FCallbackGarbageCollector] Freed invalid
    -- callbacks!`, object notification keeps queueing Pals, and not one of them
    -- is ever processed again. Seen in the wild as "the shimmer is gone", with
    -- eighteen Pals queued and none drained.
    --
    -- The batch travels through an upvalue rather than through a capture,
    -- because the point is that the function object never changes.
    local drainBatch = nil

    local function queuePal(object)
        pending[#pending + 1] = { actor = object, tries = 0 }
        trace(string.format("queued a pal (%d waiting)", #pending))
    end

    local function registerNotify()
        NotifyOnNewObject("/Script/Pal.PalCharacter", queuePal)
    end

    local okNotify, errNotify = pcall(registerNotify)
    if not okNotify then
        Log("prestige marker: object notification failed: " .. tostring(errNotify))
        return false
    end

    local function drainOnGameThread()
            local batch = drainBatch
            drainBatch = nil
            if not batch then return end
            -- The slot is APPENDED to, never replaced, because a tick can fire
            -- again before the game thread has run this one. Overwriting it
            -- dropped a whole batch, and during a world-load stall that is every
            -- Pal in the base: the queue filled, nothing was ever drawn, and the
            -- only symptom was a Pal with no shimmer.
            for _, entry in ipairs(batch) do
                -- pcall(namedFn, arg), not a closure per entry: this runs once
                -- per queued Pal per tick, which on world load is the busiest
                -- allocation site in the file.
                local ok, settled = pcall(tryReconcile, entry.actor)
                if not (ok and settled) then
                    entry.tries = entry.tries + 1
                    if entry.tries < MAX_TRIES then
                        pending[#pending + 1] = entry
                    end
                end
            end

            -- A permanent marker needs a permanent caretaker. Object
            -- notification only ever fires for a NEW Pal, so nothing was
            -- watching the ones already wearing one: recall a Pal and its
            -- systems kept drawing and sounding at the player, because no code
            -- ran at that moment at all.
            --
            -- This is that code. It rides the loop that already exists rather
            -- than adding a timer of its own.
            -- Two directions, not one. Taking the marker off lived here
            -- already; putting it back did not, and nothing else could. Object
            -- notification fires once per NEW Pal, so a Pal stripped while it
            -- sat in the party stayed dark for the rest of the session no
            -- matter how often it was summoned again.
            -- A table of components is not proof of a visible marker: they can
            -- be destroyed with the entry left behind, and a layered marker can
            -- lose one layer and keep another. alreadyMarked answers the real
            -- question and clears an all-dead table on the way.
            local stale, revive = {}, {}
            for key, entry in pairs(marked) do
                local live = isLive(entry.actor)
                if not (live and isVisibleActor(entry.actor)) then
                    stale[#stale + 1] = { key = key, entry = entry }
                elseif entry.stage and not alreadyMarked(entry.actor)
                    and (entry.reviveFails or 0) <= MAX_TRIES then
                    revive[#revive + 1] = entry
                end
            end
            for _, item in ipairs(stale) do
                -- Parked or gone: the next summon starts with a clean slate.
                item.entry.reviveFails = nil
                if item.entry.comps then
                    Log("prestige marker: marker off, pal parked or gone")
                end
                for _, comp in ipairs(item.entry.comps or {}) do destroyComp(comp) end
                item.entry.comps = nil
                -- a destroyed actor is gone for good; a hidden one keeps its
                -- entry so the marker returns when it is summoned again
                if not isLive(item.entry.actor) then marked[item.key] = nil end
            end
            -- Bounded, because this runs every 500 ms forever. An asset that
            -- cannot spawn would otherwise retry and log twice a second for the
            -- rest of the session.
            for _, entry in ipairs(revive) do
                local ok, back = pcall(spawnGlow, entry.actor, entry.stage)
                if ok and back then
                    entry.reviveFails = nil
                    entry.hushed = nil
                    Log(string.format("prestige marker: marker back on, stage %d", entry.stage))
                else
                    entry.reviveFails = (entry.reviveFails or 0) + 1
                    if entry.reviveFails <= MAX_TRIES then
                        Log(string.format("prestige marker: a summoned pal did not get its marker back (%d/%d)",
                            entry.reviveFails, MAX_TRIES))
                    elseif entry.reviveFails == MAX_TRIES + 1 then
                        Log("prestige marker: giving up on this pal's marker until it is summoned again")
                    end
                end
            end

            -- The engine creates the sound component when the system first
            -- plays, which is after the attach, so this cannot run once at
            -- attach time. It runs here until it has silenced a Pal, and the
            -- flag keeps it from scanning every audio component twice a second
            -- for the rest of the session.
            local unhushed = {}
            for _, entry in pairs(marked) do
                if entry.comps and not entry.hushed and isLive(entry.actor) then
                    unhushed[#unhushed + 1] = entry
                end
            end
            if #unhushed > 0 then
                local hushed = hushMarkerSounds(unhushed)
                if hushed > 0 then
                    for _, entry in ipairs(unhushed) do entry.hushed = true end
                    Log(string.format("prestige marker: silenced %d marker sound(s)", hushed))
                end
            end
    end

    -- One loop for every pending Pal. It goes idle when the queue is empty and
    -- only enters the game thread when there is work.
    local function drainTick()
        local hasNew = #pending > 0
        local hasMarked = next(marked) ~= nil
        if not (hasNew or hasMarked) then return false end

        local batch = pending
        pending = {}
        if drainBatch then
            for _, entry in ipairs(batch) do drainBatch[#drainBatch + 1] = entry end
        else
            drainBatch = batch
        end

        local ok, err = pcall(ExecuteInGameThread, drainOnGameThread)
        if not ok then
            -- The batch is detached from `pending` at this point, so handing it
            -- back is the difference between a retry and a silent loss.
            for _, entry in ipairs(drainBatch or {}) do pending[#pending + 1] = entry end
            drainBatch = nil
            Log("prestige marker: drain could not reach the game thread: " .. tostring(err))
        end
        return false
    end

    LoopAsync(500, drainTick)

    -- THE Palvolve debug key. One key, re-pointed at whatever is being tested;
    -- it currently cycles the prestige shimmer. Client side and deliberately so:
    -- the chat hook only fires on the AUTHORITY while effects are drawn here, so
    -- every chat attempt needed its argument to travel first. A key press does
    -- not, which is the whole reason this exists.
    --
    -- F5, not F1: F1 opens the Creative Menu. The probe keys on F3 to F10 only
    -- exist while devMode is on (main.lua loads probes.lua behind that flag), so
    -- F5 is free on a normal client. F11 is the game's fullscreen toggle and F12
    -- belongs to Steam.
    local okKey = pcall(function()
        local code = Key and Key.F5
        if code == nil then return end
        -- the five that a stage can wear, weakest first, plus back to
        -- stage-driven. Comparing them is the whole point of the key.
        -- One press, one rung: I through X, then back to the Pal's real stage.
        -- Walking the ladder is what has to be judged; a single effect on its
        -- own is what the chat command is for.
        local steps = #STAGE_GLOW + 1
        local at = 0
        local lastPress = 0
        RegisterKeyBind(code, function()
            local now = os.clock()
            if (now - lastPress) < 0.35 then return end
            lastPress = now
            at = (at % steps) + 1
            local stage = (at <= #STAGE_GLOW) and at or nil
            ExecuteInGameThread(function() PrestigeMark.setStage(stage) end)
        end)
    end)
    if not okKey then Log("prestige marker: the debug key F5 could not be bound") end

    Log("Prestige marker active: prestiged pals shimmer (F5 cycles the look)")
    return true
end

return PrestigeMark
