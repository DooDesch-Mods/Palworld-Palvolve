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

-- Binaries that only ever ship with the dedicated server build (Steam app
-- 2394010); the game client ships Palworld-Win64-Shipping.exe instead.
local SERVER_BINARIES = {
    "PalServer-Win64-Shipping-Cmd.exe",
    "PalServer-Win64-Shipping.exe",
}

-- The Win64 directory a script path sits under:
-- <root>\Pal\Binaries\Win64\ue4ss\Mods\Palvolve\Scripts\role.lua
function Role.win64DirOf(src)
    return src:match("^@?(.*)[/\\][Uu][Ee]4[Ss][Ss][/\\]")
        or src:match("^@?(.*[/\\][Bb]inaries[/\\][^/\\]+)[/\\]")
end

-- Process-static dedicated-server detection. The dedicated server never has
-- a game viewport, but at mod-load time the viewport does not exist on
-- clients either - the shipped binary layout is the only signal available
-- this early.
--
-- The directory name alone is not that signal. A Steam install puts the
-- server under "PalServer\Pal\...", but a host may name the directory
-- anything: GPortal uses "palworld", which by name is indistinguishable
-- from a client install. What actually separates the two builds are the
-- binaries sitting next to us, and looking for the server ones cannot
-- produce a false positive on a client, which never ships them. Being
-- wrong the other way is expensive: the UI modules load headless and their
-- retry pollers churn callback refs until UE4SS' callback GC frees one that
-- is still scheduled.
--
-- Split from isDedicated so it can be exercised against real install layouts.
function Role.detectDedicated(src)
    src = src or ""
    if src:find("PalServer", 1, true) or src:find("palserver", 1, true) then
        return true
    end
    local dir = Role.win64DirOf(src)
    if not dir then return false end
    for _, exe in ipairs(SERVER_BINARIES) do
        local ok, found = pcall(function()
            local f = io.open(dir .. "\\" .. exe, "rb")
            if f then f:close() return true end
            return false
        end)
        if ok and found then return true end
    end
    return false
end

function Role.isDedicated()
    if isDedicatedCached ~= nil then return isDedicatedCached end
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    isDedicatedCached = Role.detectDedicated(src)
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
    -- the reflected getter is K2_GetPawn; plain GetPawn does not exist as a
    -- UFunction, so read the replicated Pawn property first
    pcall(function() ctx.pawn = pc.Pawn end)
    if not (ctx.pawn and ctx.pawn:IsValid()) then
        pcall(function() ctx.pawn = pc:K2_GetPawn() end)
    end
    pcall(function() ctx.isLocal = pc:IsLocalPlayerController() end)
    if ctx.isLocal == nil then ctx.isLocal = false end
    return ctx
end

function Role.localPlayerCtx()
    return Role.playerCtxFor(Role.getLocalPlayerController())
end

-- Visible in-game chat line to ONE specific player. Preferred path is the
-- game's own targeted system chat (PalUtility:SendSystemToPlayerChat with the
-- receiver's PlayerUId): it renders as a private [SYSTEM] line for that player
-- alone. The old EnterChat_Receive path attributed the text to the player
-- ("[Name]: ...") and fed it into the global chat everyone sees - kept only
-- as the fallback when no PlayerUId is available. Message must be a plain
-- string in both paths; FText userdata kills the process natively.
function Role.chat(playerCtx, msg)
    if not (playerCtx and playerCtx.pc and playerCtx.pc:IsValid()) then return false end
    -- The targeted system chat is proven only for REMOTE receivers (authority
    -- sending to a connected client) - exactly the case where the legacy RPC
    -- leaked into the global chat. For the LOCAL player it renders nothing in
    -- standalone (the call succeeds but no line appears), so the local player
    -- keeps the legacy receive RPC: it runs on this machine alone, which makes
    -- it private by construction in single player and on a pure client.
    local sent = false
    if playerCtx.playerUId and Role.hasWorldAuthority() and not playerCtx.isLocal then
        pcall(function()
            local util = StaticFindObject("/Script/Pal.Default__PalUtility")
            local world = FindFirstOf("World")
            if util and util:IsValid() and world and world:IsValid() then
                local g = playerCtx.playerUId
                util:SendSystemToPlayerChat(world, tostring(msg),
                    { { A = g.A, B = g.B, C = g.C, D = g.D } })
                sent = true
            end
        end)
    end
    if sent then return true end
    local ok = pcall(function()
        playerCtx.pc:EnterChat_Receive(tostring(msg), 1)
    end)
    return ok
end

-- Reply to a CHAT COMMAND. The EnterChat hook fires on the sender's client
-- (RPC stub) AND on the world authority, so command handlers run twice on
-- dedicated servers. The authority owns the visible reply (private system
-- chat); the client-side run only logs - its EnterChat_Receive fallback
-- would render the reply attributed to the player, duplicating the system
-- line. In standalone/host the local run IS the authority and chats normally.
function Role.ack(playerCtx, msg)
    if Role.hasWorldAuthority() then
        return Role.chat(playerCtx, msg)
    end
    Log("(ack suppressed on client, authority replies) " .. tostring(msg))
    return true
end

-- Player-facing status text. Local player: plain log. Remote requester:
-- forwarded through the per-player channels - a machine-readable screen
-- log line (hooked by the client mod, HUD-invisible) and a human-readable
-- private chat line.
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
    Role.chat(playerCtx, "[Palvolve] " .. msg)
end

return Role
