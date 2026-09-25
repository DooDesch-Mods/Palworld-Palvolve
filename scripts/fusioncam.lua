-- fusioncam.lua: the camera that films an altar fusion for the player watching it.
--
-- A camera actor of our own takes over the view with a soft blend, circles the
-- altar along a few keyframes while the scene plays, pushes in for the collapse
-- and pulls back for the reveal, then hands the view back to the player's body.
-- Only the player on this machine is filmed, and only near the altar: the view
-- is local, so a dedicated server has nobody to film and a player far away keeps
-- their own camera.
--
-- Every call runs on the game thread (fusionfx.lua drives it from its tick).

local Role = require("role")

local FusionCam = {}

local function Log(msg)
    print(string.format("[Palvolve] [fusioncam] %s\n", tostring(msg)))
end

local RANGE = 4000          -- viewers farther from the altar keep their own camera
local BLEND_IN_S, BLEND_OUT_S = 1.2, 1.0
local EASE_IN_OUT = 4       -- EViewTargetBlendFunction::VTBlend_EaseInOut
local SHAKE_CLASS = "/Game/Pal/Blueprint/Weapon/Explosion/BP_CameraShake_ExplosionBig.BP_CameraShake_ExplosionBig_C"

-- Path around the altar: scene time (s), angle from the altar's front (deg),
-- distance and height above the scene centre. Between keys the camera eases.
local KEYS = {
    { t = 0.0, angle = 28, dist = 1500, up = 220 },
    { t = 3.0, angle = 22, dist = 1300, up = 260 },
    { t = 9.0, angle = -20, dist = 1150, up = 330 },
    { t = 16.0, angle = -55, dist = 950, up = 300 },
    { t = 18.5, angle = -48, dist = 700, up = 240 },
    { t = 20.0, angle = -40, dist = 780, up = 260 },
    { t = 24.0, angle = 8, dist = 1150, up = 300 },
    { t = 30.0, angle = 12, dist = 1200, up = 300 },
}

local cam = nil
local pc = nil
local center = nil
local frontYaw = 0
local lookZ = 0

local function live(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v == true
end

local function ease(t) return t * t * (3 - 2 * t) end
local function lerp(a, b, t) return a + (b - a) * t end

local function pathAt(t)
    if t <= KEYS[1].t then return KEYS[1] end
    for i = 2, #KEYS do
        local a, b = KEYS[i - 1], KEYS[i]
        if t <= b.t then
            local k = ease((t - a.t) / (b.t - a.t))
            return { angle = lerp(a.angle, b.angle, k), dist = lerp(a.dist, b.dist, k), up = lerp(a.up, b.up, k) }
        end
    end
    return KEYS[#KEYS]
end

local function lookRotation(from, to)
    local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
    local flat = math.sqrt(dx * dx + dy * dy)
    return { Pitch = math.deg(math.atan(dz, flat)), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
end

local function place(t, target)
    local p = pathAt(t)
    local a = math.rad(frontYaw + p.angle)
    local pos = { x = center.x + math.cos(a) * p.dist, y = center.y + math.sin(a) * p.dist, z = center.z + p.up }
    local rot = lookRotation(pos, target or { x = center.x, y = center.y, z = lookZ })
    cam:K2_SetActorLocationAndRotation({ X = pos.x, Y = pos.y, Z = pos.z }, rot, false, {}, true)
end

--- Takes the view of the local player if they are near. opts: worldCtx,
--- center {x,y,z}, frontYaw (deg, the altar's front). Returns true when filming.
function FusionCam.start(opts)
    if cam then FusionCam.stop("a new scene started") end
    local localPc = Role.getLocalPlayerController()
    if not live(localPc) then
        Log("no local player, the scene plays without a camera")
        return false
    end
    local okNear, near = pcall(function()
        local l = localPc:K2_GetPawn():K2_GetActorLocation()
        local dx, dy, dz = l.X - opts.center.x, l.Y - opts.center.y, l.Z - opts.center.z
        return dx * dx + dy * dy + dz * dz <= RANGE * RANGE
    end)
    if not okNear then
        Log("[WARN] player position unreadable, no camera: " .. tostring(near))
        return false
    end
    if not near then
        Log("the player is far from the altar, their camera stays")
        return false
    end
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local camClass = StaticFindObject("/Script/Engine.CameraActor")
    if not (live(statics) and live(camClass)) then
        Log("[WARN] camera class or spawner missing, no camera")
        return false
    end
    center, frontYaw = opts.center, opts.frontYaw or 0
    lookZ = center.z
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = center.x, Y = center.y, Z = center.z + 300 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local okSpawn, spawned = pcall(function()
        local a = statics:BeginDeferredActorSpawnFromClass(opts.worldCtx, camClass, xf, 1, nil)
        statics:FinishSpawningActor(a, xf)
        return a
    end)
    if not (okSpawn and live(spawned)) then
        Log("[WARN] camera not spawned: " .. tostring(spawned))
        return false
    end
    cam, pc = spawned, localPc
    local okPlace, placeErr = pcall(place, 0, nil)
    if not okPlace then Log("[WARN] camera not placed: " .. tostring(placeErr)) end
    local okView, viewErr = pcall(function() pc:SetViewTargetWithBlend(cam, BLEND_IN_S, EASE_IN_OUT, 2.0, false) end)
    if not okView then
        Log("[WARN] view not taken over: " .. tostring(viewErr))
        FusionCam.stop("view refused")
        return false
    end
    Log("filming the fusion")
    return true
end

--- Moves the camera along its path. t: scene time in seconds; target: the
--- point to look at, or nil for the scene centre.
function FusionCam.follow(t, target)
    if not cam then return end
    if not live(cam) then
        cam = nil
        Log("[WARN] the camera vanished during the scene")
        return
    end
    local ok, err = pcall(place, t, target)
    if not ok then Log("[WARN] camera step failed: " .. tostring(err)) end
end

--- A hit to the view: a shake and, with a colour, a flash that fades out.
function FusionCam.hit(scale, flash)
    if not live(pc) then return end
    local okPcm, pcm = pcall(function() return pc.PlayerCameraManager end)
    if not (okPcm and live(pcm)) then
        Log("[WARN] no camera manager for the hit")
        return
    end
    local shake = StaticFindObject(SHAKE_CLASS)
    if not live(shake) then
        local okLoad, loadErr = pcall(LoadAsset, SHAKE_CLASS:gsub("%.[^.]*$", ""))
        if not okLoad then Log("[WARN] shake asset did not load: " .. tostring(loadErr)) end
        shake = StaticFindObject(SHAKE_CLASS)
    end
    if live(shake) then
        local ok, err = pcall(function() pcm:StartCameraShake(shake, scale or 1.0, 0, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
        if not ok then Log("[WARN] shake failed: " .. tostring(err)) end
    else
        Log("[WARN] shake class missing: " .. SHAKE_CLASS)
    end
    if flash then
        local ok, err = pcall(function() pcm:StartCameraFade(0.85, 0.0, 0.6, flash, false, false) end)
        if not ok then Log("[WARN] flash failed: " .. tostring(err)) end
    end
end

--- Gives the view back to the player's body and removes the camera.
function FusionCam.stop(reason)
    if not cam then return end
    local c, p = cam, pc
    cam, pc = nil, nil
    if live(p) then
        local ok, err = pcall(function() p:SetViewTargetWithBlend(p:K2_GetPawn(), BLEND_OUT_S, EASE_IN_OUT, 2.0, false) end)
        if not ok then Log("[ERROR] view not given back: " .. tostring(err)) end
    end
    FusionCam._pending = c
    -- removed once the blend back is over, so the view never cuts
    LoopAsync(math.floor((BLEND_OUT_S + 0.3) * 1000), function()
        ExecuteInGameThread(FusionCam._destroyPending)
        return true
    end)
    Log("camera handed back (" .. tostring(reason) .. ")")
end

function FusionCam._destroyPending()
    local c = FusionCam._pending
    FusionCam._pending = nil
    if live(c) then
        local ok, err = pcall(function() c:K2_DestroyActor() end)
        if not ok then Log("[WARN] camera not removed: " .. tostring(err)) end
    end
end

function FusionCam.active()
    return cam ~= nil
end

return FusionCam
