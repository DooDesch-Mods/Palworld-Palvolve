-- Palvolve remote replay state: the context a client builds to play an evolution
-- the server ran.

local Elements = require("elements")
local FX = require("fx")
local PalPassives = require("palpassives")
local EvoUtil = require("evo_util")

local EvoRemote = {}

-- Build the fx ctx for the CLIENT re-play. Same shape as the singleplayer ctx,
-- but the transform backend is swapped for MP: yaw goes on the MESH (client-
-- local, smooth), position is owned by the server (placeForScale no-op), and
-- freeze is a no-op (the host freezes authoritatively). Actor SCALE stays as
-- the SP path uses it - scale is not in FRepMovement, so it renders locally on
-- this client and is not reset by the server's movement packets.
EvoRemote.remoteCtx = nil
EvoRemote.remoteRevealBusy = false
EvoRemote.remoteRevealStart = 0
local function buildRemoteCtx(actor, holder, playerCtx, pair)
    local ox, oy, oz, oyaw, ohalf = nil, nil, nil, 0, 0
    pcall(function() local l = actor:K2_GetActorLocation(); ox, oy, oz = l.X, l.Y, l.Z end)
    pcall(function() oyaw = actor:K2_GetActorRotation().Yaw end)
    -- scaled COLLISION capsule = the engine's grounding measure
    -- (GetSimpleCollisionHalfHeight is not a UFunction in this build)
    pcall(function()
        local cap = actor.CapsuleComponent
        if cap and cap:IsValid() then ohalf = cap:GetScaledCapsuleHalfHeight() end
    end)
    local ctx = {
        actor = actor, worldCtx = holder,
        playerPawn = playerCtx and playerCtx.pawn or nil,
        oldX = ox, oldY = oy, oldZ = oz, oldYaw = oyaw, oldHalf = ohalf, newHalf = nil,
        fx = {},
        -- yaw uses the SP default (actor rotation): the host freezes the pal,
        -- so it sends no rotation updates and the client-side spin holds.
        placeForScale = function() end, -- position is server-authoritative
        freeze = function() end,        -- freeze is server-authoritative
        unfreeze = function() end,
    }
    ctx.elemsFrom = (pair and Elements.of(pair.from, holder)) or {}
    if pair and pair.stone == "adaptation" then
        local adapted = Elements.adaptationElement(pair, holder)
        ctx.elemsTo = adapted and { adapted } or (Elements.of(pair.to, holder) or {})
    elseif pair then
        ctx.elemsTo = Elements.of(pair.to, holder) or {}
    else
        ctx.elemsTo = {}
    end
    ctx.colorFrom = Elements.colorFor(ctx.elemsFrom[1])
    ctx.colorTo = Elements.colorFor(ctx.elemsTo[1])
    -- The finale picks its base layer from this. Read off the pair rather than
    -- passed in, so the client side gets the same answer from the synced tree
    -- without another field on the wire.
    ctx.isPrestige = (pair and pair.category == "prestige") or false
    -- Only a fight fusion reaches this path (the altar plays its own scene), and
    -- its short timing also decides when the host may reload the Pal.
    ctx.fusionKind = (pair and pair.category == "fusion") and "temporary" or nil
    -- Which prestige programme plays: the Pal's own stage, so the Nth prestige
    -- outdoes the N-1th. Unknown reads as 1 rather than as nothing.
    -- The host's number wins where it is available: the local passive list can
    -- still be the pre-prestige one when this runs on a client.
    ctx.prestigeStage = (pair and tonumber(pair.prestigeStage)) or 1
    if ctx.isPrestige and not (pair and pair.prestigeStage) then
        local probeParam = EvoUtil.paramOf(ctx.actor)
        if probeParam then
            local okStages, stages = pcall(PalPassives.resolve, probeParam)
            if okStages and type(stages) == "table" and stages.prestige
                and (stages.prestige.stage or 0) > 0 then
                ctx.prestigeStage = stages.prestige.stage
            end
        end
    end
    ctx.completeOk = function() EvoRemote.remoteRevealBusy = false; EvoRemote.remoteCtx = nil end
    ctx.completeAbort = function()
        pcall(function() FX.cleanup(ctx) end)
        EvoRemote.remoteRevealBusy = false; EvoRemote.remoteCtx = nil
    end
    return ctx
end

EvoRemote.buildRemoteCtx = buildRemoteCtx

return EvoRemote
