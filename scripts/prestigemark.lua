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
-- Checked against the shipped assets: NS_PalSoul_* and NS_AwakeningAura carry no
-- Wwise event at all, the rest do. The silent ones therefore take as many rungs
-- as they can, and the noisy ones are muted through their AkComponent.
local STAGE_GLOW = {
    "soulblue",    -- I    silent
    "fish",        -- II
    "soulgold",    -- III  silent
    "soulpink",    -- IV   silent
    "lucky",       -- V
    "bossbody",    -- VI
    "bossbody",    -- VII
    "bossbodyp",   -- VIII
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
local function isVisibleActor(actor)
    local hidden = nil
    pcall(function() hidden = actor.bHidden end)
    if hidden == true or hidden == 1 then return false end
    return true
end

local function isPlayerActor(actor, param)
    local className = ""
    pcall(function() className = actor:GetClass():GetFullName() end)
    if type(className) == "string" and className:find("PlayerCharacter", 1, true) then
        return true
    end
    if not isLive(param) then return false end
    local flag = nil
    pcall(function() flag = param.SaveParameter.IsPlayer end)
    return flag == true
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
    local key = nil
    pcall(function() key = actor:GetAddress() end)
    if key ~= nil then return tostring(key) end
    pcall(function() key = actor:GetFullName() end)
    return key and tostring(key) or nil
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
    local half = 50
    pcall(function()
        local spc = actor.StaticCharacterParameterComponent
        if isLive(spc) and spc.MeshCapsuleHalfHeight > 0 then
            half = spc.MeshCapsuleHalfHeight
        end
    end)
    return half
end

-- No attempt is made to silence these.
--
-- Several carry an Ak event, and the sound is posted natively through
-- UPalNiagaraDataInterfaceSoundPlayer's PlaySoundOneShot - there is no child
-- AkComponent under the Niagara component to turn down. Three versions of a
-- component-side mute were written here before that was established; all of
-- them were reaching for something that does not exist.
--
-- The only reliable way to a silent marker is a silent ASSET. NS_PalSoul_* and
-- NS_AwakeningAura carry no event; the rest do, and wear their sound.

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
    local comp = nil
    pcall(function()
        local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
        if not isLive(lib) then return end
        -- SnapToTarget (2) for a system authored around a body, KeepRelativeOffset
        -- (0) for one authored around a point, which then gets lifted to the
        -- middle of the Pal instead of sitting at its feet.
        --
        -- It was KeepWorldPosition (1) once, which with a zero location put the
        -- system at the world origin: attached, reported as success, kilometres
        -- away. Two assets were blamed for that before the argument was.
        local locationType = mid and 0 or 2
        local offset = mid and { X = 0, Y = 0, Z = half } or { X = 0, Y = 0, Z = 0 }
        comp = lib:SpawnSystemAttached(system, mesh, FName("None"),
            offset, { Pitch = 0, Yaw = 0, Roll = 0 },
            locationType, false, true, 0, false)
    end)
    if not isLive(comp) then return nil end

    -- Authored for bosses and for objects, so everything is scaled to the body.
    pcall(function()
        local scale = math.max(0.4, math.min(half / 90, 1.6))
        comp:SetRelativeScale3D({ X = scale, Y = scale, Z = scale })
    end)

    return comp
end

--- The base layer plus whatever this stage adds. A stage that repeats the base
--- gets one layer, not two.
local function spawnGlow(actor, stage)
    local mesh = nil
    pcall(function() mesh = actor:GetMainMesh() end)
    if not isLive(mesh) then return false end

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
    pcall(function() comp:SetVisibility(false, true) end)
    pcall(function() comp:SetActive(false, true) end)
    pcall(function() comp:Deactivate() end)
    pcall(function() comp:K2_DestroyComponent(comp) end)
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

--- Brings one Pal's marker in line with its prestige stage. Safe to call again.
function PrestigeMark.reconcile(actor)
    if not isLive(actor) then return end

    local param = nil
    pcall(function()
        local component = actor:GetCharacterParameterComponent()
        if isLive(component) then param = component:GetIndividualParameter() end
    end)
    if not isLive(param) then return end

    if isPlayerActor(actor, param) then return end
    -- A parked pal keeps its marker drawing and sounding at the player's feet,
    -- so it loses it here rather than at the next summon.
    if not isVisibleActor(actor) then
        removeGlow(actor)
        return
    end

    -- With the debug override set, every pal wears the rung regardless of what
    -- it has earned. Without it, its own stage decides as usual.
    local stage = stageOverride or prestigeStageOf(param)
    local id = "?"
    pcall(function() id = param:GetCharacterID():ToString() end)
    trace(string.format("%s reads stage %d", id, stage))
    if stage > 0 then
        if alreadyMarked(actor) then return end
        if spawnGlow(actor, stage) then
            trace(string.format("shimmer on, stage %d", stage))
        else
            trace(string.format("stage %d but the shimmer could not be attached", stage))
        end
        return
    end
    removeGlow(actor)
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
    if not isLive(actor) then return true end

    local param = nil
    pcall(function()
        local component = actor:GetCharacterParameterComponent()
        if isLive(component) then param = component:GetIndividualParameter() end
    end)
    if not isLive(param) then return false end

    if isPlayerActor(actor, param) then return true end

    local mesh = nil
    pcall(function() mesh = actor:GetMainMesh() end)
    if not isLive(mesh) then return false end

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

    local okNotify, errNotify = pcall(function()
        NotifyOnNewObject("/Script/Pal.PalCharacter", function(object)
            pending[#pending + 1] = { actor = object, tries = 0 }
            trace(string.format("queued a pal (%d waiting)", #pending))
        end)
    end)
    if not okNotify then
        Log("prestige marker: object notification failed: " .. tostring(errNotify))
        return false
    end

    -- One loop for every pending Pal. It goes idle when the queue is empty and
    -- only enters the game thread when there is work: every ExecuteInGameThread
    -- registers a transient callback ref, and idle ticks must stay ref-free.
    LoopAsync(500, function()
        local hasNew = #pending > 0
        local hasMarked = next(marked) ~= nil
        if not (hasNew or hasMarked) then return false end

        local batch = pending
        pending = {}
        ExecuteInGameThread(function()
            for _, entry in ipairs(batch) do
                local settled = false
                local ok = pcall(function() settled = tryReconcile(entry.actor) end)
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
            local stale = {}
            for key, entry in pairs(marked) do
                if not (isLive(entry.actor) and isVisibleActor(entry.actor)) then
                    stale[#stale + 1] = { key = key, entry = entry }
                end
            end
            for _, item in ipairs(stale) do
                for _, comp in ipairs(item.entry.comps or {}) do destroyComp(comp) end
                item.entry.comps = nil
                -- a destroyed actor is gone for good; a hidden one keeps its
                -- entry so the marker returns when it is summoned again
                if not isLive(item.entry.actor) then marked[item.key] = nil end
            end
        end)
        return false
    end)

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
