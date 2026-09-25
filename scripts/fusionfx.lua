-- fusionfx.lua: the altar fusion as a scene, about 17 seconds plus the reveal.
--
--   call       both Pals roar on their pedestals, lightning strikes the gate
--   gather     light rises from them, they lift straight up off the pedestals
--   swirl      they glide out in front of the gate and circle each other,
--              faster and closer, with a vortex in the gate behind them
--   compress   they spiral into one point of light
--   silence    everything stops for a breath
--   burst      both elements at once, then the caller commits the fusion
--   reveal     the fused Pal grows out of the light and lands on pedestal 1,
--              with the evolution finale in its colours
--   hero       it roars on the pedestal
--
-- fusioncam.lua films it for a player standing near the altar.
--
-- The Pals hang on a turning pivot (fusionrig.lua): the engine moves them every
-- frame, Lua only sets the course. The circle sits in front of the gate, far
-- enough out that neither body reaches a pillar.
--
-- A scene has two parts. The logic (commit at the burst, the fused Pal set down)
-- runs where the world is owned. The picture (movement, effects, sound, camera)
-- runs where a player watches: effects, sounds and the camera are local, and a
-- dedicated server replicates none of them. Single player and a listen host do
-- both in one scene; a dedicated server runs the logic alone and tells the
-- players near the altar to play the picture (FusionFx.playRemote).
--
-- One LoopAsync driver hands every tick to the game thread through named
-- functions: a closure per tick feeds UE4SS's callback collector, and a
-- collected callback that is still scheduled stops every timer of the mod
-- (UE4SS-LESSONS.md section 1). Every step checks the actors it touches, so a
-- player leaving mid-scene ends it instead of faulting natively.

local Elements = require("elements")
local Recipes = require("finale_recipes")
local Finale = require("finale")
local FusionCam = require("fusioncam")
local Rig = require("fusionrig")
local Sound = require("sound")
local Role = require("role")

local FusionFx = {}

local function Log(msg)
    print(string.format("[Palvolve] [fusionfx] %s\n", tostring(msg)))
end

-- With devMode on, every step of a scene goes to a file of its own that is
-- flushed per line: a native crash cuts off the end of UE4SS.log, and the end
-- is where the answer is.
local traceFile = nil
local function trace(msg)
    local okCfg, cfg = pcall(require, "config")
    if not (okCfg and cfg.devMode) then return end
    if not traceFile then
        local dir = cfg.stateDir and cfg.stateDir()
        if not dir then
            Log("[WARN] scene trace off: no state folder")
            return
        end
        traceFile = io.open(dir .. "\\fusion-scene-trace.log", "a")
        if not traceFile then
            Log("[WARN] scene trace off: file not writable")
            return
        end
    end
    traceFile:write(string.format("%.3f %s\n", os.clock(), tostring(msg)))
    traceFile:flush()
end
FusionFx._trace = trace

local TICK_MS = 33
-- scene time (s) at which each beat starts
local T_GATHER, T_GLIDE, T_SWIRL, T_COMPRESS, T_SILENCE, T_BURST = 1.5, 3.0, 4.0, 9.0, 10.0, 10.4
local RISE_S = T_GLIDE - T_GATHER
local GLIDE_S = T_SWIRL - T_GLIDE
local SWIRL_S = T_COMPRESS - T_SWIRL
local COMPRESS_S = T_SILENCE - T_COMPRESS
local HOLD_S = 3.0 -- the fused Pal on its pedestal before the camera hands back
local REVEAL_S = 3.5 -- growing time when the finale does not set one
local LAND_AFTER_PEAK_S = 0.4 -- the fused Pal touches down this long after the finale's peak
local TAIL_OUT_S = 1.2 -- finale lights still burning this long after the landing are put out
local FIND_TIMEOUT_S = 6
local STAND = 30 -- a body's origin above its feet (every Pal capsule is this small)
local SPIN_START, SPIN_SWIRL_END, SPIN_COMPRESS_END = 40, 600, 1100 -- degrees per second
local GATE_MARGIN = 40 -- room left between a circling body and the nearest pillar
local ORBIT_HALF_WIDTH = 180 -- circling bodies shrink to about this half-width
local ORBIT_SCALE_MIN, ORBIT_SCALE_MAX = 0.35, 0.8
local MESH_WAIT_S = 2.5 -- longest wait for the fused Pal's body to take its new form
local ENCOUNT = 5 -- ActionMontageMap key of a Pal's encounter roar

local ABSORB_NS = "/Game/Pal/Effect/Weapon/Prism/NS_CaptureAbsorbToBallCenter.NS_CaptureAbsorbToBallCenter"
local ORB_NS = "/Game/Pal/Effect/Weapon/Prism/NS_CaptureAbsorbToBall.NS_CaptureAbsorbToBall"
local CLOSE_NS = "/Game/Pal/Effect/Common/PalCatch/NS_PalCatch_Close.NS_PalCatch_Close"
local IMPACT_NS = "/Game/Pal/Effect/Common/RaidBoss/NS_RaidBoss_Summon_Impact.NS_RaidBoss_Summon_Impact"
local COMET_NS = "/Game/Pal/Effect/Common/RaidBoss/NS_RaidBoss_Summon_Comet.NS_RaidBoss_Summon_Comet"
local VORTEX_NS = "/Game/Pal/Effect/Common/RaidBoss/NS_RaidBoss_Summon_00.NS_RaidBoss_Summon_00"
local SPEEDLINE_NS = "/Game/Pal/Effect/CutScene/Electric_Boss/NS_ElectricBoss_SpeedLine.NS_ElectricBoss_SpeedLine"
local ROAR_NS = "/Game/Pal/Effect/CutScene/Electric_Boss/NS_ElectricBoss_Roar.NS_ElectricBoss_Roar"
local LIGHTNING_NS = "/Game/Pal/Effect/Skill/ThunderRain/NS_LightningStrike.NS_LightningStrike"

local SE = "/Game/Pal/Sound/Events/SE/"
local SND_HAZE = SE .. "MapObject/PalSummoningStand/AKE_Summon_Haze_01.AKE_Summon_Haze_01"
local SND_CHARGE = SE .. "Pal/RaidBoss/NightLady/AKE_Pal_Nightlady_FormChange_EnergyCharge_01.AKE_Pal_Nightlady_FormChange_EnergyCharge_01"
local SND_SWIRL = SE .. "Skill/UniqueSkills/LegendDeer_ModeChange/AKE_LegendDeer_Modechange_Charge.AKE_LegendDeer_Modechange_Charge"
local SND_BURST = SE .. "Pal/RaidBoss/KingBahamut_Dragon/AKE_Pal_KingBahamut_Dragon_FormChange_EnergyBurst_01.AKE_Pal_KingBahamut_Dragon_FormChange_EnergyBurst_01"
local SND_BOOM = SE .. "Common/Explosion/AKE_General_Explosion.AKE_General_Explosion"
local SND_FLASH = SE .. "MapObject/PalSummoningStand/AKE_Summon_Flash_01.AKE_Summon_Flash_01"
local SND_FANFARE = SE .. "UI/CampLevelUp/AKE_CampLevelUp.AKE_CampLevelUp"

local WHITE = { R = 1, G = 1, B = 1, A = 1 }

local niagaraClass = nil
local function loadSystem(path)
    local obj = StaticFindObject(path)
    if not (obj and obj:IsValid()) then
        local okLoad, loadErr = pcall(LoadAsset, path)
        if not okLoad then Log("[WARN] effect asset did not load: " .. tostring(path) .. ": " .. tostring(loadErr)) end
        obj = StaticFindObject(path)
    end
    if not (obj and obj:IsValid()) then return nil end
    if not (niagaraClass and niagaraClass:IsValid()) then
        niagaraClass = StaticFindObject("/Script/Niagara.NiagaraSystem")
    end
    if niagaraClass and obj:IsA(niagaraClass) then return obj end
    return nil
end

local run = nil -- the one scene that plays at a time

local function spawnAt(worldCtx, path, x, y, z, scale)
    if run and run.visuals == false then return nil end
    trace("spawn " .. tostring(path))
    local ns = loadSystem(path)
    local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not (ns and lib and lib:IsValid() and worldCtx and worldCtx:IsValid()) then
        Log("[WARN] effect not spawned: " .. tostring(path))
        return nil
    end
    local s = scale or 1
    local comp = lib:SpawnSystemAtLocation(worldCtx, ns, { X = x, Y = y, Z = z },
        { Pitch = 0, Yaw = 0, Roll = 0 }, { X = s, Y = s, Z = s }, true, true, 0, false)
    -- kept until the silence beat, which puts out everything still burning
    if run and not run.burst and comp then run.fx[#run.fx + 1] = comp end
    return comp
end

local function killComp(comp)
    if comp and comp:IsValid() then
        comp:Deactivate()
        comp:K2_DestroyComponent(comp)
    end
end

local function killEffects(r)
    for i = #r.fx, 1, -1 do
        local ok, err = pcall(killComp, r.fx[i])
        if not ok then Log("[WARN] effect not put out: " .. tostring(err)) end
        r.fx[i] = nil
    end
end

local function burstFor(element)
    return Recipes.hitBursts[element] or Recipes.hitBursts.Normal
end

--- The first plain path of an element's centerpiece, else its hit burst.
local function centerpieceFor(element)
    local e = Recipes.elements[element]
    local c = e and e.centerpiece and e.centerpiece.candidates
    if type(c) == "table" then
        for _, cand in ipairs(c) do
            if type(cand) == "string" then return cand end
        end
    end
    return burstFor(element)
end

local function lerp(a, b, t) return a + (b - a) * t end
local function ease(t) return t * t * (3 - 2 * t) end
local function clamp01(t) return math.max(0, math.min(1, t)) end

--- Half the visible height of a Pal's body: effects belong at its middle, and
--- the origin of every Pal sits at its feet.
local function bodyHalf(actor)
    local ok, h = pcall(function() return actor.StaticCharacterParameterComponent.MeshCapsuleHalfHeight end)
    if ok and type(h) == "number" and h > 0 then return h end
    Log("[WARN] body height unreadable, effects use 80: " .. tostring(h))
    return 80
end

local function valid(a) return a ~= nil and a:IsValid() end

--- Half-width and half-height of a Pal's model at scale 1, from its mesh
--- bounds (tails and wings included); the capsule is the same small size for
--- every Pal and says nothing about how big one looks.
local function meshSize(actor)
    local ok, w, h = pcall(function()
        local e = actor.Mesh.SkeletalMesh:GetBounds().BoxExtent
        return math.max(e.X, e.Y), e.Z
    end)
    if ok and type(w) == "number" and w > 0 then return w, h end
    Log("[WARN] model size unreadable, the capsule stands in: " .. tostring(w))
    local half = bodyHalf(actor)
    return half, half
end

local function meshName(actor)
    local ok, n = pcall(function() return actor.Mesh.SkeletalMesh:GetFullName() end)
    return ok and n or nil
end

local function scaleTo(actor, s)
    actor:SetActorScale3D({ X = s, Y = s, Z = s })
end

local function soundOn(path, actor) Sound.onActor(path, actor, true) end

-- Montage lookup through one named callback and a shared buffer, so the map
-- walk makes no closure (UE4SS-LESSONS.md section 1).
local montageWalk = { key = nil, found = nil }
local function collectMontage(k, v)
    if k:get() == montageWalk.key then montageWalk.found = v:get() end
end

--- Plays the Pal's own encounter roar. False when it has none.
local function roar(actor)
    montageWalk.key, montageWalk.found = ENCOUNT, nil
    actor.StaticCharacterParameterComponent.ActionMontageMap:ForEach(collectMontage)
    local m = montageWalk.found
    montageWalk.found = nil
    if not (m and m:IsValid()) then return false end
    local len = actor.Mesh:GetAnimInstance():Montage_Play(m, 1.0, 0, 0.0, true)
    return (len or 0) > 0
end

local function roarLogged(actor, label)
    local ok, played = pcall(roar, actor)
    if not ok then
        Log("[WARN] roar of " .. label .. " failed: " .. tostring(played))
    elseif not played then
        Log(label .. " has no encounter roar")
    end
end

--- A world point in the scene's frame: fwd along the altar front, side along
--- pedestal 1 to 2, up from the standing height.
local function at(r, fwd, side, up)
    return r.mx + r.fx_ * fwd + r.lx * side, r.my + r.fy_ * fwd + r.ly * side, r.mz + up
end

-- ------------------------------------------------------------------ beats

local function cueCall(r)
    roarLogged(r.a, "A")
    roarLogged(r.b, "B")
    if r.gate then
        local g = r.gate
        for _, side in ipairs({ -g.side, g.side }) do
            local x, y, z = at(r, -g.back, side, g.top - STAND)
            spawnAt(r.worldCtx, LIGHTNING_NS, x, y, z, 1.0)
        end
    end
    soundOn(SND_HAZE, r.pivot)
end

local function cueGather(r)
    for _, p in ipairs({ r.a, r.b }) do
        local rel = p.RootComponent.RelativeLocation
        local yaw = p.RootComponent.RelativeRotation.Yaw
        Rig.moveTo(p, { x = rel.X, y = rel.Y, z = 0 }, yaw, 0, RISE_S, true, true)
    end
    local gx, gy, gz = r.ox, r.oy, r.oz
    if r.gate then gx, gy, gz = at(r, -r.gate.back, 0, r.gate.top * 0.45) end
    spawnAt(r.worldCtx, ABSORB_NS, gx, gy, gz, 1.4)
    soundOn(SND_CHARGE, r.pivot)
    FusionCam.shot({ yaw = 12, dist = 1150 * r.camK, up = 230, fov = 80 }, T_SWIRL - T_GATHER)
end

local function cueRiseBurst(r)
    for _, side in ipairs({ { r.a, r.elemA, r.bodyA }, { r.b, r.elemB, r.bodyB } }) do
        local l = side[1]:K2_GetActorLocation()
        spawnAt(r.worldCtx, burstFor(side[2]), l.X, l.Y, l.Z - STAND + side[3] * r.sc, 0.9)
    end
end

local function cueGlide(r)
    for _, p in ipairs({ r.a, r.b }) do
        local sign = p.RootComponent.RelativeLocation.Y < 0 and -1 or 1
        -- they face each other across the circle
        Rig.moveTo(p, { x = 0, y = sign * r.r0, z = 0 }, sign < 0 and 90 or -90, 0, GLIDE_S, true, true)
    end
end

local function cueSwirl(r)
    for _, p in ipairs({ r.a, r.b }) do
        local sign = p.RootComponent.RelativeLocation.Y < 0 and -1 or 1
        Rig.moveTo(p, { x = 0, y = sign * r.r1, z = 0 }, sign < 0 and 90 or -90, 0, SWIRL_S, true, true)
    end
    if r.gate then
        local x, y, z = at(r, -r.gate.back, 0, r.gate.top * 0.45)
        spawnAt(r.worldCtx, VORTEX_NS, x, y, z, 0.8)
    else
        spawnAt(r.worldCtx, VORTEX_NS, r.ox, r.oy, r.oz, 0.8)
    end
    spawnAt(r.worldCtx, SPEEDLINE_NS, r.ox, r.oy, r.oz, 1.0)
    soundOn(SND_SWIRL, r.pivot)
    FusionCam.shot({ yaw = -30, dist = 1050 * r.camK, up = 260, fov = 85 }, SWIRL_S)
end

local function cueCompress(r)
    for _, p in ipairs({ r.a, r.b }) do
        local faceYaw = p.RootComponent.RelativeLocation.Y < 0 and 90 or -90
        Rig.moveTo(p, { x = 0, y = 0, z = 0 }, faceYaw, 0, COMPRESS_S, false, true)
    end
    spawnAt(r.worldCtx, ABSORB_NS, r.ox, r.oy, r.oz, 1.5)
    FusionCam.shot({ yaw = -38, dist = 800 * r.camK, up = 120, fov = 64 }, COMPRESS_S)
end

local function cueSilence(r)
    for _, p in ipairs({ r.a, r.b }) do
        local okHide, hideErr = pcall(function() p:SetActorHiddenInGame(true) end)
        if not okHide then Log("[WARN] Pal not hidden for the silence: " .. tostring(hideErr)) end
    end
    r.hidden = true
    if not r.visuals then return end
    killEffects(r)
    -- the one light left: where the two became one
    local okOrb, orb = pcall(spawnAt, r.worldCtx, ORB_NS, r.ox, r.oy, r.oz, 0.6)
    if not okOrb then Log("[WARN] light point not spawned: " .. tostring(orb)) end
    Sound.stopOn(r.pivot)
    Rig.spin(r.pivot, 0)
    FusionCam.shot({ yaw = -39 }, T_BURST - T_SILENCE)
end

local function cueBurst(r)
    killEffects(r) -- the light point bursts
    r.burst = true
    r.burstAt = os.clock() - r.startedAt
    if r.visuals then
        local x, y, z = r.ox, r.oy, r.oz
        spawnAt(r.worldCtx, CLOSE_NS, x, y, z, 1.5)
        spawnAt(r.worldCtx, IMPACT_NS, x, y, r.mz - STAND, 1.2)
        spawnAt(r.worldCtx, COMET_NS, x, y, z, 1.0)
        spawnAt(r.worldCtx, centerpieceFor(r.elemA), x, y, z, 0.9)
        if r.elemB ~= r.elemA then spawnAt(r.worldCtx, centerpieceFor(r.elemB), x, y, z, 0.9) end
        Sound.at(SND_BURST, r.worldCtx, x, y, z)
        Sound.at(SND_BOOM, r.worldCtx, x, y, z)
        FusionCam.hit(0.8, WHITE, true)
        FusionCam.shot({ yaw = -28, dist = 1300 * r.camK, up = 240, fov = 88 }, 1.2)
    end
    -- a picture-only scene commits nothing: the world's owner does, and the
    -- fused Pal arrives by replication (findC)
    if not r.logic then return end
    -- The commit runs here: the scene waits in the light for the fused Pal.
    local ok, err = pcall(r.onCommit)
    if not ok then
        Log("[ERROR] commit raised: " .. tostring(err))
        FusionFx.abort("commit failed")
    end
end

local CUES = {
    { t = 0.0, fn = cueCall, name = "call" },
    { t = T_GATHER, fn = cueGather, name = "gather" },
    { t = T_GATHER + 0.1, fn = cueRiseBurst, name = "rise burst" },
    { t = T_GATHER + 0.9, fn = cueRiseBurst, name = "rise burst" },
    { t = T_GLIDE, fn = cueGlide, name = "glide" },
    { t = T_SWIRL, fn = cueSwirl, name = "swirl" },
    { t = T_COMPRESS, fn = cueCompress, name = "compress" },
    { t = T_SILENCE, fn = cueSilence, name = "silence", logic = true },
    { t = T_BURST, fn = cueBurst, name = "burst", logic = true },
}

--- Room between a body and the nearest pillar, in cm (negative: inside it).
--- Pillars stand gate.back behind the pedestal line, gate.side to either side.
local function pillarRoom(r, actor)
    local l = actor:K2_GetActorLocation()
    local dx, dy = l.X - r.mx, l.Y - r.my
    local fwd, side = dx * r.fx_ + dy * r.fy_, dx * r.lx + dy * r.ly
    local g = r.gate
    local half = g.side - g.halfInner -- a pillar's half-width
    local best = math.huge
    for _, ps in ipairs({ -g.side, g.side }) do
        local ex = math.max(0, math.abs(fwd + g.back) - g.depthHalf)
        local ey = math.max(0, math.abs(side - ps) - half)
        best = math.min(best, math.sqrt(ex * ex + ey * ey))
    end
    return best - r.bodyW
end

--- What changes a little every tick before the burst: spin, size, flares.
local function stepFlow(r, t)
    if r.gate and t >= T_SWIRL and t < T_SILENCE then
        for _, p in ipairs({ r.a, r.b }) do
            local room = pillarRoom(r, p) + r.bodyW * (1 - p:GetActorScale3D().X / r.sc)
            if room < (r.minRoom or math.huge) then r.minRoom = room end
        end
    end
    if t >= T_GATHER and t < T_GLIDE then
        local s = lerp(1, r.sc, ease(clamp01((t - T_GATHER) / RISE_S)))
        scaleTo(r.a, s)
        scaleTo(r.b, s)
    elseif t >= T_SWIRL and t < T_COMPRESS then
        local k = clamp01((t - T_SWIRL) / SWIRL_S)
        Rig.spin(r.pivot, lerp(SPIN_START, SPIN_SWIRL_END, k * k))
        -- a pulse in the centre ties the two together, faster as they speed up
        if t >= r.nextFlare then
            r.tetherA = not r.tetherA
            spawnAt(r.worldCtx, burstFor(r.tetherA and r.elemA or r.elemB), r.ox, r.oy, r.oz, lerp(0.3, 0.55, k))
            r.nextFlare = t + lerp(0.7, 0.25, k)
        end
    elseif t >= T_COMPRESS and t < T_SILENCE then
        local k = clamp01((t - T_COMPRESS) / COMPRESS_S)
        Rig.spin(r.pivot, lerp(SPIN_SWIRL_END, SPIN_COMPRESS_END, k))
        local s = lerp(r.sc, 0.03, ease(k))
        scaleTo(r.a, s)
        scaleTo(r.b, s)
    end
end

local function landHero(r)
    local okFreeze, freezeErr = pcall(r.freeze, r.c, true)
    if not okFreeze then Log("[WARN] fused Pal not re-frozen for its roar: " .. tostring(freezeErr)) end
    roarLogged(r.c, "the fused Pal")
    local l = r.c:K2_GetActorLocation()
    spawnAt(r.worldCtx, ROAR_NS, l.X, l.Y, l.Z - STAND + r.bodyC, 1.0)
    Sound.onActor(SND_FANFARE, r.c, false)
    FusionCam.hit(0.5, nil, false)
    FusionCam.shot({ yaw = 16, dist = r.heroDist * 0.8, up = 140, fov = 66 }, HOLD_S)
end

--- The reveal where nobody watches: the fused Pal is set down at once and the
--- scene holds as long as a watching player's reveal lasts, so nothing moves
--- it back while their picture still plays.
local function stepRevealLogic(r, t, land)
    if not r.landedAt then
        r.landedAt = t
        local okPlace, placeErr = pcall(function()
            r.c:K2_SetActorLocation({ X = land.x, Y = land.y, Z = land.z }, false, {}, true)
            r.c:K2_SetActorRotation({ Pitch = 0, Yaw = r.landYaw or r.frontYaw, Roll = 0 }, false)
        end)
        if not okPlace then Log("[WARN] fused Pal not set down: " .. tostring(placeErr)) end
        return
    end
    if t >= r.landedAt + REVEAL_S + LAND_AFTER_PEAK_S + HOLD_S then FusionFx.abort("revealed") end
end

local function stepReveal(r, t)
    if not valid(r.c) then return end
    local land = r.land or { x = r.ox, y = r.oy, z = r.mz }
    if not r.visuals then return stepRevealLogic(r, t, land) end
    if not r.revealStart and not r.formReady then
        -- the altar hands back a body that may still wear A's model for a moment
        if not r.foundAt then
            r.foundAt = t
            local okHide, hideErr = pcall(function() r.c:SetActorHiddenInGame(true) end)
            if not okHide then Log("[WARN] fused Pal not hidden while it takes its form: " .. tostring(hideErr)) end
        end
        local changed = meshName(r.c) ~= r.meshA
        if not changed and t - r.foundAt < MESH_WAIT_S then return end
        if not changed then Log("[WARN] the fused Pal still wears the old model, it is shown anyway") end
        Log(string.format("fused Pal takes its form after %.2f s", t - r.foundAt))
        r.formReady = true
    end
    if not r.revealStart then
        r.revealStart = t
        local okFreeze, freezeErr = pcall(r.freeze, r.c, true)
        if not okFreeze then Log("[WARN] fused Pal not frozen for the reveal: " .. tostring(freezeErr)) end
        r.bodyC = bodyHalf(r.c)
        -- the altar may hand back a pooled body that still hangs on the pivot
        Rig.detach(r.c)
        r.c:K2_SetActorLocation({ X = r.ox, Y = r.oy, Z = r.oz }, false, {}, true)
        r.c:K2_SetActorRotation({ Pitch = 0, Yaw = r.landYaw or r.frontYaw, Roll = 0 }, false)
        scaleTo(r.c, 0.03)
        local okShow, showErr = pcall(function() r.c:SetActorHiddenInGame(false) end)
        if not okShow then Log("[WARN] fused Pal not shown: " .. tostring(showErr)) end
        spawnAt(r.worldCtx, centerpieceFor(r.elemC or r.elemA), r.ox, r.oy, r.oz, 0.8)
        Sound.at(SND_FLASH, r.worldCtx, r.ox, r.oy, r.oz)
        -- the evolution finale in the new Pal's colours, where it comes to rest
        local okFinale, fin = pcall(Finale.begin, r.worldCtx, land.x, land.y, land.z - STAND,
            r.elemsC or { r.elemC or r.elemA }, STAND, r.bodyC)
        if okFinale then
            r.finale = fin
            -- the Pal reaches full size on the finale's peak and lands right after
            if fin and fin.growS and fin.growS > 0 then r.growS = fin.growS end
        else
            Log("[WARN] reveal finale did not start: " .. tostring(fin))
        end
        r.revealS = (r.growS or REVEAL_S) + LAND_AFTER_PEAK_S
        Rig.moveTo(r.c, land, r.landYaw or r.frontYaw, 0, r.revealS, true, true)
        local wC, hC = meshSize(r.c)
        -- far enough back that the finale's light ring stays in front of the lens
        r.heroDist = math.max(1600, 1100 + math.max(wC, hC) * 3)
        FusionCam.focus(land.x, land.y, land.z - STAND + hC, r.revealS)
        FusionCam.shot({ yaw = 22, dist = r.heroDist, up = 260, fov = 72 }, r.revealS)
    end
    if r.landedAt then
        -- lights that outlive the landing (the recall light keeps pulsing) are
        -- put out a moment after it, so the scene ends on the standing Pal
        if r.finale and not r.finaleOut and t >= r.landedAt + TAIL_OUT_S then
            r.finaleOut = true
            local okOut, outErr = pcall(Finale.stopAll, r.finale.f)
            if not okOut then Log("[WARN] finale lights not put out: " .. tostring(outErr)) end
        end
        if t >= r.landedAt + HOLD_S then FusionFx.abort("revealed") end
        return
    end
    local growS = r.growS or REVEAL_S
    scaleTo(r.c, lerp(0.03, 1, ease(clamp01((t - r.revealStart) / growS))))
    if t - r.revealStart >= r.revealS then
        -- the Pal stands: the finale starts nothing new, so the scene ends on it
        r.landedAt = t
        if r.finale then r.finale.f.idx = #r.finale.f.events + 1 end
        scaleTo(r.c, 1)
        local okHero, heroErr = pcall(landHero, r)
        if not okHero then Log("[WARN] hero moment failed: " .. tostring(heroErr)) end
    end
end

-- ------------------------------------------------------------------ driver

--- Puts an actor back to normal size and lets it move again.
local function releaseActor(r, actor, unhide)
    if not valid(actor) then return end
    Rig.detach(actor)
    local okScale, scaleErr = pcall(scaleTo, actor, 1)
    if not okScale then Log("[WARN] scale not reset: " .. tostring(scaleErr)) end
    if unhide then
        local okShow, showErr = pcall(function() actor:SetActorHiddenInGame(false) end)
        if not okShow then Log("[WARN] Pal not shown again: " .. tostring(showErr)) end
    end
    local okFreeze, freezeErr = pcall(r.freeze, actor, false)
    if not okFreeze then Log("[WARN] actor not unfrozen: " .. tostring(freezeErr)) end
end

local function finishRun(reason)
    if not run then return end
    local r = run
    run = nil
    -- before the burst the two Pals are still themselves: they go back as they were
    local keepA = not r.burst
    releaseActor(r, r.a, keepA and r.hidden)
    releaseActor(r, r.b, keepA and r.hidden)
    releaseActor(r, r.c, false)
    killEffects(r)
    if r.finale and not r.finaleOut then
        local okOut, outErr = pcall(Finale.stopAll, r.finale.f)
        if not okOut then Log("[WARN] finale lights not put out at the end: " .. tostring(outErr)) end
    end
    Rig.destroy(r.pivot)
    local okCam, camErr = pcall(FusionCam.stop, reason)
    if not okCam then Log("[ERROR] camera not handed back: " .. tostring(camErr)) end
    if r.minRoom then Log(string.format("closest a circling body came to a pillar: %.0f cm", r.minRoom)) end
    Log("scene ended: " .. reason)
    if r.onDone then
        local ok, err = pcall(r.onDone, reason)
        if not ok then Log("[ERROR] onDone failed: " .. tostring(err)) end
    end
end

local function tickGameThread()
    local r = run
    if not r then return end
    local t = os.clock() - r.startedAt
    if not r.burst and not (valid(r.a) and valid(r.b) and (valid(r.pivot) or not r.visuals)) then
        finishRun("a Pal left the scene")
        return
    end
    if t > r.deadline then
        finishRun("timed out")
        return
    end
    trace(string.format("tick t=%.2f burst=%s c=%s", t, tostring(r.burst), tostring(r.c ~= nil)))
    local ok, err = true, nil
    while run == r and ok and r.cue <= #CUES and t >= CUES[r.cue].t do
        local cue = CUES[r.cue]
        r.cue = r.cue + 1
        trace("beat " .. cue.name .. " camera " .. FusionCam.where())
        -- without a picture only the beats that change the world run
        if r.visuals or cue.logic then ok, err = pcall(cue.fn, r) end
        if not ok then err = cue.name .. ": " .. tostring(err) end
    end
    if run ~= r then return end
    if ok and not r.burst then
        if r.visuals then ok, err = pcall(stepFlow, r, t) end
    elseif ok and r.c then
        ok, err = pcall(stepReveal, r, t)
    elseif ok and r.findC then
        -- the fused Pal's actor is spawned by someone else (the altar respawns
        -- its phantom a moment after the commit): look for it a few times a second
        if t >= (r.nextFind or 0) then
            r.nextFind = t + 0.2
            local okFind, found = pcall(r.findC)
            if okFind and valid(found) then
                r.c = found
            elseif not okFind then
                Log("[WARN] looking for the fused Pal failed: " .. tostring(found))
            end
        end
        if not r.c and t > (r.burstAt or t) + r.findTimeout then
            finishRun("the fused Pal did not appear")
            return
        end
    end
    if run ~= r then return end
    if r.finale and not r.finaleOut then
        local okPump, pumpErr = pcall(Finale.pump, r.finale.ctx, r.finale.f, os.clock() - r.finale.startedAt)
        if not okPump then Log("[WARN] finale step failed: " .. tostring(pumpErr)) end
    end
    FusionCam.update()
    if not ok then
        Log("[ERROR] scene step failed: " .. tostring(err))
        finishRun("step failed")
    end
end

-- One driver at a time: a scene started right after another one ended would
-- otherwise get the old driver's ticks on top of its own.
local driving = false

local function tick()
    if not run then
        driving = false
        return true
    end
    ExecuteInGameThread(tickGameThread)
    return false
end
FusionFx._tick = tick -- held by the module so the scheduled callback is never collected

--- Where the circle goes: out in front of the gate, far enough that a body of
--- half-width b on radius r0 keeps GATE_MARGIN to the nearest pillar corner.
local function orbitOut(gate, r0, b)
    if not gate then return 0 end
    local corner = gate.back - gate.depthHalf -- pillar front face behind the pedestal line
    local need = r0 + b + GATE_MARGIN
    local d = math.sqrt(math.max(0, need * need - gate.halfInner * gate.halfInner)) - corner
    return math.max(60, d)
end

--- Starts the scene. opts: worldCtx, a, b (actors), center {x,y,z} (between
--- the two Pals at standing height), idA, idB, freeze(actor, frozen),
--- onCommit() (runs at the burst; must eventually call FusionFx.reveal(actorC,
--- idC) or FusionFx.awaitReveal or FusionFx.abort), onDone(reason).
--- Optional: startRadius (how far from the centre the Pals stand), land {x,y,z}
--- and landYaw (where the fused Pal comes to rest; landYaw is also the altar's
--- front), gate {back, side, halfInner, depthHalf, top} (the altar's arch, in
--- cm from the centre at pedestal height).
function FusionFx.play(opts)
    if run then return false, "a fusion scene is already playing" end
    local front = opts.landYaw or 0
    local r = {
        visuals = opts.visuals ~= false, logic = opts.logic ~= false,
        findC = opts.findC, findTimeout = opts.findTimeout or FIND_TIMEOUT_S,
        worldCtx = opts.worldCtx, a = opts.a, b = opts.b,
        mx = opts.center.x, my = opts.center.y, mz = opts.center.z,
        frontYaw = front, gate = opts.gate,
        fx_ = math.cos(math.rad(front)), fy_ = math.sin(math.rad(front)),
        lx = -math.sin(math.rad(front)), ly = math.cos(math.rad(front)),
        elemA = (Elements.of(opts.idA, opts.worldCtx) or {})[1] or "Normal",
        elemB = (Elements.of(opts.idB, opts.worldCtx) or {})[1] or "Normal",
        freeze = opts.freeze, onCommit = opts.onCommit, onDone = opts.onDone,
        land = opts.land, landYaw = opts.landYaw,
        bodyA = bodyHalf(opts.a), bodyB = bodyHalf(opts.b),
        cue = 1, nextFlare = T_SWIRL, fx = {},
    }
    local wA, hA = meshSize(opts.a)
    local wB, hB = meshSize(opts.b)
    local wMax, hMax = math.max(wA, wB), math.max(hA, hB)
    r.sc = math.max(ORBIT_SCALE_MIN, math.min(ORBIT_SCALE_MAX, ORBIT_HALF_WIDTH / math.max(wMax, hMax * 0.8)))
    local b = wMax * r.sc
    r.r0 = math.max(140, b * 1.4)
    r.r1 = math.max(b * 1.1, r.r0 * 0.6)
    r.out = orbitOut(r.gate, r.r0, b)
    r.bodyW = b
    r.lift = 150 + hMax * r.sc
    r.meshA = meshName(opts.a)
    r.ox, r.oy, r.oz = at(r, r.out, 0, r.lift)
    r.camK = math.max(1, math.min(2, (r.r0 + b) / 300))
    r.deadline = T_BURST + FIND_TIMEOUT_S + REVEAL_S + 3 + HOLD_S + 20

    if not r.visuals then
        -- the logic alone: the Pals stay where they stand until the burst
        run = r
        r.startedAt = os.clock()
        if not driving then
            driving = true
            LoopAsync(TICK_MS, FusionFx._tick)
        end
        Log(string.format("scene started without a picture (%s + %s)", r.elemA, r.elemB))
        return true
    end
    -- the pivot is local: every watching player moves their own copy of the
    -- Pals, so nothing of it replicates
    local pivot, pivotErr = Rig.pivot(opts.worldCtx, r.ox, r.oy, r.oz, front)
    if not pivot then return false, "no pivot: " .. tostring(pivotErr) end
    r.pivot = pivot
    for _, a in ipairs({ opts.a, opts.b }) do
        local okFreeze, freezeErr = pcall(opts.freeze, a, true)
        if not okFreeze then Log("[WARN] Pal not frozen for the scene: " .. tostring(freezeErr)) end
        local okAttach, attachErr = pcall(Rig.attach, a, pivot)
        if not okAttach then
            Log("[ERROR] Pal not attached to the scene: " .. tostring(attachErr))
            Rig.detach(opts.a)
            Rig.detach(opts.b)
            Rig.destroy(pivot)
            return false, "attach failed"
        end
    end
    run = r
    r.startedAt = os.clock()
    local okCam, filming = pcall(FusionCam.start, { worldCtx = opts.worldCtx,
        center = { x = r.ox, y = r.oy, z = r.oz }, frontYaw = front,
        shot = { yaw = 35, dist = 1500 * r.camK, up = 120, fov = 80 } })
    if not okCam then Log("[WARN] camera did not start: " .. tostring(filming)) end
    FusionCam.shot({ yaw = 28, dist = 1350 * r.camK, up = 150, fov = 80 }, T_GATHER)
    if not driving then
        driving = true
        LoopAsync(TICK_MS, FusionFx._tick)
    end
    Log(string.format("scene started (%s + %s), circle %.0f out, radius %.0f, scale %.2f%s%s", r.elemA, r.elemB,
        r.out, r.r0, r.sc, (okCam and filming) and ", filmed" or "", r.logic and "" or ", picture only"))
    return true
end

--- Hands the scene the fused Pal's actor for the reveal.
function FusionFx.reveal(actorC, idC)
    if not run then return end
    run.c = actorC
    run.elemsC = Elements.of(idC, run.worldCtx)
    run.elemC = (run.elemsC or {})[1]
end

--- Like reveal, for an actor that does not exist yet: findC() is asked until it
--- returns one or timeoutS runs out after the burst.
function FusionFx.awaitReveal(findC, idC, timeoutS)
    if not run then return end
    run.findC = findC
    run.findTimeout = timeoutS or FIND_TIMEOUT_S
    run.elemsC = Elements.of(idC, run.worldCtx)
    run.elemC = (run.elemsC or {})[1]
end

-- ------------------------------------------------------------------ remote picture

local REMOTE_RANGE = 4000 -- players farther from the altar do not play the picture
local BODY_REACH = 220    -- how far from a pedestal a body may stand and still count

local function readBody(c)
    if c.bHidden then return nil end
    return c:K2_GetActorLocation()
end

--- The visible Pal body closest to a point, within BODY_REACH.
local function addressOf(o) return o:GetAddress() end

local function bodyNear(x, y, z, exclude)
    local best, bestD = nil, BODY_REACH * BODY_REACH
    -- two Lua handles of one object do not compare equal: compare addresses
    local skip = nil
    if exclude then
        local okA, addr = pcall(addressOf, exclude)
        if okA then skip = addr end
    end
    for _, c in ipairs(FindAllOf("PalCharacter") or {}) do
        local okC, addr = pcall(addressOf, c)
        if okC and addr ~= skip then
            local ok, l = pcall(readBody, c)
            if ok and l and math.abs(l.Z - z) < 300 then
                local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2
                if d < bestD then best, bestD = c, d end
            end
        end
    end
    return best
end

--- A player's picture of a fusion the server runs: the server sends the altar's
--- centre, the landing point and front, and the three species. The two Pals are
--- the bodies standing on the pedestals; the fused Pal is the body that turns up
--- on pedestal 1 after the burst.
function FusionFx.playRemote(info)
    local pc = Role.getLocalPlayerController()
    if not (pc and pc:IsValid()) then
        Log("remote scene skipped: no local player")
        return false
    end
    local okPos, here = pcall(function() return pc:K2_GetPawn():K2_GetActorLocation() end)
    if not (okPos and here) then
        Log("[WARN] remote scene skipped: player position unreadable")
        return false
    end
    local c, land = info.center, info.land
    if (here.X - c.x) ^ 2 + (here.Y - c.y) ^ 2 > REMOTE_RANGE * REMOTE_RANGE then
        Log("remote scene skipped: the altar is out of view")
        return false
    end
    local Altar = package.loaded["altar"]
    local bodies = (Altar and Altar.bodiesNear) and Altar.bodiesNear(c.x, c.y, c.z) or {}
    local a, b = bodies[1], bodies[2]
    -- without the altar module (or its container) the bodies on the pedestals stand in
    a = a or bodyNear(land.x, land.y, land.z, nil)
    b = b or bodyNear(2 * c.x - land.x, 2 * c.y - land.y, land.z, a)
    if not (a and b) then
        Log(string.format("[WARN] remote scene skipped: Pals on the pedestals not found (A %s, B %s)",
            tostring(a ~= nil), tostring(b ~= nil)))
        return false
    end
    local Evolution = package.loaded["evolution"]
    local freeze = Evolution and Evolution.fusionApi and Evolution.fusionApi.freeze
    if not freeze then
        Log("[WARN] remote scene skipped: the freeze helper is not loaded")
        return false
    end
    local ok, why = FusionFx.play({
        worldCtx = pc, a = a, b = b, center = c, land = land, landYaw = info.landYaw,
        gate = Altar and Altar.GATE, idA = info.idA, idB = info.idB, freeze = freeze,
        visuals = true, logic = false, findTimeout = 10,
        -- the fused Pal is the altar's slot-1 Pal once its body turns up again
        findC = function()
            local now = (Altar and Altar.bodiesNear) and Altar.bodiesNear(c.x, c.y, c.z) or {}
            return now[1]
        end,
    })
    if not ok then
        Log("[WARN] remote scene did not start: " .. tostring(why))
        return false
    end
    run.elemsC = Elements.of(info.idC, pc)
    run.elemC = (run.elemsC or {})[1]
    Log(string.format("remote scene: %s + %s = %s", tostring(info.idA), tostring(info.idB), tostring(info.idC)))
    return true
end

--- One burst in an element's colour at a point, outside any scene.
function FusionFx.spark(worldCtx, element, x, y, z, scale)
    return spawnAt(worldCtx, burstFor(element or "Normal"), x, y, z, scale)
end

--- The pull-into-the-ball effect at a point, outside any scene.
function FusionFx.absorbAt(worldCtx, x, y, z)
    return spawnAt(worldCtx, ABSORB_NS, x, y, z, 1.2)
end

function FusionFx.abort(reason)
    finishRun(reason or "aborted")
end

function FusionFx.playing()
    return run ~= nil
end

--- Length up to the burst plus a typical reveal, for callers that budget a watchdog.
FusionFx.LENGTH_S = T_BURST + REVEAL_S + LAND_AFTER_PEAK_S + HOLD_S

return FusionFx
