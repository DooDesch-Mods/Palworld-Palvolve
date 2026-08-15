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

-- Same line, but also in the server console. UE4SS logs to a file an admin has
-- to know about; the console is what they are already looking at. Only facts a
-- support case starts with go here, never per-evolution chatter.
local function Announce(msg)
    Log(msg)
    if type(PalvolveNative_Console) == "function" then
        pcall(PalvolveNative_Console, "[Palvolve] " .. msg)
    end
end

-- Set once the engine has answered. The path guess below never writes here.
local isDedicatedCached = nil
-- The last provisional answer, so the log only reports a correction once.
local provisionalReported = nil

-- Binaries that only ever ship with the dedicated server build (Steam app
-- 2394010); the game client ships Palworld-Win64-Shipping.exe instead.
local SERVER_BINARIES = {
    "PalServer-Win64-Shipping-Cmd.exe",
    "PalServer-Win64-Shipping.exe",
}

-- Files that exist in a dedicated server's ROOT and in no client install.
-- Checked against both installs: a client root holds Palworld.exe and no
-- DefaultPalWorldSettings.ini at all.
local SERVER_ROOT_MARKERS = {
    "DefaultPalWorldSettings.ini",
    "PalServer.exe",
    "PalServer.sh",
}

-- How far up from the scripts folder the server root may sit. A Steam layout
-- needs five; one host ships UE4SS under <root>/Mods/NativeMods/UE4SS and needs
-- six, which is what the margin is for.
local MAX_WALK_UP = 8

local function fileExists(path)
    local ok, found = pcall(function()
        local f = io.open(path, "rb")
        if f then f:close() return true end
        return false
    end)
    return ok and found
end

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
    -- The native companion reads the running executable's own name, which says
    -- which of the two builds this is without a world and without a guess. Only
    -- when it is missing do the path heuristics below get a turn.
    if type(PalvolveNative_IsDedicatedServer) == "function" then
        local ok, native = pcall(PalvolveNative_IsDedicatedServer)
        if ok and type(native) == "boolean" then return native end
    end

    src = src or ""
    if src:find("PalServer", 1, true) or src:find("palserver", 1, true) then
        return true
    end
    local dir = Role.win64DirOf(src)
    if dir then
        for _, exe in ipairs(SERVER_BINARIES) do
            if fileExists(dir .. "\\" .. exe) then return true end
        end
    end

    -- Walk up looking for the server ROOT, instead of assuming the scripts sit
    -- under Pal\Binaries\Win64. A host is free to put UE4SS anywhere, and one
    -- puts it under <root>\Mods\NativeMods\UE4SS, where neither the path nor the
    -- neighbouring files say "server". A dedicated server was then run down the
    -- single player path: the UI modules that must never start headless loaded,
    -- and no evolve phase signal ever reached a client.
    local at = src:gsub("^@", "")
    local sep = at:find("\\", 1, true) and "\\" or "/"
    for _ = 1, MAX_WALK_UP do
        local up = at:match("^(.*)[/\\][^/\\]*$")
        if not up or up == "" then break end
        at = up
        for _, marker in ipairs(SERVER_ROOT_MARKERS) do
            if fileExists(at .. sep .. marker) then return true end
        end
    end
    return false
end

-- The engine's own answer, which is the definition rather than a guess:
-- UKismetSystemLibrary::IsDedicatedServer is World->GetNetMode() == NM_DedicatedServer.
-- Returns nil while no world exists yet, which is the only reason the path guess
-- below still has a job.
--
-- Needed because the path guess is only as good as the install layout, and a host
-- is free to pick any. One of them ships UE4SS under <root>/Mods/NativeMods/UE4SS
-- instead of <root>/Pal/Binaries/Win64/ue4ss: no "PalServer" anywhere in the path
-- and no server binary next to the scripts, so the guess said "client" and the mod
-- ran a dedicated server down the single player path - no phase signals to anyone,
-- so no evolve animation and no refreshed work suitability on any client.
function Role.netIsDedicated()
    local answer = nil
    pcall(function()
        local lib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not (lib and lib:IsValid()) then return end

        -- Any live object that belongs to the world will do as a context. The game
        -- mode exists only on the authority, so it is tried first: finding it is
        -- already half the answer, and it exists before any character does.
        local ctx = nil
        for _, class in ipairs({ "PalGameMode", "PalGameStateInGame", "PalPlayerCharacter" }) do
            local found = FindFirstOf(class)
            if found and found:IsValid() then ctx = found break end
        end
        if not ctx then return end

        answer = lib:IsDedicatedServer(ctx) and true or false
    end)
    return answer
end

function Role.isDedicated()
    if isDedicatedCached ~= nil then return isDedicatedCached end

    local fromEngine = Role.netIsDedicated()
    if fromEngine ~= nil then
        isDedicatedCached = fromEngine
        -- Logged every time, not only on a mismatch. This one line is what a
        -- support case needs first, and it has to be there whether or not the
        -- guess happened to agree.
        local role = fromEngine and "dedicated server" or "client or listen host"
        if provisionalReported ~= nil and provisionalReported ~= fromEngine then
            Announce(string.format("role: %s (asked the engine; the install layout said %s)",
                role, provisionalReported and "dedicated server" or "client or listen host"))
        else
            Announce(string.format("role: %s (asked the engine)", role))
        end
        return isDedicatedCached
    end

    -- No world yet. Answer from the layout, but do NOT remember it: this same
    -- call runs again later, and by then the engine can be asked.
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    local guess = Role.detectDedicated(src)
    provisionalReported = guess
    return guess
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
-- How talkative the mod is in the chat. Set by config.lua after the user file
-- is read; role.lua cannot ask for it, because config requires THIS module and
-- a require back would close the circle.
--   "all"     everything
--   "replies" only what answers something the player did
--   "off"     nothing but command replies
Role.chatMode = "all"

--- kind: "info" for anything the mod says on its own, "reply" for a refusal or
--- another answer to a player action, "command" for the reply to a chat command.
--- A command reply is never silenced: silence there reads as a broken mod.
local function chatAllowed(kind)
    local mode = Role.chatMode or "all"
    -- "always" is for the one line a player must never miss: whether their
    -- client and the server agree on a version. A mod that goes quiet about
    -- that leaves every later symptom unexplained.
    if kind == "always" or kind == "command" then return true end
    if mode == "off" then return false end
    if mode == "replies" then return kind == "reply" end
    return true
end

-- Every line this mod puts in a chat says so. A player on a server sees lines
-- from several mods at once, and in single player ours arrive under the
-- player's OWN name because a client cannot set a sender - without the tag
-- there is nothing at all to tell them apart by. It was only on the messages
-- that happened to go through Role.notify, which is why the same screen showed
-- some tagged and some not.
local TAG = "[Palvolve] "

function Role.chat(playerCtx, msg, kind)
    if not chatAllowed(kind or "info") then return true end
    msg = tostring(msg)
    if msg:sub(1, #TAG) ~= TAG then msg = TAG .. msg end
    return Role.chatRaw(playerCtx, msg)
end

function Role.chatRaw(playerCtx, msg)
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

    -- Local render, without the [SYSTEM] sender the host can set.
    --
    -- The chat widget takes an FPalChatMessage whose Sender is a plain string,
    -- and the game's own [SYSTEM] lines are exactly that string, so calling
    -- PalUIChat:OnReceivedChat with a Sender of "SYSTEM" looked like the way to
    -- give a client-side line the same look. It kills the client: handing that
    -- struct to the widget from Lua took the game down with no Lua error and
    -- nothing in the log, the same class of death as passing FText where an
    -- FString belongs. Measured 2026-08-12, do not try it again without a
    -- native call path.
    --
    -- A client can therefore not produce a [SYSTEM] line at all. Where the look
    -- matters, the message has to come FROM the host, which owns the only
    -- function that sets a sender.
    -- Who this line reaches: on a client the engine only sends an RPC call to
    -- the server when the function is marked Server, and this is the receive
    -- half of the pair, so the line is drawn on this machine. On a listen host
    -- the machine IS the authority, where a receive-side call is the one that
    -- could go out to every connected player, and the object dump does not say
    -- whether it does. Measured on a dedicated server: the line arrives with an
    -- EMPTY sender rather than the player's name, which is what a purely local
    -- render looks like. The host case is still unmeasured, and it keeps this
    -- path anyway: a host that silently loses every message the mod has for it
    -- is a certain loss, against guests possibly seeing a line about a Pal.
    local ok = pcall(function()
        playerCtx.pc:EnterChat_Receive(tostring(msg), 1)
    end)
    return ok
end

-- Length limit for both paths above: the chat DROPS a line that runs too long
-- instead of truncating it, so a message past roughly a hundred characters
-- never appears on screen even though the log shows it. Player-facing messages
-- are therefore kept short at the source rather than split here - splitting
-- means cutting a Lua string by BYTES, which lands inside a multi-byte
-- character in German, Russian or Japanese and hands the chat malformed text.

-- Reply to a CHAT COMMAND. The EnterChat hook fires on the sender's client
-- (RPC stub) AND on the world authority, so command handlers run twice on
-- dedicated servers. The authority owns the visible reply (private system
-- chat); the client-side run only logs - its EnterChat_Receive fallback
-- would render the reply attributed to the player, duplicating the system
-- line. In standalone/host the local run IS the authority and chats normally.
function Role.ack(playerCtx, msg)
    if Role.hasWorldAuthority() then
        return Role.chat(playerCtx, msg, "command")
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
    Role.chat(playerCtx, msg)
end

return Role
