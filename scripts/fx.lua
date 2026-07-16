-- Palvolve FX: the evolution staging - the pal faces the player, spins up
-- while shrinking into nothing, a burst peak bridges the respawn gap, and
-- the new form grows back out of the vortex with the spin winding down,
-- holding face-to-face until the finale effects have faded.
--
-- Hook contract (all hooks run on the game thread, driven by evolution.lua):
--   onDissolve(ctx)             sequence start, old actor still visible
--   onHide(ctx)                 right before the old actor is hidden and torn down
--   onGap(ctx)                  every activation pump nudge while the spot is empty
--   revealDelayMs()             how long to hold the staging before unhiding
--   onPreReveal(ctx, newActor)  new actor exists but is still hidden (teleported)
--   onReveal(ctx, newActor)     right after the new actor became visible
--   cleanup(ctx)                on abort/failure ONLY - never on success;
--                               the staging tears itself down in its own
--                               reveal driver
--   dissolveDurationMs()        how long the dissolve staging runs before the
--                               teardown starts
--   keepsFrozenUntilDone        this staging drives the post-reveal phase
--                               itself: it freezes the new actor (ctx.freeze
--                               in onPreReveal), unfreezes it when its reveal
--                               animation is done, and MUST then end the
--                               sequence via ctx.completeOk (or completeAbort
--                               on any mid-animation failure) - the core
--                               keeps the sequence lock held until then
--
-- ctx: { actor, worldCtx, oldX, oldY, oldZ, oldYaw, oldHalf, newHalf?,
--        freeze(a), unfreeze(a), completeOk(), completeAbort(), fx = {} }
-- worldCtx is the pal's otomo holder (world context for Niagara spawns, also
-- exposes TryGetSpawnedOtomo); newHalf is the new form's capsule half height
-- when it could be measured; run-private state lives inside ctx.fx.

local Config = require("config")

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

-- Vanilla "return to sphere" light burst (always resident, the game uses
-- it for every recall). NS_Return exposes no color parameter (only
-- User.Rate/User.Scale) and M_Glow has no vector parameter either -
-- tinting is impossible, so element looks come from the dedicated vanilla
-- element effects below instead.
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

-- Vanilla element hit effects used as element-colored bursts during the
-- staging; keys match the element names from elements.lua.
local ELEMENT_BURSTS = {
    Normal      = "/Game/Pal/Effect/Common/Hit/Hit01/NS_Hit01Max.NS_Hit01Max",
    Fire        = "/Game/Pal/Effect/Common/Hit/Hit01Fire/NS_Hit01Fire.NS_Hit01Fire",
    Water       = "/Game/Pal/Effect/Common/Hit/Hit01Water/NS_Hit01Water.NS_Hit01Water",
    Leaf        = "/Game/Pal/Effect/Common/Hit/Hit01_grass/NS_Hit01_grass.NS_Hit01_grass",
    Electricity = "/Game/Pal/Effect/Common/Hit/Hit01Thunder/NS_Hit01Thunder_M.NS_Hit01Thunder_M",
    Ice         = "/Game/Pal/Effect/Common/Hit/Hit01Ice/NS_Hit01Ice.NS_Hit01Ice",
    Earth       = "/Game/Pal/Effect/Common/Hit/Hit01_earth/NS_Hit01earth.NS_Hit01earth",
    Dark        = "/Game/Pal/Effect/Common/Hit/Hit01_dark/NS_Hit01dark.NS_Hit01dark",
    Dragon      = "/Game/Pal/Effect/Common/Hit/Hit01_dragon/NS_Hit01_dragon.NS_Hit01_dragon",
}

-- Hit effects stream in with combat and are usually NOT resident during a
-- calm evolution - load them once at sequence start so the bursts never
-- hitch mid-animation. Takes element-name lists.
local function preloadBursts(...)
    for _, group in ipairs({ ... }) do
        for _, elem in ipairs(group or {}) do
            local path = ELEMENT_BURSTS[elem]
            if path then
                pcall(function()
                    local ns = StaticFindObject(path)
                    if not (ns and ns:IsValid()) then LoadAsset(path) end
                end)
            end
        end
    end
end

-- Cycles through a form's elements so dual-element pals burst in BOTH of
-- their elements alternately.
local function elemAt(elems, i)
    if not (elems and #elems > 0) then return nil end
    return elems[((i - 1) % #elems) + 1]
end

local function spawnBurst(worldCtx, x, y, z, elem)
    if not (Config.digimon and Config.digimon.elementColors) then return end
    local path = elem and ELEMENT_BURSTS[elem]
    if not path then return end
    pcall(function()
        local ns = StaticFindObject(path)
        if not (ns and ns:IsValid()) then
            LoadAsset(path)
            ns = StaticFindObject(path)
        end
        local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
        if ns and ns:IsValid() and lib and lib:IsValid() then
            lib:SpawnSystemAtLocation(worldCtx, ns, { X = x, Y = y, Z = z },
                { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }, true, true, 0, false)
        end
    end)
end

-- ---------------------------------------------------------------- staging

local function digimonCfg()
    local c = Config.digimon or {}
    return {
        spinUpMs = math.max(c.spinUpMs or 1200, 1),
        shrinkMs = math.max(c.shrinkMs or 1200, 1),
        growMs = math.max(c.growMs or 1600, 1),
        peakDegPerSec = math.max(c.peakDegPerSec or 1080, 0),
        finaleHoldMs = math.max(c.finaleHoldMs or 1800, 0),
    }
end

local function yawTowardsPlayer(ctx, x, y)
    local yaw = nil
    pcall(function()
        -- the requesting player's pawn (threaded through the sequence ctx);
        -- FindFirstOf stays only as a fallback for legacy callers - on a
        -- host with several players it may face the wrong one
        local player = ctx and ctx.playerPawn
        if not (player and player:IsValid()) then
            player = FindFirstOf("PalPlayerCharacter")
        end
        if player and player:IsValid() then
            local p = player:K2_GetActorLocation()
            yaw = math.deg(math.atan(p.Y - y, p.X - x))
        end
    end)
    return yaw
end

-- Yaw backend, overridable per sequence (activeYawFn). Singleplayer rotates
-- the ACTOR; multiplayer sets it on the MESH instead, because on a client the
-- actor rotation is replicated/frozen by the server and would fight a local
-- spin, while mesh rotation is purely local and smooth.
local activeYawFn = nil
local function setYaw(actor, yaw)
    if activeYawFn then activeYawFn(actor, yaw) return end
    pcall(function()
        actor:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
    end)
end

local M = {
    keepsFrozenUntilDone = true,
    dissolveDurationMs = function()
        local c = digimonCfg()
        return c.spinUpMs + c.shrinkMs
    end,
    revealDelayMs = function() return 100 end,

    -- Pure-visual reveal flash for the CLIENT presentation of a remote
    -- (server-authoritative) evolution: a light + burst at a world location,
    -- with NO actor manipulation. The pal is a replicated proxy on a client,
    -- so freezing/despawning/respawning it locally does not hold and crashes;
    -- only cosmetic Niagara spawns are safe.
    remoteBurst = function(worldCtx, x, y, z)
        spawnLight(worldCtx, x, y, z)
        spawnBurst(worldCtx, x, y, z, "Normal")
    end,

    onDissolve = function(ctx)
        -- adopt this sequence's transform backend (MP overrides the yaw sink)
        activeYawFn = ctx.setYaw
        local c = digimonCfg()
        preloadBursts(ctx.elemsFrom, ctx.elemsTo)
        local faceYaw = yawTowardsPlayer(ctx, ctx.oldX, ctx.oldY) or ctx.oldYaw or 0
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
                -- White overlay only once the shrink starts: earlier the spin
                -- is still so slow that the white-out reads as a texture
                -- glitch instead of part of the effect.
                if not state.glowApplied and t > spinUpS then
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
                    state.burstNo = (state.burstNo or 0) + 1
                    spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ)
                    spawnBurst(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ,
                        elemAt(ctx.elemsFrom, state.burstNo))
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
                spawnBurst(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ + zOff,
                    elemAt(ctx.elemsFrom, i))
            end)
            return stopped
        end)
    end,

    onGap = function(ctx) end, -- the peak loop already carries the hold state

    onPreReveal = function(ctx, newActor)
        activeYawFn = ctx.setYaw
        -- freeze the fresh actor so its own summon/landing logic cannot fight
        -- the grow animation
        if ctx.freeze then pcall(ctx.freeze, newActor) end
        pcall(function() newActor:SetActorScale3D({ X = 0.02, Y = 0.02, Z = 0.02 }) end)
        setYaw(newActor, ctx.fx.faceYaw or 0)
    end,

    onReveal = function(ctx, newActor)
        if ctx.fx.stopPeak then ctx.fx.stopPeak() end
        ctx.fx.revealActor = newActor
        -- explosion finale: simultaneous bursts around the spot in the
        -- TARGET form's element(s) - dual-element targets alternate
        spawnLight(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ)
        spawnBurst(ctx.worldCtx, ctx.oldX, ctx.oldY, ctx.oldZ, elemAt(ctx.elemsTo, 1))
        spawnBurst(ctx.worldCtx, ctx.oldX + 80, ctx.oldY, ctx.oldZ + 40, elemAt(ctx.elemsTo, 2))
        spawnBurst(ctx.worldCtx, ctx.oldX - 80, ctx.oldY, ctx.oldZ + 40, elemAt(ctx.elemsTo, 3))
        spawnBurst(ctx.worldCtx, ctx.oldX, ctx.oldY + 80, ctx.oldZ + 100, elemAt(ctx.elemsTo, 4))
        spawnBurst(ctx.worldCtx, ctx.oldX, ctx.oldY - 80, ctx.oldZ + 100, elemAt(ctx.elemsTo, 5))
        playEffect(newActor, 2)

        -- One continuous driver from reveal to the end of the finale hold:
        -- the pal grows while the spin winds down, keeps turning majestically
        -- through the hold and steers back into the face-player yaw at the
        -- very end.
        local c = digimonCfg()
        local faceYaw = yawTowardsPlayer(ctx, ctx.oldX, ctx.oldY) or (ctx.fx.faceYaw or 0)
        setYaw(newActor, faceYaw)
        pcall(function()
            local ctrl = newActor:GetController()
            if ctrl and ctrl:IsValid() then
                ctrl:SetControlRotation({ Pitch = 0, Yaw = faceYaw, Roll = 0 })
            end
        end)
        -- Actor rotation with control-rotation sync: mesh-level rotation is
        -- overwritten every frame by the pals own mesh rotator (calls
        -- succeed, nothing moves), so the actor is the only usable handle.
        -- Keeping the controllers control rotation in lockstep makes the
        -- facing logic pull WITH the spin, and the steer-in at the end means
        -- there is never a slow phase or a snap it could fight.
        local state = { stopped = false, offset = 0, lastTick = os.clock() }
        ctx.fx.growState = state
        local function applySpin()
            local yawNow = (faceYaw + state.offset) % 360
            setYaw(newActor, yawNow)
            pcall(function()
                local ctrl = newActor:GetController()
                if ctrl and ctrl:IsValid() then
                    ctrl:SetControlRotation({ Pitch = 0, Yaw = yawNow, Roll = 0 })
                end
            end)
        end
        -- back to facing the player - for aborts too
        local function restoreSpin()
            state.offset = 0
            applySpin()
        end
        state.restoreSpin = restoreSpin
        local startedAt = os.clock()
        local growS = c.growMs / 1000
        local holdS = c.finaleHoldMs / 1000
        local totalS = growS + holdS
        local alignS = math.min(0.8, holdS * 0.4) -- steer-in window at the end
        LoopAsync(33, function()
            if state.stopped then return true end
            ExecuteInGameThread(function()
                if state.stopped then return end
                if not (newActor and newActor:IsValid()) then
                    -- actor died mid-drive: normalize whatever the holder has
                    -- now, then end the sequence as an abort (we own the lock)
                    state.stopped = true
                    state.finished = true
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
                local t = now - startedAt
                local speed
                if t < growS then
                    -- reveal: fast spin winding down to a steady rate while
                    -- the pal grows (ease-out)
                    local p = t / growS
                    speed = c.peakDegPerSec * (1 - p) + 360 * p
                    local invp = 1 - p
                    local s = 0.02 + 0.98 * (1.0 - invp * invp)
                    state.scale = s
                    pcall(function() newActor:SetActorScale3D({ X = s, Y = s, Z = s }) end)
                elseif t < totalS - alignS then
                    -- finale hold: keep turning majestically while the
                    -- effects play out (never below the dominance floor)
                    if not state.scaleDone then
                        state.scaleDone = true
                        state.scale = 1
                        pcall(function() newActor:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end)
                    end
                    local h = (t - growS) / math.max(holdS, 0.05)
                    speed = 360 * (1 - h) + 240 * h
                else
                    -- steer back into the face-player yaw along the spin
                    -- direction - lands, never snaps
                    local deltaCW = (360 - (state.offset % 360)) % 360
                    local remaining = math.max(totalS - t, 0.05)
                    speed = math.min(math.max(deltaCW / remaining, 240), c.peakDegPerSec)
                end
                state.offset = state.offset + speed * dt
                -- Keep the height in sync with the growth: the engine
                -- floor-snaps the frozen actor while it is TINY and never
                -- re-snaps as it grows, so at full size the feet would end up
                -- in the ground. Center = ground + capsule half * scale keeps
                -- the feet on the ground the whole time (ground derives from
                -- the old pal's center and capsule).
                local sNow = state.scale or 1
                local oldH = (ctx.oldHalf and ctx.oldHalf > 0) and ctx.oldHalf or 30
                local newH = (ctx.newHalf and ctx.newHalf > 0) and ctx.newHalf or oldH
                -- SP re-anchors the actor location so the feet stay grounded
                -- while growing. On MP the actor location is server-authoritative
                -- (the host already teleported + froze it), so a client write
                -- would fight replication - ctx.placeForScale is a no-op there.
                if ctx.placeForScale then
                    ctx.placeForScale(newActor, sNow, oldH, newH)
                else
                    pcall(function()
                        newActor:K2_SetActorLocation({
                            X = ctx.oldX or 0, Y = ctx.oldY or 0,
                            Z = (ctx.oldZ or 0) - oldH + newH * sNow,
                        }, false, {}, false)
                    end)
                end
                if t >= totalS then
                    state.stopped = true
                    state.finished = true
                    restoreSpin()
                    pcall(function() newActor:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end)
                    if ctx.unfreeze then pcall(ctx.unfreeze, newActor) end
                    if ctx.completeOk then pcall(ctx.completeOk) end
                else
                    applySpin()
                end
            end)
            return state.stopped
        end)
    end,

    cleanup = function(ctx)
        if ctx.fx.dissolveState then ctx.fx.dissolveState.stopped = true end
        if ctx.fx.stopPeak then ctx.fx.stopPeak() end
        local grow = ctx.fx.growState
        -- "not finished" covers both a running grow AND the finale hold (both
        -- run in the same LoopAsync driver); stopped halts that driver, and
        -- finished marks the run as handled so a repeated cleanup skips the
        -- restore branch below.
        local growUnfinished = grow and not grow.finished
        if grow then
            grow.stopped = true
            grow.finished = true
        end
        -- never leave a mini/frozen/mid-spin pal behind on aborts
        local a = ctx.fx.revealActor
        if a and a:IsValid() and growUnfinished then
            pcall(function() a:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end)
            if grow and grow.restoreSpin then pcall(grow.restoreSpin) end
            if ctx.unfreeze then pcall(ctx.unfreeze, a) end
        end
        if ctx.actor and ctx.actor:IsValid() then
            pcall(function() ctx.actor:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end)
            -- the dissolve applies the white overlay to the old actor's mesh;
            -- an abort before the teardown must take it off again
            pcall(function() ctx.actor:GetMainMesh():SetOverlayMaterial(nil) end)
        end
    end,
}

return M
