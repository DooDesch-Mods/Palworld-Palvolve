-- ride.lua: gets a rider off a Pal before the Pal is taken away.
--
-- An evolution and both halves of a battle fusion despawn the summoned Pal and
-- spawn the new form. With a player on its back the rider stays attached to a
-- mount that no longer exists: the game then ignores every input except the
-- camera, and the respawn never finds its Pal. Everything that removes a Pal
-- asks here first whether someone rides it, and waits until they are off.
--
-- Only the authority calls dismount: on a client the ride state is a
-- replicated copy, and a write there changes nothing the server keeps.

local GameLoop = require("gameloop")

local Ride = {}

local POLL_MS = 100
-- GetOffFromPal normally lands within a frame or two; past this the rider is
-- detached directly, and past the second limit the removal is called off.
local GET_OFF_WAIT_MS = 2000
local DETACH_WAIT_MS = 1000

local function Log(msg)
    print(string.format("[Palvolve] [ride] %s\n", tostring(msg)))
end

local function isValidUnsafe(obj)
    return obj:IsValid()
end

local function isLive(obj)
    if obj == nil then return false end
    local ok, valid = pcall(isValidUnsafe, obj)
    return ok and valid == true
end

local function palUtility()
    local u = StaticFindObject("/Script/Pal.Default__PalUtility")
    if isLive(u) then return u end
    return nil
end

local function nameOf(obj)
    local ok, name = pcall(function() return obj:GetFullName() end)
    return ok and tostring(name) or "?"
end

--- The character riding palActor, or nil when nobody does.
function Ride.riderOf(palActor)
    if not isLive(palActor) then return nil end
    local util = palUtility()
    if not util then
        Log("[WARN] PalUtility not found, the rider of a Pal cannot be looked up")
        return nil
    end
    local ok, rider = pcall(function() return util:FindRiderByRidingActor(palActor) end)
    if not ok then
        Log("[WARN] rider lookup failed: " .. tostring(rider))
        return nil
    end
    if isLive(rider) then return rider end
    return nil
end

local function riderComponent(rider)
    local ok, rc = pcall(function() return rider["Rider Component"] end)
    if ok and isLive(rc) then return rc end
    Log("[WARN] the rider has no Rider Component: " .. (ok and "missing" or tostring(rc)))
    return nil
end

--- Whether palActor is off the ground: flying, or falling.
function Ride.airborne(palActor)
    if not isLive(palActor) then return false end
    local ok, onGround = pcall(function() return palActor.CharacterMovement:IsMovingOnGround() end)
    if not ok then
        Log("[WARN] ground state of the ridden Pal unreadable, counting it as on the ground: "
            .. tostring(onGround))
        return false
    end
    return onGround ~= true
end

--- Whether someone rides palActor while it is off the ground. An evolution or
--- a fusion refuses to start then: getting off would drop the rider.
function Ride.ridingInAir(palActor)
    return Ride.riderOf(palActor) ~= nil and Ride.airborne(palActor)
end

local function stillRiding(palActor, rider, rc)
    if not isLive(palActor) then return false end
    if Ride.riderOf(palActor) then return true end
    if rc and isLive(rc) then
        local ok, riding = pcall(function() return rc:IsRiding() end)
        if not ok then
            Log("[WARN] IsRiding unreadable: " .. tostring(riding))
        elseif riding == true then
            return true
        end
    end
    return false
end

--- Gets whoever rides palActor off it, then calls onDone(true) once nobody
--- rides it, or onDone(false, why) when that did not work. Without a rider
--- onDone(true) runs right away, inside this call. label names the caller in
--- the log.
function Ride.dismount(palActor, onDone, label)
    label = label or "Pal"
    local rider = Ride.riderOf(palActor)
    if not rider then
        onDone(true)
        return
    end
    local rc = riderComponent(rider)
    if rc then
        local okLock, locked = pcall(function() return rc:IsDisableGetOff() end)
        if not okLock then
            Log("[WARN] IsDisableGetOff unreadable: " .. tostring(locked))
        elseif locked == true then
            Log(string.format("[WARN] %s: the game does not let %s get off right now", label, nameOf(rider)))
            onDone(false, "getting off is locked")
            return
        end
    end
    local util = palUtility()
    local okOff, result = false, "PalUtility not found"
    if util then
        okOff, result = pcall(function() return util:GetOffFromPal(rider, true, false) end)
    end
    Log(string.format("%s: getting %s off (GetOffFromPal ok=%s returned %s)",
        label, nameOf(rider), tostring(okOff), tostring(result)))

    local waited, detached = 0, false
    local handle = GameLoop.start(POLL_MS, function()
        waited = waited + POLL_MS
        if not stillRiding(palActor, rider, rc) then
            Log(string.format("%s: the rider is off after %d ms", label, waited))
            onDone(true)
            return true
        end
        if not detached and waited >= GET_OFF_WAIT_MS then
            detached = true
            if rc and isLive(rc) then
                local okDetach, detachErr = pcall(function() rc:DettachRiderNoAnimation() end)
                Log(string.format("[WARN] %s: still riding after %d ms, detaching directly (ok=%s%s)",
                    label, waited, tostring(okDetach), okDetach and "" or (", " .. tostring(detachErr))))
            else
                Log(string.format("[WARN] %s: still riding after %d ms and no Rider Component to detach",
                    label, waited))
            end
            return false
        end
        if waited >= GET_OFF_WAIT_MS + DETACH_WAIT_MS then
            Log(string.format("[ERROR] %s: the rider could not be taken off; the Pal is left as it is", label))
            onDone(false, "still riding")
            return true
        end
        return false
    end, "dismount")
    -- Without the poll nobody would ever call onDone, and the caller's lock
    -- would stay held.
    if handle == nil then
        Log(string.format("[ERROR] %s: the dismount poll did not start", label))
        onDone(false, "dismount poll did not start")
    end
end

return Ride
