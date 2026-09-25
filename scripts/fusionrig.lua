-- fusionrig.lua: motion the engine plays every frame, for the fusion scene.
--
-- A Lua tick runs about 30 times a second and not in step with the frame, so a
-- body or camera placed from Lua moves in visible jumps. Here Lua only sets the
-- course and the engine does the moving:
--   pivot     a bare actor with a RotatingMovementComponent; whatever is
--             attached to it circles with it, turned every frame
--   moveTo    KismetSystemLibrary.MoveComponentTo, an eased move of a
--             component's relative location and rotation over a set time
--
-- Every call runs on the game thread.

local FusionRig = {}

local function Log(msg)
    print(string.format("[Palvolve] [fusionrig] %s\n", tostring(msg)))
end

local IDENTITY = { X = 0, Y = 0, Z = 0, W = 1 }
local ONE = { X = 1, Y = 1, Z = 1 }
local ATTACH_KEEP_WORLD = 1 -- EAttachmentRule::KeepWorld
local DETACH_KEEP_WORLD = 1 -- EDetachmentRule::KeepWorld
local MOVE = 0 -- EMoveComponentAction::Move

local function live(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v == true
end
FusionRig.live = live

local statics, ksl, rotatingClass, holderClass = nil, nil, nil, nil
local function engineObjects()
    if not live(statics) then statics = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    if not live(ksl) then ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    if not live(rotatingClass) then rotatingClass = StaticFindObject("/Script/Engine.RotatingMovementComponent") end
    -- a camera actor is the plainest spawnable actor with a root component
    if not live(holderClass) then holderClass = StaticFindObject("/Script/Engine.CameraActor") end
    return live(statics) and live(ksl) and live(rotatingClass) and live(holderClass)
end

--- Spawns a holder actor at x, y, z facing yaw. Returns the actor or nil, err.
function FusionRig.spawn(worldCtx, x, y, z, yaw)
    if not engineObjects() then return nil, "engine classes missing" end
    local half = math.rad(yaw or 0) / 2
    local xf = { Rotation = { X = 0, Y = 0, Z = math.sin(half), W = math.cos(half) },
        Translation = { X = x, Y = y, Z = z }, Scale3D = ONE }
    local a = statics:BeginDeferredActorSpawnFromClass(worldCtx, holderClass, xf, 1, nil)
    if not live(a) then return nil, "spawn refused" end
    statics:FinishSpawningActor(a, xf)
    return a
end

--- A holder that turns itself around its up axis. Returns pivot, or nil, err.
function FusionRig.pivot(worldCtx, x, y, z, yaw)
    local a, err = FusionRig.spawn(worldCtx, x, y, z, yaw)
    if not a then return nil, err end
    local rm = a:AddComponentByClass(rotatingClass, false, { Rotation = IDENTITY,
        Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = ONE }, false)
    if not live(rm) then
        a:K2_DestroyActor()
        return nil, "no rotating movement"
    end
    rm.RotationRate = { Pitch = 0, Yaw = 0, Roll = 0 }
    FusionRig._spinners = FusionRig._spinners or {}
    FusionRig._spinners[a:GetFullName()] = rm
    return a
end

--- Sets how fast a pivot turns, in degrees per second.
function FusionRig.spin(pivot, degPerSec)
    local rm = FusionRig._spinners and FusionRig._spinners[pivot:GetFullName()]
    if not live(rm) then return false end
    rm.RotationRate = { Pitch = 0, Yaw = degPerSec, Roll = 0 }
    return true
end

--- The pivot's current yaw in degrees.
function FusionRig.yaw(pivot)
    return pivot:K2_GetActorRotation().Yaw
end

--- Hangs actor under parent where it stands now.
function FusionRig.attach(actor, parent)
    actor:K2_AttachToActor(parent, FName("None"), ATTACH_KEEP_WORLD, ATTACH_KEEP_WORLD, ATTACH_KEEP_WORLD, false)
end

function FusionRig.detach(actor)
    if live(actor) then actor:K2_DetachFromActor(DETACH_KEEP_WORLD, DETACH_KEEP_WORLD, DETACH_KEEP_WORLD) end
end

-- One latent action per component: a new move on the same component replaces
-- the running one instead of stacking a second.
local uuids = {}
local nextUuid = 58100

--- Eases actor's root to rel {x,y,z} and yaw/pitch (relative to its parent, or
--- the world when it has none) over secs.
function FusionRig.moveTo(actor, rel, yaw, pitch, secs, easeIn, easeOut)
    if not engineObjects() then return false end
    local root = actor.RootComponent
    local key = actor:GetFullName()
    if not uuids[key] then
        nextUuid = nextUuid + 1
        uuids[key] = nextUuid
    end
    ksl:MoveComponentTo(root, { X = rel.x, Y = rel.y, Z = rel.z }, { Pitch = pitch or 0, Yaw = yaw or 0, Roll = 0 },
        easeOut ~= false, easeIn ~= false, math.max(0.01, secs), false, MOVE,
        { Linkage = 0, UUID = uuids[key], ExecutionFunction = FName("None"), CallbackTarget = actor })
    return true
end

--- Removes a holder actor the rig spawned.
function FusionRig.destroy(actor)
    if not live(actor) then return end
    local key = actor:GetFullName()
    if FusionRig._spinners then FusionRig._spinners[key] = nil end
    uuids[key] = nil
    local ok, err = pcall(function() actor:K2_DestroyActor() end)
    if not ok then Log("[WARN] rig actor not removed: " .. tostring(err)) end
end

return FusionRig
