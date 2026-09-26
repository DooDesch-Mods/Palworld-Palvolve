-- fusioncam.lua: the camera that films an altar fusion for the player watching it.
--
-- The camera hangs on a small rig the engine moves every frame, so the shot
-- glides instead of stepping with the Lua tick:
--   base   a holder at the point the camera looks at; eased to a new point by
--          FusionCam.focus
--   spin   a turning holder on the base; its yaw is the camera's angle around
--          the point, steered toward each shot's angle
--   cam    the camera on the spin, dist out and up, looking back at the base
-- fusionfx.lua calls FusionCam.shot at every beat of the scene. Only the player
-- on this machine is filmed, and only near the altar: the view is local, so a
-- dedicated server has nobody to film and a player far away keeps their own
-- camera.
--
-- Every call runs on the game thread (fusionfx.lua drives it from its tick).

local Role = require("role")
local GameLoop = require("gameloop")
local Rig = require("fusionrig")

local FusionCam = {}

local function Log(msg)
    print(string.format("[Palvolve] [fusioncam] %s\n", tostring(msg)))
end

local RANGE = 4000          -- viewers farther from the altar keep their own camera
local BLEND_IN_S, BLEND_OUT_S = 1.2, 1.0
local EASE_IN_OUT = 4       -- EViewTargetBlendFunction::VTBlend_EaseInOut
local LEAD_S = 0.15         -- how far ahead on its path the angle is steered
local SHAKE_BIG = "/Game/Pal/Blueprint/RaidBoss/BP_CameraShake_RaidBossModeChange.BP_CameraShake_RaidBossModeChange_C"
local SHAKE_SMALL = "/Game/Pal/Blueprint/Weapon/Explosion/BP_CameraShake_ExplosionBig.BP_CameraShake_ExplosionBig_C"

local rig = nil -- { base, spin, cam, pc, frontYaw, shot, fov }

local live = Rig.live

local function ease(t) return t * t * (3 - 2 * t) end
local function lerp(a, b, t) return a + (b - a) * t end
local function wrap(deg)
    deg = (deg + 180) % 360
    return deg - 180
end

local function camPitch(dist, up)
    return -math.deg(math.atan(up, dist))
end

--- Takes the view of the local player if they are near. opts: worldCtx,
--- center {x,y,z} (the point to look at), frontYaw (deg, the altar's front),
--- shot {yaw, dist, up, fov} (the opening framing, yaw from the front).
--- Returns true when filming.
function FusionCam.start(opts)
    if rig then FusionCam.stop("a new scene started") end
    local pc = Role.getLocalPlayerController()
    if not live(pc) then
        Log("no local player, the scene plays without a camera")
        return false
    end
    local okNear, near = pcall(function()
        local l = pc:K2_GetPawn():K2_GetActorLocation()
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
    local c, s = opts.center, opts.shot
    local front = opts.frontYaw or 0
    local r = { pc = pc, frontYaw = front, fov = s.fov or 90 }
    local okBuild, buildErr = pcall(function()
        r.base = assert(Rig.spawn(opts.worldCtx, c.x, c.y, c.z, 0))
        r.spin = assert(Rig.pivot(opts.worldCtx, c.x, c.y, c.z, front + s.yaw))
        Rig.attach(r.spin, r.base)
        local a = math.rad(front + s.yaw)
        r.cam = assert(Rig.spawn(opts.worldCtx, c.x + math.cos(a) * s.dist, c.y + math.sin(a) * s.dist,
            c.z + s.up, front + s.yaw + 180))
        Rig.attach(r.cam, r.spin)
        r.cam:K2_SetActorRelativeRotation({ Pitch = camPitch(s.dist, s.up), Yaw = 180, Roll = 0 }, false, {}, true)
        r.cam.CameraComponent:SetFieldOfView(r.fov)
    end)
    if not okBuild then
        Log("[WARN] camera rig not built: " .. tostring(buildErr))
        for _, a in ipairs({ r.cam, r.spin, r.base }) do Rig.destroy(a) end
        return false
    end
    rig = r
    r.shot = { t0 = os.clock(), secs = 0.01, yaw0 = s.yaw, yaw1 = s.yaw, fov0 = r.fov, fov1 = r.fov }
    local okView, viewErr = pcall(function() pc:SetViewTargetWithBlend(r.cam, BLEND_IN_S, EASE_IN_OUT, 2.0, false) end)
    if not okView then
        Log("[WARN] view not taken over: " .. tostring(viewErr))
        FusionCam.stop("view refused")
        return false
    end
    Log("filming the fusion")
    return true
end

--- The camera's current angle from the altar front.
local function currentYaw(r)
    return wrap(Rig.yaw(r.spin) - r.frontYaw)
end

--- Moves to a new framing over secs: yaw from the front (deg), dist and up
--- from the point it looks at, fov. Missing fields keep their value.
function FusionCam.shot(s, secs)
    local r = rig
    if not r then return end
    if not (live(r.cam) and live(r.spin)) then
        Log("[WARN] the camera vanished during the scene")
        rig = nil
        return
    end
    local ok, err = pcall(function()
        local yaw0 = currentYaw(r)
        local yaw1 = s.yaw and (yaw0 + wrap(s.yaw - yaw0)) or yaw0
        r.shot = { t0 = os.clock(), secs = math.max(0.05, secs), yaw0 = yaw0, yaw1 = yaw1,
            fov0 = r.fov, fov1 = s.fov or r.fov }
        if s.dist and s.up then
            Rig.moveTo(r.cam, { x = s.dist, y = 0, z = s.up }, 180, camPitch(s.dist, s.up), secs, true, true)
        end
    end)
    if not ok then Log("[WARN] camera shot failed: " .. tostring(err)) end
end

--- Eases the point the camera looks at to x, y, z over secs.
function FusionCam.focus(x, y, z, secs)
    local r = rig
    if not (r and live(r.base)) then return end
    local ok, err = pcall(Rig.moveTo, r.base, { x = x, y = y, z = z }, 0, 0, secs, true, true)
    if not ok then Log("[WARN] camera focus failed: " .. tostring(err)) end
end

--- Steers the angle and the field of view along the current shot; once per
--- scene tick.
function FusionCam.update()
    local r = rig
    if not r then return end
    if not live(r.spin) then
        Log("[WARN] the camera rig vanished during the scene")
        rig = nil
        return
    end
    local ok, err = pcall(function()
        local sh = r.shot
        local now = os.clock()
        local k = math.min(1, (now - sh.t0) / sh.secs)
        local kLead = math.min(1, (now + LEAD_S - sh.t0) / sh.secs)
        local want = lerp(sh.yaw0, sh.yaw1, ease(kLead))
        Rig.spin(r.spin, wrap(want - currentYaw(r)) / LEAD_S)
        local fov = lerp(sh.fov0, sh.fov1, ease(k))
        if math.abs(fov - r.fov) > 0.05 then
            r.fov = fov
            r.cam.CameraComponent:SetFieldOfView(fov)
        end
    end)
    if not ok then Log("[WARN] camera step failed: " .. tostring(err)) end
end

local function loadShake(path)
    local shake = StaticFindObject(path)
    if live(shake) then return shake end
    local okLoad, loadErr = pcall(LoadAsset, (path:gsub("%.[^.]*$", "")))
    if not okLoad then Log("[WARN] shake asset did not load: " .. tostring(loadErr)) end
    shake = StaticFindObject(path)
    if live(shake) then return shake end
    Log("[WARN] shake class missing: " .. path)
    return nil
end

--- A small shake of a player's view, outside the filmed scene.
function FusionCam.shake(pc, scale)
    if not live(pc) then return end
    local okPcm, pcm = pcall(function() return pc.PlayerCameraManager end)
    if not (okPcm and live(pcm)) then
        Log("[WARN] no camera manager for the shake")
        return
    end
    local shake = loadShake(SHAKE_SMALL)
    if not shake then return end
    local ok, err = pcall(function() pcm:StartCameraShake(shake, scale or 1.0, 0, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not ok then Log("[WARN] shake failed: " .. tostring(err)) end
end

--- A hit to the view: a shake (big or small) and, with a colour, a flash that
--- fades out.
function FusionCam.hit(scale, flash, big)
    local r = rig
    if not (r and live(r.pc)) then return end
    local okPcm, pcm = pcall(function() return r.pc.PlayerCameraManager end)
    if not (okPcm and live(pcm)) then
        Log("[WARN] no camera manager for the hit")
        return
    end
    local shake = loadShake(big and SHAKE_BIG or SHAKE_SMALL)
    if shake then
        local ok, err = pcall(function() pcm:StartCameraShake(shake, scale or 1.0, 0, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
        if not ok then Log("[WARN] shake failed: " .. tostring(err)) end
    end
    if flash then
        local ok, err = pcall(function() pcm:StartCameraFade(0.9, 0.0, 0.7, flash, false, false) end)
        if not ok then Log("[WARN] flash failed: " .. tostring(err)) end
    end
end

--- Gives the view back to the player's body and removes the camera.
function FusionCam.stop(reason)
    local r = rig
    if not r then return end
    rig = nil
    if live(r.spin) then Rig.spin(r.spin, 0) end
    if live(r.pc) then
        local ok, err = pcall(function() r.pc:SetViewTargetWithBlend(r.pc:K2_GetPawn(), BLEND_OUT_S, EASE_IN_OUT, 2.0, false) end)
        if not ok then Log("[ERROR] view not given back: " .. tostring(err)) end
    end
    FusionCam._pending = r
    -- removed once the blend back is over, so the view never cuts
    GameLoop.after(math.floor((BLEND_OUT_S + 0.3) * 1000), FusionCam._destroyPending, "camera removal")
    Log("camera handed back (" .. tostring(reason) .. ")")
end

function FusionCam._destroyPending()
    local r = FusionCam._pending
    FusionCam._pending = nil
    if not r then return end
    for _, a in ipairs({ r.cam, r.spin, r.base }) do Rig.destroy(a) end
end

--- Where the camera is, as text for the scene trace.
function FusionCam.where()
    local r = rig
    if not (r and live(r.cam)) then return "off" end
    local ok, s = pcall(function()
        local l = r.cam:K2_GetActorLocation()
        local rot = r.cam:K2_GetActorRotation()
        return string.format("%.0f,%.0f,%.0f yaw %.0f (%.0f from front) pitch %.0f fov %.0f", l.X, l.Y, l.Z,
            rot.Yaw, currentYaw(r), rot.Pitch, r.fov)
    end)
    return ok and s or ("unreadable: " .. tostring(s))
end

function FusionCam.active()
    return rig ~= nil
end

return FusionCam
