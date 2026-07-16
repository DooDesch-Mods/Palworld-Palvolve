-- role.lua: runtime role detection and player context for multiplayer.
-- The mod runs in three process roles: standalone/listen host (world
-- authority + local player), dedicated server (world authority, no local
-- player) and connected client (local player, no authority). Everything
-- that acts on "the player" must go through a playerCtx instead of
-- FindFirstOf, because on a host with connected clients FindFirstOf
-- returns an arbitrary controller.
local Role = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local isDedicatedCached = nil

-- Process-static dedicated-server detection. The dedicated server never has
-- a game viewport, but at mod-load time the viewport does not exist on
-- clients either - the ship binary layout is the only signal available this
-- early. The dedicated build lives under "PalServer\Pal\..." (Steam app
-- 2394010), the game client under "Palworld\Pal\..." or a copy of it, so
-- the mod's own script path is a process-static discriminator.
function Role.isDedicated()
    if isDedicatedCached ~= nil then return isDedicatedCached end
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    isDedicatedCached = (src:find("PalServer", 1, true) ~= nil)
        or (src:find("palserver", 1, true) ~= nil)
    return isDedicatedCached
end

-- The controller of the player sitting at THIS machine (nil on dedicated).
-- FindAllOf + IsLocalPlayerController instead of FindFirstOf: on a listen
-- host with guests every connected player has a controller instance in
-- this process.
function Role.getLocalPlayerController()
    if Role.isDedicated() then return nil end
    local found = nil
    pcall(function()
        local all = FindAllOf("PalPlayerController") or {}
        for _, pc in ipairs(all) do
            local ok, isLocal = pcall(function() return pc:IsLocalPlayerController() end)
            if ok and isLocal and pc:IsValid() then
                found = pc
                break
            end
        end
    end)
    return found
end

-- True when this process owns the world state (standalone, listen host,
-- dedicated server). False only on a client connected to a remote host.
function Role.hasWorldAuthority()
    if Role.isDedicated() then return true end
    local authority = false
    pcall(function()
        local pc = Role.getLocalPlayerController()
        if pc and pc:IsValid() then authority = pc:HasAuthority() end
    end)
    return authority
end

-- Bundle everything player-scoped code needs. pc may be any controller
-- (local player or a remote client's controller on the authority).
function Role.playerCtxFor(pc)
    if not (pc and pc:IsValid()) then return nil end
    local ctx = { pc = pc }
    pcall(function() ctx.playerState = pc.PlayerState end)
    pcall(function()
        local g = ctx.playerState.PlayerUId
        ctx.playerUId = { A = g.A, B = g.B, C = g.C, D = g.D }
    end)
    pcall(function() ctx.pawn = pc:GetPawn() end)
    pcall(function() ctx.isLocal = pc:IsLocalPlayerController() end)
    if ctx.isLocal == nil then ctx.isLocal = false end
    return ctx
end

function Role.localPlayerCtx()
    return Role.playerCtxFor(Role.getLocalPlayerController())
end

-- Visible in-game chat line to a specific player's own client (works for
-- the local player and for a remote requester on the authority). Uses
-- EnterChat_Receive, whose Message parameter is an FString - passing FText
-- userdata there kills the process natively (see UE4SS-LESSONS). Category 1
-- (Global) is what the retail chat UI renders.
function Role.chat(playerCtx, msg)
    if not (playerCtx and playerCtx.pc and playerCtx.pc:IsValid()) then return false end
    local ok = pcall(function()
        playerCtx.pc:EnterChat_Receive(tostring(msg), 1)
    end)
    return ok
end

-- Player-facing status text. Local player: plain log (same surface as
-- today, the dev loop greps for it). Remote requester: forwarded through
-- the per-player channels proven in the transport spike - a machine-
-- readable screen log line (hooked by the client mod, HUD-invisible) and
-- a human-readable private chat line.
function Role.notify(playerCtx, msg)
    Log(msg)
    if not playerCtx or playerCtx.isLocal then return end
    pcall(function()
        playerCtx.pc:SendScreenLogToClient(
            "PVLV1|log|" .. msg,
            { R = 0.2, G = 1.0, B = 0.4, A = 1.0 },
            6.0,
            FName("PalvolveNotify"))
    end)
    pcall(function()
        playerCtx.pc:EnterChat_Receive("[Palvolve] " .. msg, 1)
    end)
end

return Role
