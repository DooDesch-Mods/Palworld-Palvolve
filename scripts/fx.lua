-- Palvolve FX: interchangeable visual stagings ("prototypes") for the gap between
-- the old form dissolving and the new form appearing. Selected via
-- Config.fxPrototype or at runtime with the console command `palvolve fx <name>`.
--
-- Hook contract (all hooks run on the game thread, driven by evolution.lua):
--   onDissolve(ctx)             sequence start, old actor still visible
--   onHide(ctx)                 right before the old actor is hidden and torn down
--   onGap(ctx)                  every activation pump nudge while the spot is empty
--   revealDelayMs()             how long to hold the staging before unhiding
--   onPreReveal(ctx, newActor)  new actor exists but is still hidden (teleported)
--   onReveal(ctx, newActor)     right after the new actor became visible
--   cleanup(ctx)                ALWAYS on sequence end (success or abort)
-- Optional:
--   dissolveDurationMs()        how long the dissolve staging runs before the
--                               teardown starts (default 1200)
--   keepsFrozenUntilDone        the prototype unfreezes the new actor itself
--                               once its reveal animation has finished
--
-- ctx: { actor, oldX, oldY, oldZ, oldYaw, oldHalf, unfreeze(a), fx = {} } -
-- prototypes keep their private state inside ctx.fx.

local Config = require("config")

local M = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- ---------------------------------------------------------------- shared helpers

local function playEffect(actor, effectId)
    pcall(function()
        actor.VisualEffectComponent:AddVisualEffect(effectId, { FloatValues = {} })
    end)
end

local function glowMaterial()
    local mat = StaticFindObject("/Game/Pal/Effect/Material/M_Glow.M_Glow")
    if mat and mat:IsValid() then return mat end
    return nil
end

-- Vanilla "return to sphere" light burst (verified loaded asset)
local function spawnLight(worldCtx, x, y, z)
    pcall(function()
        local ns = StaticFindObject("/Game/Pal/Effect/Common/Return/NS_Return.NS_Return")
        local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
        if ns and ns:IsValid() and lib and lib:IsValid() then
            lib:SpawnSystemAtLocation(worldCtx, ns, { X = x, Y = y, Z = z },
                { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }, true, true, 0, false)
        end
    end)
end

local function destroyActor(a)
    if a and a:IsValid() then
        pcall(function() a:K2_DestroyActor() end)
    end
end

-- Linear scale animation driven from Lua (placeholder actors must not rely on ticks)
local function animateScale(actor, fromScale, toScale, durationMs, onDone)
    local startedAt = os.clock()
    local durationS = durationMs / 1000
    local finished = false
    LoopAsync(33, function()
        if finished then return true end
        ExecuteInGameThread(function()
            if finished then return end
            if not (actor and actor:IsValid()) then
                finished = true
                return
            end
            local t = math.min((os.clock() - startedAt) / durationS, 1.0)
            local s = fromScale + (toScale - fromScale) * t
            pcall(function() actor:SetActorScale3D({ X = s, Y = s, Z = s }) end)
            if t >= 1.0 then
                finished = true
                if onDone then pcall(onDone) end
            end
        end)
        return finished
    end)
end

-- Continuous sine wobble; returns a stop function
local function startWobble(actor, baseScale, amplitude, speed)
    local stopped = false
    LoopAsync(33, function()
        if stopped then return true end
        ExecuteInGameThread(function()
            if stopped then return end
            if not (actor and actor:IsValid()) then
                stopped = true
                return
            end
            local s = baseScale * (1.0 + amplitude * math.sin(os.clock() * speed))
            pcall(function() actor:SetActorScale3D({ X = s, Y = s, Z = s }) end)
        end)
        return stopped
    end)
    return function() stopped = true end
end

local function meshAssetOf(palActor)
    local asset = nil
    pcall(function()
        asset = palActor:GetMainMesh():GetSkinnedAsset()
    end)
    if asset and asset:IsValid() then return asset end
    return nil
end

-- ---------------------------------------------------------------- prototypes

local prototypes = {}

-- "pillar": light bursts only (the original baseline)
prototypes.pillar = {
    revealDelayMs = function() return 200 end,
    onDissolve = function(ctx)
        playEffect(ctx.actor, 1) -- CaptureEmissive: white glow in place
    end,
    onHide = function(ctx) end,
    onGap = function(ctx)
        spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ)
    end,
    onPreReveal = function(ctx, newActor) end,
    onReveal = function(ctx, newActor)
        playEffect(newActor, 2) -- SpawnFromBallEmissive: appear out of white glow
    end,
    cleanup = function(ctx) end,
}

-- "shrink": old form shrinks into nothing, new form grows out of nothing
prototypes.shrink = {
    revealDelayMs = function() return 100 end,
    onDissolve = function(ctx)
        playEffect(ctx.actor, 1)
        animateScale(ctx.actor, 1.0, 0.05, 1050)
    end,
    onHide = function(ctx) end,
    onGap = function(ctx)
        spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ)
    end,
    onPreReveal = function(ctx, newActor)
        pcall(function() newActor:SetActorScale3D({ X = 0.05, Y = 0.05, Z = 0.05 }) end)
    end,
    onReveal = function(ctx, newActor)
        playEffect(newActor, 2)
        ctx.fx.grownActor = newActor
        animateScale(newActor, 0.05, 1.0, 900, function()
            ctx.fx.grownActor = nil
        end)
    end,
    cleanup = function(ctx)
        -- never leave a mini pal behind on aborts
        local a = ctx.fx.grownActor
        if a and a:IsValid() then
            pcall(function() a:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end)
        end
        if ctx.actor and ctx.actor:IsValid() then
            pcall(function() ctx.actor:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end)
        end
    end,
}

-- "statue": a white frozen copy of the old form holds the spot, morphs into the
-- white silhouette of the new form, then the real pal is revealed in color
prototypes.statue = {
    revealDelayMs = function() return 600 end,
    onDissolve = function(ctx)
        playEffect(ctx.actor, 1)
        ctx.fx.oldMeshAsset = meshAssetOf(ctx.actor)
    end,
    onHide = function(ctx)
        if not ctx.fx.oldMeshAsset then
            Log("fx statue: old mesh asset unavailable, falling back to light pillar")
            return
        end
        pcall(function()
            local world = ctx.actor:GetWorld()
            local cls = StaticFindObject("/Script/Engine.SkeletalMeshActor")
            if not (world and world:IsValid() and cls and cls:IsValid()) then return end
            local statue = world:SpawnActor(cls,
                { X = ctx.oldX, Y = ctx.oldY, Z = ctx.oldZ },
                { Pitch = 0, Yaw = ctx.oldYaw or 0, Roll = 0 })
            if not (statue and statue:IsValid()) then return end
            local comp = statue.SkeletalMeshComponent
            comp:SetSkinnedAssetAndUpdate(ctx.fx.oldMeshAsset, true)
            pcall(function() comp.bPauseAnims = true end)
            pcall(function() comp:SetComponentTickEnabled(false) end)
            local glow = glowMaterial()
            if glow then pcall(function() comp:SetOverlayMaterial(glow) end) end
            statue:SetActorEnableCollision(false)
            ctx.fx.statue = statue
        end)
        if ctx.fx.statue then
            Log("fx statue: placeholder spawned")
        else
            Log("fx statue: spawn failed, falling back to light pillar")
        end
    end,
    onGap = function(ctx)
        if not ctx.fx.statue then
            spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ)
        end
    end,
    onPreReveal = function(ctx, newActor)
        -- morph the white silhouette into the NEW form while everything is hidden
        local statue = ctx.fx.statue
        if not (statue and statue:IsValid()) then return end
        local newAsset = meshAssetOf(newActor)
        if newAsset then
            pcall(function()
                statue.SkeletalMeshComponent:SetSkinnedAssetAndUpdate(newAsset, true)
            end)
            spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ)
        end
    end,
    onReveal = function(ctx, newActor)
        destroyActor(ctx.fx.statue)
        ctx.fx.statue = nil
        playEffect(newActor, 2)
    end,
    cleanup = function(ctx)
        destroyActor(ctx.fx.statue)
        ctx.fx.statue = nil
    end,
}

-- "cocoon": a glowing, wobbling sphere encases the spot and bursts on reveal
prototypes.cocoon = {
    revealDelayMs = function() return 250 end,
    onDissolve = function(ctx)
        playEffect(ctx.actor, 1)
    end,
    onHide = function(ctx)
        pcall(function()
            local world = ctx.actor:GetWorld()
            local cls = StaticFindObject("/Script/Engine.StaticMeshActor")
            local mesh = StaticFindObject("/Engine/EngineMeshes/Sphere.Sphere")
            if not (world and world:IsValid() and cls and cls:IsValid()
                    and mesh and mesh:IsValid()) then return end
            local ball = world:SpawnActor(cls,
                { X = ctx.oldX, Y = ctx.oldY, Z = ctx.oldZ }, { Pitch = 0, Yaw = 0, Roll = 0 })
            if not (ball and ball:IsValid()) then return end
            pcall(function() ball:SetMobility(2) end) -- Movable, MUST precede any transform change
            local comp = ball.StaticMeshComponent
            comp:SetStaticMesh(mesh)
            local glow = glowMaterial()
            if glow then
                pcall(function() comp:SetOverlayMaterial(glow) end)
                pcall(function() comp:SetMaterial(0, glow) end)
            end
            ball:SetActorEnableCollision(false)
            -- engine sphere radius is ~160uu; wrap the pal capsule with some margin
            local half = (ctx.oldHalf and ctx.oldHalf > 0) and ctx.oldHalf or 60
            local base = (half * 1.25) / 160.0
            ball:SetActorScale3D({ X = base, Y = base, Z = base })
            ctx.fx.cocoon = ball
            ctx.fx.stopWobble = startWobble(ball, base, 0.12, 5.0)
        end)
        if ctx.fx.cocoon then
            Log("fx cocoon: placeholder spawned")
        else
            Log("fx cocoon: spawn failed, falling back to light pillar")
        end
    end,
    onGap = function(ctx)
        if not ctx.fx.cocoon then
            spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ)
        end
    end,
    onPreReveal = function(ctx, newActor) end,
    onReveal = function(ctx, newActor)
        if ctx.fx.stopWobble then ctx.fx.stopWobble() end
        destroyActor(ctx.fx.cocoon)
        ctx.fx.cocoon = nil
        spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ) -- burst moment
        playEffect(newActor, 2)
    end,
    cleanup = function(ctx)
        if ctx.fx.stopWobble then ctx.fx.stopWobble() end
        destroyActor(ctx.fx.cocoon)
        ctx.fx.cocoon = nil
    end,
}

-- "digimon": the pal faces the player, spins up faster and faster while
-- shrinking into nothing, a burst peak holds the spot, and the new form grows
-- back out of the vortex with the same spin winding down (user-specced staging)

local function digimonCfg()
    local c = Config.digimon or {}
    return {
        spinUpMs = math.max(c.spinUpMs or 1200, 1),
        shrinkMs = math.max(c.shrinkMs or 1200, 1),
        growMs = math.max(c.growMs or 1600, 1),
        peakDegPerSec = math.max(c.peakDegPerSec or 1080, 0),
    }
end

local function yawTowardsPlayer(x, y)
    local yaw = nil
    pcall(function()
        local player = FindFirstOf("PalPlayerCharacter")
        if player and player:IsValid() then
            local p = player:K2_GetActorLocation()
            yaw = math.deg(math.atan(p.Y - y, p.X - x))
        end
    end)
    return yaw
end

local function setYaw(actor, yaw)
    pcall(function()
        actor:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
    end)
end

prototypes.digimon = {
    keepsFrozenUntilDone = true,
    dissolveDurationMs = function()
        local c = digimonCfg()
        return c.spinUpMs + c.shrinkMs
    end,
    revealDelayMs = function() return 100 end,

    onDissolve = function(ctx)
        local c = digimonCfg()
        local faceYaw = yawTowardsPlayer(ctx.oldX, ctx.oldY) or ctx.oldYaw or 0
        ctx.fx.faceYaw = faceYaw
        setYaw(ctx.actor, faceYaw)

        local state = {
            stopped = false,
            yaw = faceYaw,
            lastTick = os.clock(),
            lastBurst = os.clock(),
            glowApplied = false,
        }
        ctx.fx.dissolveState = state
        local startedAt = os.clock()
        local totalS = (c.spinUpMs + c.shrinkMs) / 1000
        local spinUpS = c.spinUpMs / 1000
        local shrinkS = c.shrinkMs / 1000
        LoopAsync(33, function()
            if state.stopped then return true end
            ExecuteInGameThread(function()
                if state.stopped then return end
                local a = ctx.actor
                if not (a and a:IsValid()) then
                    state.stopped = true
                    return
                end
                local now = os.clock()
                local dt = now - state.lastTick
                state.lastTick = now
                local t = now - startedAt
                local progress = math.min(t / totalS, 1.0)
                -- quadratic ramp from a slow start to the peak speed
                local speed = 45 + (c.peakDegPerSec - 45) * (progress * progress)
                state.yaw = (state.yaw + speed * dt) % 360
                setYaw(a, state.yaw)
                -- phase B: shrink while still spinning (ease-in)
                if t > spinUpS then
                    local st = math.min((t - spinUpS) / shrinkS, 1.0)
                    local s = 1.0 - 0.98 * (st * st)
                    pcall(function() a:SetActorScale3D({ X = s, Y = s, Z = s }) end)
                end
                -- white overlay from the middle of the spin-up
                if not state.glowApplied and t > spinUpS * 0.5 then
                    state.glowApplied = true
                    local glow = glowMaterial()
                    if glow then
                        pcall(function() a:GetMainMesh():SetOverlayMaterial(glow) end)
                    end
                end
                -- bursts with rising frequency (0.8s -> 0.25s)
                local interval = 0.8 - 0.55 * progress
                if (now - state.lastBurst) >= interval then
                    state.lastBurst = now
                    spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ)
                end
                if t >= totalS then state.stopped = true end
            end)
            return state.stopped
        end)
    end,

    onHide = function(ctx)
        if ctx.fx.dissolveState then ctx.fx.dissolveState.stopped = true end
        -- peak hold: repeatable burst state until the new model is ready
        local stopped = false
        ctx.fx.stopPeak = function() stopped = true end
        local i = 0
        LoopAsync(300, function()
            if stopped then return true end
            ExecuteInGameThread(function()
                if stopped then return end
                i = i + 1
                local zOff = (i % 3) * 60
                spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ + zOff)
            end)
            return stopped
        end)
    end,

    onGap = function(ctx) end, -- the peak loop already carries the hold state

    onPreReveal = function(ctx, newActor)
        pcall(function() newActor:SetActorScale3D({ X = 0.02, Y = 0.02, Z = 0.02 }) end)
        setYaw(newActor, ctx.fx.faceYaw or 0)
    end,

    onReveal = function(ctx, newActor)
        if ctx.fx.stopPeak then ctx.fx.stopPeak() end
        ctx.fx.revealActor = newActor
        -- explosion finale: simultaneous bursts around the spot
        spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ)
        spawnLight(ctx.worldCtx, ctx.oldX + 80, ctx.oldY, ctx.oldZ + 40)
        spawnLight(ctx.worldCtx, ctx.oldX - 80, ctx.oldY, ctx.oldZ + 40)
        spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY + 80, ctx.oldZ + 100)
        spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY - 80, ctx.oldZ + 100)
        playEffect(newActor, 2)

        -- grow back with the spin winding down, ending face to face
        local c = digimonCfg()
        local state = {
            stopped = false,
            yaw = ctx.fx.faceYaw or 0,
            lastTick = os.clock(),
        }
        ctx.fx.growState = state
        local startedAt = os.clock()
        local growS = c.growMs / 1000
        LoopAsync(33, function()
            if state.stopped then return true end
            ExecuteInGameThread(function()
                if state.stopped then return end
                if not (newActor and newActor:IsValid()) then
                    -- actor died mid-grow: normalize whatever the holder has now,
                    -- then end the sequence as an abort (we own the lock here)
                    state.stopped = true
                    pcall(function()
                        local h = ctx.worldCtx
                        local re = (h and h:IsValid()) and h:TryGetSpawnedOtomo() or nil
                        if re and re:IsValid() then
                            pcall(function() re:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end)
                            if ctx.unfreeze then pcall(ctx.unfreeze, re) end
                        end
                    end)
                    if ctx.completeAbort then pcall(ctx.completeAbort) end
                    return
                end
                local now = os.clock()
                local dt = now - state.lastTick
                state.lastTick = now
                local t = math.min((now - startedAt) / growS, 1.0)
                local inv = 1.0 - t
                local speed = c.peakDegPerSec * inv * inv -- decelerating spin
                state.yaw = (state.yaw + speed * dt) % 360
                local s = 0.02 + 0.98 * (1.0 - inv * inv) -- ease-out growth
                pcall(function() newActor:SetActorScale3D({ X = s, Y = s, Z = s }) end)
                if t >= 1.0 then
                    state.stopped = true
                    state.finished = true
                    pcall(function() newActor:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end)
                    setYaw(newActor, yawTowardsPlayer(ctx.oldX, ctx.oldY) or state.yaw)
                    if ctx.unfreeze then pcall(ctx.unfreeze, newActor) end
                    if ctx.completeOk then pcall(ctx.completeOk) end
                else
                    setYaw(newActor, state.yaw)
                end
            end)
            return state.stopped
        end)
    end,

    cleanup = function(ctx)
        if ctx.fx.dissolveState then ctx.fx.dissolveState.stopped = true end
        if ctx.fx.stopPeak then ctx.fx.stopPeak() end
        local grow = ctx.fx.growState
        local growUnfinished = grow and not grow.stopped
        if grow then grow.stopped = true end
        -- never leave a mini/frozen pal behind on aborts
        local a = ctx.fx.revealActor
        if a and a:IsValid() and growUnfinished then
            pcall(function() a:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end)
            if ctx.unfreeze then pcall(ctx.unfreeze, a) end
        end
        if ctx.actor and ctx.actor:IsValid() then
            pcall(function() ctx.actor:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end)
        end
    end,
}

-- ---------------------------------------------------------------- selection

local current = "statue"

function M.list()
    local names = {}
    for name, _ in pairs(prototypes) do table.insert(names, name) end
    table.sort(names)
    return names
end

function M.set(name)
    if prototypes[name] then
        current = name
        return true
    end
    return false
end

function M.get()
    return current
end

function M.active()
    return prototypes[current]
end

function M.init(defaultName)
    if defaultName and prototypes[defaultName] then
        current = defaultName
    end
end

return M
