-- fusionfx.lua: the altar fusion as a scene, about 22 seconds.
--
--   rise      both Pals lift off to opposite sides of the altar
--   orbit     they circle each other, faster and closer, element bursts flaring
--   collapse  they shrink into one point of light
--   burst     both elements at once, then the caller commits the fusion
--   reveal    the fused Pal grows out of the light and lands
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

local FusionFx = {}

local function Log(msg)
    print(string.format("[Palvolve] [fusionfx] %s\n", tostring(msg)))
end

local TICK_MS = 33
local RISE_S, ORBIT_S, COLLAPSE_S, BURST_S, REVEAL_S = 2.5, 12.5, 2.0, 1.0, 4.0
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
    Log("scene ended: " .. reason)
    if r.onDone then
        local ok, err = pcall(r.onDone, reason)
        if not ok then Log("[ERROR] onDone failed: " .. tostring(err)) end
    end
end

local function stepOrbit(r, t)
    local cx, cy, cz = r.cx, r.cy, r.cz
    local orbitT = math.max(0, math.min(1, (t - RISE_S) / ORBIT_S))
    local radius = t < RISE_S and RADIUS_START or lerp(RADIUS_START, RADIUS_END, ease(orbitT))
    local lift = t < RISE_S and lerp(0, LIFT_START, ease(t / RISE_S)) or lerp(LIFT_START, LIFT_END, orbitT)
    local speed = lerp(SPEED_START, SPEED_END, orbitT * orbitT)
    r.angle = r.angle + speed * (TICK_MS / 1000)
    local rad = math.rad(r.angle)
    local ax, ay = cx + math.cos(rad) * radius, cy + math.sin(rad) * radius
    local bx, by = cx - math.cos(rad) * radius, cy - math.sin(rad) * radius
    place(r.a, ax, ay, cz + lift, r.angle + 90)
    place(r.b, bx, by, cz + lift, r.angle - 90)
    -- the flares come faster as the Pals speed up
    if t >= RISE_S and t >= r.nextFlare then
        spawnAt(r.worldCtx, burstFor(r.elemA), ax, ay, cz + lift, 0.8)
        spawnAt(r.worldCtx, burstFor(r.elemB), bx, by, cz + lift, 0.8)
        r.nextFlare = t + lerp(1.2, 0.3, orbitT)
    end
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
    end
    local rt = math.max(0, math.min(1, (t - r.revealStart) / REVEAL_S))
    local s = lerp(0.03, 1, ease(math.min(1, rt * 1.6)))
    local z = r.cz + lerp(LIFT_END, 0, ease(rt))
    place(r.c, r.cx, r.cy, z, r.angle)
    scaleTo(r.c, s)
    if rt >= 1 then finishRun("revealed") end
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
    if t < RISE_S + ORBIT_S then
        ok, err = pcall(stepOrbit, r, t)
    elseif t < RISE_S + ORBIT_S + COLLAPSE_S then
        ok, err = pcall(stepCollapse, r, t)
    elseif not r.burst then
        ok, err = pcall(stepBurst, r)
    elseif r.c then
        ok, err = pcall(stepReveal, r, t)
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
function FusionFx.play(opts)
    if run then return false, "a fusion scene is already playing" end
    run = {
        worldCtx = opts.worldCtx, a = opts.a, b = opts.b,
        cx = opts.center.x, cy = opts.center.y, cz = opts.center.z,
        elemA = (Elements.of(opts.idA, opts.worldCtx) or {})[1] or "Normal",
        elemB = (Elements.of(opts.idB, opts.worldCtx) or {})[1] or "Normal",
        freeze = opts.freeze, onCommit = opts.onCommit, onDone = opts.onDone,
        startedAt = os.clock(), angle = 0, nextFlare = RISE_S,
        deadline = RISE_S + ORBIT_S + COLLAPSE_S + BURST_S + REVEAL_S + 20,
    }
    for _, a in ipairs({ opts.a, opts.b }) do
        local okFreeze, freezeErr = pcall(opts.freeze, a, true)
        if not okFreeze then Log("[WARN] Pal not frozen for the scene: " .. tostring(freezeErr)) end
    end
    if not driving then
        driving = true
        LoopAsync(TICK_MS, FusionFx._tick)
    end
    Log(string.format("scene started (%s + %s)", run.elemA, run.elemB))
    return true
end

--- Hands the scene the fused Pal's actor for the reveal.
function FusionFx.reveal(actorC, idC)
    if not run then return end
    run.c = actorC
    run.elemC = (Elements.of(idC, run.worldCtx) or {})[1]
end

--- Like reveal, for an actor that does not exist yet: findC() is asked until it
--- returns one or timeoutS runs out after the burst.
function FusionFx.awaitReveal(findC, idC, timeoutS)
    if not run then return end
    run.findC = findC
    run.findTimeout = timeoutS or 6
    run.elemC = (Elements.of(idC, run.worldCtx) or {})[1]
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
