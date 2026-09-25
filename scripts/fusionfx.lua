-- fusionfx.lua: the altar fusion as a scene, about 27 seconds.
--
--   charge    light rises from both Pals in their element colours
--   rise      both Pals lift off to opposite sides of the altar
--   orbit     they circle each other, faster and closer, element bursts flaring
--   collapse  they shrink into one point of light
--   burst     both elements at once, then the caller commits the fusion
--   reveal    the fused Pal grows out of the light and lands, with the
--             evolution finale in its colours cut off at the landing, then a
--             moment on its pedestal
--
-- fusioncam.lua films it for a player standing near the altar.
--
-- Server-driven actor movement, so other players see the orbit too; the
-- effects use SpawnSystemAtLocation, which renders on client proxies.
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
local CHARGE_S, RISE_S, ORBIT_S, COLLAPSE_S, BURST_S, REVEAL_S, HOLD_S = 3.0, 2.0, 11.0, 2.0, 1.0, 4.0, 3.0
local CHARGE_BEATS = { 0.2, 0.7, 1.2, 1.7, 2.2 } -- one rising burst per beat and Pal
local STAND = 30 -- a body's origin above its feet (every Pal capsule is this small)
local LAND_AFTER_PEAK_S = 0.4 -- the fused Pal touches down this long after the finale's peak
local TAIL_OUT_S = 1.2 -- finale lights still burning this long after the landing are put out
local RADIUS_START, RADIUS_END = 300, 50
local LIFT_START, LIFT_END = 150, 260
local SPEED_START, SPEED_END = 60, 900 -- degrees per second

local ABSORB_NS = "/Game/Pal/Effect/Weapon/Prism/NS_CaptureAbsorbToBallCenter.NS_CaptureAbsorbToBallCenter"
local CLOSE_NS = "/Game/Pal/Effect/Common/PalCatch/NS_PalCatch_Close.NS_PalCatch_Close"
local IMPACT_NS = "/Game/Pal/Effect/Common/RaidBoss/NS_RaidBoss_Summon_Impact.NS_RaidBoss_Summon_Impact"

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

local function spawnAt(worldCtx, path, x, y, z, scale)
    trace("spawn " .. tostring(path))
    local ns = loadSystem(path)
    local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not (ns and lib and lib:IsValid() and worldCtx and worldCtx:IsValid()) then
        Log("[WARN] effect not spawned: " .. tostring(path))
        return nil
    end
    local s = scale or 1
    return lib:SpawnSystemAtLocation(worldCtx, ns, { X = x, Y = y, Z = z },
        { Pitch = 0, Yaw = 0, Roll = 0 }, { X = s, Y = s, Z = s }, true, true, 0, false)
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

local run = nil -- the one scene that plays at a time

--- Half the visible height of a Pal's body: effects belong at its middle, and
--- the origin of every Pal sits at its feet.
local function bodyHalf(actor)
    local ok, h = pcall(function() return actor.StaticCharacterParameterComponent.MeshCapsuleHalfHeight end)
    if ok and type(h) == "number" and h > 0 then return h end
    Log("[WARN] body height unreadable, effects use 80: " .. tostring(h))
    return 80
end

local function valid(a) return a ~= nil and a:IsValid() end

local function place(actor, x, y, z, yaw)
    actor:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true)
    if yaw then actor:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false) end
end

local function scaleTo(actor, s)
    actor:SetActorScale3D({ X = s, Y = s, Z = s })
end

--- Puts an actor back to normal size and lets it move again.
local function releaseActor(r, actor)
    if not valid(actor) then return end
    local okScale, scaleErr = pcall(scaleTo, actor, 1)
    if not okScale then Log("[WARN] scale not reset: " .. tostring(scaleErr)) end
    local okFreeze, freezeErr = pcall(r.freeze, actor, false)
    if not okFreeze then Log("[WARN] actor not unfrozen: " .. tostring(freezeErr)) end
end

local function finishRun(reason)
    if not run then return end
    local r = run
    run = nil
    releaseActor(r, r.a)
    releaseActor(r, r.b)
    releaseActor(r, r.c)
    if r.finale and not r.finaleOut then
        local okOut, outErr = pcall(Finale.stopAll, r.finale.f)
        if not okOut then Log("[WARN] finale lights not put out at the end: " .. tostring(outErr)) end
    end
    local okCam, camErr = pcall(FusionCam.stop, reason)
    if not okCam then Log("[ERROR] camera not handed back: " .. tostring(camErr)) end
    Log("scene ended: " .. reason)
    if r.onDone then
        local ok, err = pcall(r.onDone, reason)
        if not ok then Log("[ERROR] onDone failed: " .. tostring(err)) end
    end
end

local function stepCharge(r, t)
    while r.chargeBeat <= #CHARGE_BEATS and t >= CHARGE_BEATS[r.chargeBeat] do
        local k = r.chargeBeat
        for _, side in ipairs({ { r.a, r.elemA, r.bodyA }, { r.b, r.elemB, r.bodyB } }) do
            local l = side[1]:K2_GetActorLocation()
            spawnAt(r.worldCtx, burstFor(side[2]), l.X, l.Y, l.Z - STAND + side[3] * 0.4 + k * 90, 0.9)
        end
        r.chargeBeat = k + 1
    end
    if not r.charged and t >= CHARGE_S - 0.4 then
        r.charged = true
        spawnAt(r.worldCtx, ABSORB_NS, r.cx, r.cy, r.cz + LIFT_START, 1.3)
    end
end

local function stepOrbit(r, t)
    local cx, cy, cz = r.cx, r.cy, r.cz
    local orbitT = math.max(0, math.min(1, (t - RISE_S) / ORBIT_S))
    local radius = t < RISE_S and r.radiusStart or lerp(r.radiusStart, RADIUS_END, ease(orbitT))
    local lift = t < RISE_S and lerp(0, LIFT_START, ease(t / RISE_S)) or lerp(LIFT_START, LIFT_END, orbitT)
    local speed = lerp(SPEED_START, SPEED_END, orbitT * orbitT)
    r.angle = r.angle + speed * (TICK_MS / 1000)
    local rad = math.rad(r.angle)
    local ax, ay = cx + math.cos(rad) * radius, cy + math.sin(rad) * radius
    local bx, by = cx - math.cos(rad) * radius, cy - math.sin(rad) * radius
    place(r.a, ax, ay, cz + lift, r.angle + 90)
    place(r.b, bx, by, cz + lift, r.angle - 90)
    -- the flares come faster as the Pals speed up, at the middle of each body,
    -- and a pulse in the centre between them ties the two together
    if t >= RISE_S and t >= r.nextFlare then
        spawnAt(r.worldCtx, burstFor(r.elemA), ax, ay, cz + lift - STAND + r.bodyA, 0.8)
        spawnAt(r.worldCtx, burstFor(r.elemB), bx, by, cz + lift - STAND + r.bodyB, 0.8)
        r.tetherA = not r.tetherA
        spawnAt(r.worldCtx, burstFor(r.tetherA and r.elemA or r.elemB), cx, cy,
            cz + lift - STAND + (r.bodyA + r.bodyB) / 2, lerp(0.5, 1.1, orbitT))
        r.nextFlare = t + lerp(0.8, 0.2, orbitT)
    end
    r.look = { x = cx, y = cy, z = cz + lift - STAND + (r.bodyA + r.bodyB) / 2 }
end

local function stepCollapse(r, t)
    local ct = math.max(0, math.min(1, (t - RISE_S - ORBIT_S) / COLLAPSE_S))
    local s = lerp(1, 0.03, ease(ct))
    local z = r.cz + LIFT_END
    r.angle = r.angle + SPEED_END * (TICK_MS / 1000)
    local rad = math.rad(r.angle)
    local radius = lerp(RADIUS_END, 0, ct)
    place(r.a, r.cx + math.cos(rad) * radius, r.cy + math.sin(rad) * radius, z)
    place(r.b, r.cx - math.cos(rad) * radius, r.cy - math.sin(rad) * radius, z)
    scaleTo(r.a, s)
    scaleTo(r.b, s)
    if not r.absorbed then
        r.absorbed = true
        spawnAt(r.worldCtx, ABSORB_NS, r.cx, r.cy, z, 1.5)
    end
    r.look = { x = r.cx, y = r.cy, z = z }
end

local function stepBurst(r)
    if r.burst then return end
    r.burst = true
    r.burstAt = os.clock() - r.startedAt
    local z = r.cz + LIFT_END
    for _, a in ipairs({ r.a, r.b }) do
        local okHide, hideErr = pcall(function() a:SetActorHiddenInGame(true) end)
        if not okHide then Log("[WARN] Pal not hidden at the burst: " .. tostring(hideErr)) end
    end
    spawnAt(r.worldCtx, CLOSE_NS, r.cx, r.cy, z, 1.5)
    spawnAt(r.worldCtx, IMPACT_NS, r.cx, r.cy, r.cz, 1.2)
    spawnAt(r.worldCtx, centerpieceFor(r.elemA), r.cx, r.cy, z, 1.2)
    if r.elemB ~= r.elemA then
        spawnAt(r.worldCtx, centerpieceFor(r.elemB), r.cx, r.cy, z, 1.2)
    end
    local okHit, hitErr = pcall(FusionCam.hit, 1.5, { R = 1, G = 1, B = 1, A = 1 })
    if not okHit then Log("[WARN] burst camera hit failed: " .. tostring(hitErr)) end
    -- The commit runs here: the scene waits in the light for the fused Pal.
    local ok, err = pcall(r.onCommit)
    if not ok then
        Log("[ERROR] commit raised: " .. tostring(err))
        finishRun("commit failed")
    end
end

local function stepReveal(r, t)
    if not valid(r.c) then return end
    if not r.revealStart then
        r.revealStart = t
        local okFreeze, freezeErr = pcall(r.freeze, r.c, true)
        if not okFreeze then Log("[WARN] fused Pal not frozen for the reveal: " .. tostring(freezeErr)) end
        spawnAt(r.worldCtx, centerpieceFor(r.elemC or r.elemA), r.cx, r.cy, r.cz + LIFT_END, 1.5)
        -- the evolution finale in the new Pal's colours, where it comes to rest
        local land = r.land or { x = r.cx, y = r.cy, z = r.cz }
        local okFinale, fin = pcall(Finale.begin, r.worldCtx, land.x, land.y, land.z - STAND,
            r.elemsC or { r.elemC or r.elemA }, STAND, bodyHalf(r.c))
        if okFinale then
            r.finale = fin
            -- the Pal reaches full size on the finale's peak and lands right after
            if fin and fin.growS and fin.growS > 0 then r.growS = fin.growS end
        else
            Log("[WARN] reveal finale did not start: " .. tostring(fin))
        end
    end
    if r.landedAt then
        -- lights that outlive the landing (the recall light keeps pulsing) are
        -- put out a moment after it, so the scene ends on the standing Pal
        if r.finale and not r.finaleOut and t >= r.landedAt + TAIL_OUT_S then
            r.finaleOut = true
            local okOut, outErr = pcall(Finale.stopAll, r.finale.f)
            if not okOut then Log("[WARN] finale lights not put out: " .. tostring(outErr)) end
        end
        if t >= r.landedAt + HOLD_S then finishRun("revealed") end
        return
    end
    local growS = r.growS or REVEAL_S
    local revealS = growS + LAND_AFTER_PEAK_S
    local rt = math.max(0, math.min(1, (t - r.revealStart) / revealS))
    local s = lerp(0.03, 1, ease(math.min(1, (t - r.revealStart) / growS)))
    -- out of the light at the centre, down onto the landing point when there is one
    local land = r.land or { x = r.cx, y = r.cy, z = r.cz }
    local e = ease(rt)
    place(r.c, lerp(r.cx, land.x, e), lerp(r.cy, land.y, e), lerp(r.cz + LIFT_END, land.z, e),
        r.landYaw or r.angle)
    scaleTo(r.c, s)
    r.look = { x = lerp(r.cx, land.x, e), y = lerp(r.cy, land.y, e), z = lerp(r.cz + LIFT_END, land.z, e) }
    if rt >= 1 then
        -- the Pal stands: the finale starts nothing new, so the scene ends on it
        r.landedAt = t
        if r.finale then r.finale.f.idx = #r.finale.f.events + 1 end
    end
end

local function tickGameThread()
    local r = run
    if not r then return end
    local t = os.clock() - r.startedAt
    if not (valid(r.a) and valid(r.b)) and not r.burst then
        finishRun("a Pal left the scene")
        return
    end
    if t > r.deadline then
        finishRun("timed out")
        return
    end
    local ok, err = true, nil
    local st = t - CHARGE_S -- time since the Pals lifted off
    trace(string.format("tick t=%.2f burst=%s c=%s", t, tostring(r.burst), tostring(r.c ~= nil)))
    if t < CHARGE_S then
        ok, err = pcall(stepCharge, r, t)
    elseif st < RISE_S + ORBIT_S then
        ok, err = pcall(stepOrbit, r, st)
    elseif st < RISE_S + ORBIT_S + COLLAPSE_S then
        ok, err = pcall(stepCollapse, r, st)
    elseif not r.burst then
        ok, err = pcall(stepBurst, r)
    elseif r.c then
        ok, err = pcall(stepReveal, r, st)
    elseif r.findC then
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
        end
    end
    if run == r and r.finale and not r.finaleOut then
        local okPump, pumpErr = pcall(Finale.pump, r.finale.ctx, r.finale.f, os.clock() - r.finale.startedAt)
        if not okPump then Log("[WARN] finale step failed: " .. tostring(pumpErr)) end
    end
    if run == r then
        trace("camera follow")
        FusionCam.follow(t, r.look)
        trace("camera follow done")
    end
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

--- Starts the scene. opts: worldCtx, a, b (actors), center {x,y,z}, idA, idB,
--- freeze(actor, frozen), onCommit() (runs at the burst; must eventually call
--- FusionFx.reveal(actorC, idC) or FusionFx.abort), onDone(reason).
--- Optional: startRadius (how far from the centre the Pals stand), land {x,y,z}
--- and landYaw (where the fused Pal comes to rest, else the centre).
function FusionFx.play(opts)
    if run then return false, "a fusion scene is already playing" end
    run = {
        worldCtx = opts.worldCtx, a = opts.a, b = opts.b,
        cx = opts.center.x, cy = opts.center.y, cz = opts.center.z,
        elemA = (Elements.of(opts.idA, opts.worldCtx) or {})[1] or "Normal",
        elemB = (Elements.of(opts.idB, opts.worldCtx) or {})[1] or "Normal",
        freeze = opts.freeze, onCommit = opts.onCommit, onDone = opts.onDone,
        startedAt = os.clock(), angle = 0, nextFlare = RISE_S, chargeBeat = 1,
        radiusStart = opts.startRadius or RADIUS_START, land = opts.land, landYaw = opts.landYaw,
        bodyA = bodyHalf(opts.a), bodyB = bodyHalf(opts.b),
        deadline = CHARGE_S + RISE_S + ORBIT_S + COLLAPSE_S + BURST_S + REVEAL_S + HOLD_S + 20,
    }
    -- the orbit starts where A stands, so neither Pal jumps at the first tick
    local okAngle, angleErr = pcall(function()
        local l = opts.a:K2_GetActorLocation()
        run.angle = math.deg(math.atan(l.Y - run.cy, l.X - run.cx))
    end)
    if not okAngle then Log("[WARN] start angle unreadable, the orbit starts at 0: " .. tostring(angleErr)) end
    for _, a in ipairs({ opts.a, opts.b }) do
        local okFreeze, freezeErr = pcall(opts.freeze, a, true)
        if not okFreeze then Log("[WARN] Pal not frozen for the scene: " .. tostring(freezeErr)) end
    end
    run.look = { x = run.cx, y = run.cy, z = run.cz + (run.bodyA + run.bodyB) / 2 }
    local okCam, filming = pcall(FusionCam.start, { worldCtx = opts.worldCtx,
        center = { x = run.cx, y = run.cy, z = run.cz }, frontYaw = opts.landYaw or 0 })
    if not okCam then Log("[WARN] camera did not start: " .. tostring(filming)) end
    if not driving then
        driving = true
        LoopAsync(TICK_MS, FusionFx._tick)
    end
    Log(string.format("scene started (%s + %s)%s", run.elemA, run.elemB, (okCam and filming) and ", filmed" or ""))
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
    run.findTimeout = timeoutS or 6
    run.elemsC = Elements.of(idC, run.worldCtx)
    run.elemC = (run.elemsC or {})[1]
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

--- Total length, for callers that budget a watchdog.
FusionFx.LENGTH_S = RISE_S + ORBIT_S + COLLAPSE_S + BURST_S + REVEAL_S

return FusionFx
