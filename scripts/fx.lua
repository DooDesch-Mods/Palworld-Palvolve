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
--
-- ctx: { actor, oldX, oldY, oldZ, oldYaw, oldHalf, fx = {} } - prototypes keep
-- their private state inside ctx.fx.

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
