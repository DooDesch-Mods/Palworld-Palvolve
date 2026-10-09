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
-- One game-thread loop (gameloop.lua) drives every tick through named
-- functions: LoopAsync plus ExecuteInGameThread 30 times a second corrupted
-- UE4SS's callback registry and crashed client and server alike
-- (UE4SS-LESSONS.md section 1). Every step checks the actors it touches, so a
-- player leaving mid-scene ends it instead of faulting natively.

local ObjTrack = require("objtrack")
local Elements = require("elements")
local Recipes = require("finale_recipes")
local Finale = require("finale")
local FusionCam = require("fusioncam")
local Rig = require("fusionrig")
local Sound = require("sound")
local Role = require("role")
local GameLoop = require("gameloop")

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
    if not okCfg then
        Log("[WARN] scene trace off: config unreadable: " .. tostring(cfg))
        return
    end
    if not cfg.devMode then return end -- tracing is disabled
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
-- The driver counts as stopped when no tick came for TICK_DEAD_S and the gap
-- is still there TICK_CONFIRM_S later.
local TICK_DEAD_S, TICK_CONFIRM_S = 2, 1
-- How often one scene starts a new driver before it ends instead.
local DRIVER_RESTARTS = 10
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
local SND_HAZE = Sound.SUMMON_HAZE
local SND_CHARGE = Sound.ENERGY_CHARGE
local SND_SWIRL = SE .. "Skill/UniqueSkills/LegendDeer_ModeChange/AKE_LegendDeer_Modechange_Charge.AKE_LegendDeer_Modechange_Charge"
local SND_BURST = Sound.FUSION_BURST
local SND_BOOM = Sound.EXPLOSION
local SND_FLASH = Sound.SUMMON_FLASH
local SND_FANFARE = SE .. "UI/CampLevelUp/AKE_CampLevelUp.AKE_CampLevelUp"

local WHITE = { R = 1, G = 1, B = 1, A = 1 }

local niagaraClass = nil
local function loadSystem(path)
    local obj = ObjTrack.static(path)
    if not (obj and obj:IsValid()) then
        local okLoad, loadErr = pcall(LoadAsset, path)
        if not okLoad then Log("[WARN] effect asset did not load: " .. tostring(path) .. ": " .. tostring(loadErr)) end
        obj = ObjTrack.static(path)
    end
    if not (obj and obj:IsValid()) then return nil end
    if not (niagaraClass and niagaraClass:IsValid()) then
        niagaraClass = ObjTrack.static("/Script/Niagara.NiagaraSystem")
    end
    if niagaraClass and obj:IsA(niagaraClass) then return obj end
    return nil
end

local run = nil -- the one scene that plays at a time

local function spawnAt(worldCtx, path, x, y, z, scale)
    if run and run.visuals == false then return nil end
    trace("spawn " .. tostring(path))
    local ns = loadSystem(path)
    local lib = ObjTrack.static("/Script/Niagara.Default__NiagaraFunctionLibrary")
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

--- The model's name, or nil when it cannot be read. r is the scene that asks;
--- a scene logs the failure once, however often it asks.
local function meshName(actor, r)
    local ok, n = pcall(function() return actor.Mesh.SkeletalMesh:GetFullName() end)
    if not ok and not r.meshWarned then
        r.meshWarned = true
        Log("[WARN] model name unreadable: " .. tostring(n))
    end
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

--- Plays the Pal's own encounter roar. False with the reason when it does not
--- play; a third value of true marks a Pal that has no roar.
local function roar(actor)
    if not valid(actor) then return false, "the Pal is gone" end
    local mesh = actor.Mesh
    if not valid(mesh) then return false, "the mesh is missing" end
    local anim = mesh:GetAnimInstance()
    if not valid(anim) then return false, "the mesh has no animation instance" end
    montageWalk.key, montageWalk.found = ENCOUNT, nil
    actor.StaticCharacterParameterComponent.ActionMontageMap:ForEach(collectMontage)
    local m = montageWalk.found
    montageWalk.found = nil
    if not (m and m:IsValid()) then return false, "no encounter montage", true end
    local len = anim:Montage_Play(m, 1.0, 0, 0.0, true)
    return (len or 0) > 0
end

local function roarLogged(actor, label)
    local ok, played, why, noRoar = pcall(roar, actor)
    if not ok then
        Log("[WARN] roar of " .. label .. " failed: " .. tostring(played))
    elseif noRoar then
        Log(label .. " has no encounter roar")
    elseif not played then
        Log("[WARN] roar of " .. label .. " skipped: " .. (why or "the montage did not play"))
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
        local changed = meshName(r.c, r) ~= r.meshA
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

--- On a player's machine the altar's Pals are replicated proxies whose
--- movement component does not tick: network smoothing parks the model where
--- the body stood before it was moved, and nothing ever pulls it back. The
--- scene and the altar move these bodies, so they put the model back on the
--- body themselves.
local function pinMesh(actor)
    local o = actor.BaseTranslationOffset
    actor.Mesh:K2_SetRelativeLocation({ X = o.X, Y = o.Y, Z = o.Z }, false, {}, false)
end

local pinWarned = false
local function pinBody(actor)
    if not valid(actor) then return end
    local ok, err = pcall(pinMesh, actor)
    if not ok and not pinWarned then
        pinWarned = true
        Log("[WARN] Pal model not held on its body: " .. tostring(err))
    end
end
local function pinBodies(r)
    pinBody(r.a)
    pinBody(r.b)
    pinBody(r.c)
end

-- Releases that a scene's end could not finish. The watchdog retries them.
local pendingRelease = {}
-- A release that keeps failing is retried this long. Past it the Pal is left
-- as it is, because a pending release keeps the next scene from starting.
local RELEASE_RETRY_S = 10
local RELEASE_STEPS = { "detach", "scale", "show", "unfreeze" }
local function showActor(actor) actor:SetActorHiddenInGame(false) end

--- Drops a release whose retry time is over. True when it was dropped.
local function releaseExpired(job)
    if os.time() <= job.giveUpAt then return false end
    local open = {}
    for _, name in ipairs(RELEASE_STEPS) do
        if not job.done[name] then open[#open + 1] = name end
    end
    Log(string.format("[ERROR] release of %s given up after %d s, not done: %s", job.label, RELEASE_RETRY_S,
        #open > 0 and table.concat(open, ", ") or "the validity check"))
    pendingRelease[job] = nil
    return true
end

local function releaseFailure(job, name, cause)
    local prior, now = job.errors[name], os.time()
    if not prior or prior.cause ~= cause then prior = { cause = cause, count = 0, notice = 0 } end
    prior.count = prior.count + 1
    if now >= prior.notice then
        prior.notice = now + 30
        Log(string.format("[ERROR] release %s %s failed (%d attempts): %s", job.label, name, prior.count, cause))
    end
    job.errors[name] = prior
end

local function releaseStep(job, name, fn, ...)
    if job.done[name] then return end -- this action already succeeded
    local ok, result = pcall(fn, ...)
    if ok and result ~= false then
        job.done[name] = true
        return
    end
    releaseFailure(job, name, ok and "the helper reported failure" or tostring(result))
end

--- Puts an actor back to normal size and lets it move again.
local function releaseActor(job)
    local ok, live = pcall(valid, job.actor)
    if not ok then
        releaseFailure(job, "validity", tostring(live))
        releaseExpired(job)
        return
    end
    if not live then
        Log("release of " .. job.label .. " skipped: the actor is gone")
        pendingRelease[job] = nil
        return
    end
    releaseStep(job, "detach", Rig.detach, job.actor)
    releaseStep(job, "scale", scaleTo, job.actor, 1)
    releaseStep(job, "show", showActor, job.actor)
    releaseStep(job, "unfreeze", job.freeze, job.actor, false)
    if job.done.detach and job.done.scale and job.done.show and job.done.unfreeze then
        pendingRelease[job] = nil
        if next(job.errors) then Log("release of " .. job.label .. " recovered") end
    else
        releaseExpired(job)
    end
end

local function cleanup(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Log("[ERROR] scene cleanup " .. name .. " failed: " .. tostring(err)) end
end

local function queueRelease(r, actor, label, unhide)
    local job = { actor = actor, label = label, freeze = r.freeze, done = { show = not unhide }, errors = {},
        giveUpAt = os.time() + RELEASE_RETRY_S }
    pendingRelease[job] = true
    cleanup("release " .. label, releaseActor, job)
end

local function reportRoom(r)
    if r.minRoom then Log(string.format("closest a circling body came to a pillar: %.0f cm", r.minRoom)) end
end

local function finishRun(reason)
    if not run then
        Log("scene end skipped (" .. tostring(reason) .. "): no scene is playing")
        return
    end
    local r = run
    run = nil
    Log(string.format("scene ending: %s; ticks %d, last step %s, burst %s",
        reason, r.ticks or 0, r.step or "starting", tostring(r.burst == true)))
    -- Every action is independent: a failed detach or effect must not prevent
    -- the view returning, the other bodies releasing, or the caller settling cost.
    if r.driver then cleanup("driver stop", GameLoop.stop, r.driver) end
    -- only a scene with a picture has a camera to give back
    if r.visuals then cleanup("camera return", FusionCam.stop, reason) end
    -- After the burst A and B can be pooled bodies; the caller restores their
    -- visibility on a failed commit. C may still be hidden while its mesh loads.
    queueRelease(r, r.a, "A", not r.burst and r.hidden)
    queueRelease(r, r.b, "B", not r.burst and r.hidden)
    if r.c then queueRelease(r, r.c, "C", true) end
    cleanup("effects", killEffects, r)
    if r.finale and not r.finaleOut then
        local okOut, outErr = pcall(Finale.stopAll, r.finale.f)
        if not okOut then Log("[WARN] finale lights not put out at the end: " .. tostring(outErr)) end
    end
    if r.pivot then cleanup("sound stop", Sound.stopOn, r.pivot) end
    cleanup("pivot removal", Rig.destroy, r.pivot)
    cleanup("pillar distance report", reportRoom, r)
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
        r.step = cue.name
        trace("beat " .. cue.name .. " camera " .. FusionCam.where())
        -- without a picture only the beats that change the world run
        if r.visuals or cue.logic then
            Log(string.format("beat %s started at %.2f s", cue.name, t))
            ok, err = pcall(cue.fn, r)
            if ok then
                Log("beat " .. cue.name .. " completed")
            else
                err = cue.name .. ": " .. tostring(err)
            end
        end
    end
    if run ~= r then
        if not ok then Log("[ERROR] scene step failed after the scene ended: " .. tostring(err)) end
        return
    end
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
    if run ~= r then
        if not ok then Log("[ERROR] scene step failed after the scene ended: " .. tostring(err)) end
        return
    end
    if not r.logic then pinBodies(r) end
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

local function tick(r)
    if run ~= r then
        Log("scene driver stopped: its scene has ended")
        return true
    end
    r.ticks = r.ticks + 1
    r.lastTick = os.clock()
    local ok, err = pcall(tickGameThread)
    if not ok then
        Log("[ERROR] scene tick failed at " .. tostring(r.step) .. ": " .. tostring(err))
        finishRun("tick failed")
    end
    return run ~= r
end

--- Starts a new driver for a scene whose ticks stopped. The scene clock runs
--- on wall time, so the next tick plays every beat that came due meanwhile.
--- False when no driver could be started.
local function restartDriver(r, gap)
    r.restarts = (r.restarts or 0) + 1
    Log(string.format("[WARN] scene ticks stopped for %.1f s at step %s, replacing driver %s (restart %d of %d)",
        gap, r.step or "starting", tostring(r.driver), r.restarts, DRIVER_RESTARTS))
    -- a stopped driver can still be registered: cancelled, it never ticks beside the new one
    if r.driver then cleanup("stopped driver removal", GameLoop.stop, r.driver) end
    r.lastTick, r.silentAt = os.clock(), nil
    r.driver = GameLoop.start(TICK_MS, r.tick, "fusion scene")
    if not r.driver then return false end
    if run ~= r then
        cleanup("driver stop after inline tick", GameLoop.stop, r.driver)
        return true
    end
    Log("scene driver restarted: " .. tostring(r.driver))
    return true
end

--- Called by the independent mod heartbeat and by requests. It replaces a
--- driver that stopped ticking, and wall time bounds a run whose scene clock
--- or driver stops advancing.
function FusionFx.watchdog()
    cleanup("pending camera", FusionCam.watchdog)
    for job in pairs(pendingRelease) do cleanup("pending release " .. job.label, releaseActor, job) end
    local r = run
    if not r then return end -- no scene to supervise
    local now, clock = os.time(), os.clock()
    local age, gap = now - r.startedWall, clock - (r.lastTick or clock)
    -- A stall of the whole game thread holds this call back as long as the
    -- scene's tick, and this call can be the first to run after it. The driver
    -- only counts as stopped when the gap is still there on a later call.
    if gap > TICK_DEAD_S then
        r.silentAt = r.silentAt or clock
    else
        r.silentAt = nil
    end
    local ticksGone = r.silentAt ~= nil and clock - r.silentAt >= TICK_CONFIRM_S
    local late = age > math.ceil(r.deadline)
    if ticksGone and not late and (r.restarts or 0) < DRIVER_RESTARTS and restartDriver(r, gap) then return end
    if ticksGone or late then
        Log(string.format("[ERROR] scene watchdog: wall age %d/%d s, tick gap %.1f/%d s, clock %.2f s, ticks %d, step %s, driver %s",
            age, math.ceil(r.deadline), gap, TICK_DEAD_S, clock - r.startedAt,
            r.ticks, r.step or "starting", tostring(r.driver)))
        finishRun(ticksGone and "scene ticks stopped" or "timed out")
    elseif now >= r.nextNotice then
        r.nextNotice = now + 5
        Log(string.format("scene heartbeat: wall %d s, clock %.2f s, ticks %d, step %s, tick gap %.1f s",
            age, clock - r.startedAt, r.ticks, r.step or "starting", gap))
    end
end

local function startDriver(r)
    r.startedAt, r.startedWall = r.startedAt or os.clock(), r.startedWall or os.time()
    r.lastTick, r.ticks, r.nextNotice = os.clock(), 0, r.startedWall + 5
    -- A late callback belongs to this run, never to a subsequent scene. GameLoop
    -- holds it in its module table for the scheduler's whole lifetime.
    r.tick = function() return tick(r) end
    r.driver = GameLoop.start(TICK_MS, r.tick, "fusion scene")
    if not r.driver then
        finishRun("scene driver did not start")
        return false
    end
    if run ~= r then
        cleanup("driver stop after inline tick", GameLoop.stop, r.driver)
        return false
    end
    Log("scene driver started: " .. tostring(r.driver))
    return true
end

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
    FusionFx.watchdog()
    if next(pendingRelease) then
        Log("[WARN] scene start skipped: a previous scene still has a failed Pal release")
        return false, "a previous scene still has a failed Pal release"
    end
    if run then
        Log("scene start skipped: a fusion scene is already playing")
        return false, "a fusion scene is already playing"
    end
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
    r.meshA = meshName(opts.a, r)
    r.ox, r.oy, r.oz = at(r, r.out, 0, r.lift)
    r.camK = math.max(1, math.min(2, (r.r0 + b) / 300))
    r.deadline = T_BURST + FIND_TIMEOUT_S + REVEAL_S + 3 + HOLD_S + 20

    if not r.visuals then
        -- the logic alone: the Pals stay where they stand until the burst
        run = r
        if not startDriver(r) then return false, "scene driver did not start" end
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
            run = r
            finishRun("attach failed")
            return false, "attach failed"
        end
    end
    run = r
    r.startedAt, r.startedWall = os.clock(), os.time()
    r.lastTick, r.ticks, r.nextNotice = os.clock(), 0, r.startedWall + 5
    local okCam, filming = pcall(FusionCam.start, { worldCtx = opts.worldCtx,
        center = { x = r.ox, y = r.oy, z = r.oz }, frontYaw = front,
        shot = { yaw = 35, dist = 1500 * r.camK, up = 120, fov = 80 } })
    if not okCam then Log("[WARN] camera did not start: " .. tostring(filming)) end
    FusionCam.shot({ yaw = 28, dist = 1350 * r.camK, up = 150, fov = 80 }, T_GATHER)
    if not startDriver(r) then return false, "scene driver did not start" end
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
function FusionFx.absorbAt(worldCtx, x, y, z, scale)
    return spawnAt(worldCtx, ABSORB_NS, x, y, z, scale or 1.2)
end

--- A lightning strike at a point, outside any scene.
function FusionFx.lightningAt(worldCtx, x, y, z)
    return spawnAt(worldCtx, LIGHTNING_NS, x, y, z, 1.0)
end

--- Speed lines at a point, outside any scene.
function FusionFx.speedlinesAt(worldCtx, x, y, z)
    return spawnAt(worldCtx, SPEEDLINE_NS, x, y, z, 1.0)
end

function FusionFx.abort(reason)
    finishRun(reason or "aborted")
end

--- True while a scene plays, and while a Pal of the last one still waits for
--- its release: a new scene would be refused then.
function FusionFx.playing()
    FusionFx.watchdog()
    return run ~= nil or next(pendingRelease) ~= nil
end

--- Length up to the burst plus a typical reveal, for callers that budget a watchdog.
-- the fight fusion's ending in fx.lua uses the same roar and impact
FusionFx.roar = roarLogged
FusionFx.IMPACT_NS = IMPACT_NS

FusionFx.LENGTH_S = T_BURST + REVEAL_S + LAND_AFTER_PEAK_S + HOLD_S

return FusionFx
