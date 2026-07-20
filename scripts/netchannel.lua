-- netchannel.lua: client -> host transport for evolve requests on a
-- dedicated server or a connected co-op client. Uses Carrier C
-- (PalOtomoHolderComponentBase:SetSelectOtomoID_ToServer with a magic int) -
-- see docs/Palvolve/SERVER-COMPAT.md for the carrier decision, the vanilla
-- side-effect neutralization and the ack channel.
--
-- Wire format:
--   ID    = MAGIC (high 16 bits) | opcode (low 16 bits)
--   Index = (reqId << 8) | pairIndex   (int32, stays positive)
-- The client only ever sends WHICH radial option it picked (a small index),
-- never the target species. The host re-derives the pair from its OWN
-- config at that index and re-validates ownership/level/cost - a hostile or
-- desynced client can never make the host evolve something it did not
-- authorize.
local Config = require("config")
local Role = require("role")

local NetChannel = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local MAGIC = 0x50560000
local MAGIC_MASK = 0xFFFF0000
local OP_EVOLVE = 7

-- host -> client phase signals, carried in SendScreenLogToClient (invisible
-- in the retail HUD; the client mod hooks that RPC and parses the prefix).
-- The host drives the MP evolution presentation as a small state machine:
--   start  = species swapped + pal frozen; client plays the dissolve + recalls
--   ready  = old body destroyed (pool broken); client re-summons the new form
--   reveal = new actor spawned, teleported to the old spot + frozen; client
--            plays the grow/finale reveal
local SIGNAL_PREFIX = "PVLV1|sig|"

local function palUtility()
    local u = StaticFindObject("/Script/Pal.Default__PalUtility")
    if u and u:IsValid() then return u end
    return nil
end

-- Engine net mode read from a world context object: true on any authority
-- (standalone, listen host, dedicated). Unlike an actor's HasAuthority this is a
-- world-level property, so it is already correct inside the join hook.
local function worldIsAuthority(wc)
    local ok = false
    pcall(function()
        local k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if k and k:IsValid() and wc then ok = (k:IsServer(wc) == true) end
    end)
    return ok
end

-- ---------------------------------------------------------------- client send

local reqCounter = 0

-- Sends "evolve my summoned pal via radial option <pairIndex>" to the host.
-- Returns ok (the send was issued; delivery/result comes back as a chat ack).
function NetChannel.sendEvolve(playerCtx, pairIndex)
    if not (playerCtx and playerCtx.pc and playerCtx.pc:IsValid()) then
        return false, "no player"
    end
    local ok = pcall(function()
        local util = palUtility()
        local holder = util and util:GetOtomoHolderComponent(playerCtx.pc)
        if not (holder and holder:IsValid()) then error("no otomo holder component") end
        reqCounter = (reqCounter + 1) & 0x7FFFFF
        local index = ((reqCounter << 8) | (pairIndex & 0xFF)) & 0x7FFFFFFF
        holder:SetSelectOtomoID_ToServer(MAGIC | OP_EVOLVE, index)
    end)
    if not ok then Log("[net] send failed") end
    return ok
end

-- The "do you run Palvolve?" handshake is host-driven, not a client ping: no
-- Lua-callable client->server RPC transmits reliably early (the otomo carrier needs
-- a summoned Pal; RequestGetUserInfoByPlayerUId and the like are dropped by native
-- validation). Instead the host greets each joining client from its server-side
-- PalPlayerCharacter:OnCompleteInitializeParameter join hook (see initHost). The
-- client only waits for the pong; a timeout without one means the host has no
-- Palvolve. ServerCheck installs onLocalEnterWorld to (re)start its check each time
-- the LOCAL player enters a remote world (the same join hook fires client-side).
NetChannel.onLocalEnterWorld = nil

-- ---------------------------------------------------------------- host receive

-- per-sender rate limit + replay window (uid string -> state)
local senders = {}

-- per-sender last visible-greet time: a client sends several handshake pings, but
-- only one "server runs Palvolve" chat line should appear per sender per window
local greeted = {}
local GREET_WINDOW_S = 60

-- Replay protection is TIME-based, not a persistent reqId set: a client's
-- send counter resets to zero on mod reload / reconnect, so a set keyed only
-- by (uid, reqId) would reject a reconnecting client's reused ids 1..N. A
-- short window only dedups genuine retransmits of the same in-flight request;
-- the host re-validates ownership/level/cost on every request anyway, so a
-- late replay is at worst a second legitimate attempt, never an exploit.
local REPLAY_WINDOW_S = 15

local function guidStr(g)
    return string.format("%08X-%08X-%08X-%08X", g.A, g.B, g.C, g.D)
end

-- returns dropReason or nil (nil = accept)
local function gate(uidStr, reqId)
    local now = os.clock()
    local s = senders[uidStr]
    if not s then
        s = { last = -1e9, seen = {} }
        senders[uidStr] = s
    end
    local seenAt = s.seen[reqId]
    if seenAt and (now - seenAt) < REPLAY_WINDOW_S then return "duplicate" end
    local minGap = (Config.net and Config.net.rateLimitSeconds) or 2
    if (now - s.last) < minGap then return "rate-limited" end
    s.last = now
    s.seen[reqId] = now
    -- evict stale entries so the table stays bounded
    for k, t in pairs(s.seen) do
        if (now - t) > REPLAY_WINDOW_S then s.seen[k] = nil end
    end
    return nil
end

-- Greet a joining Palvolve client: a hidden pong (drives the client's detection and
-- version compare) plus one visible [SYSTEM] chat line, deduped per sender so
-- repeated pings draw a single line. SendSystemToPlayerChat posts an unattributed
-- system line to JUST that player (no "[Name]:" prefix, and not a broadcast to all).
local function greetSender(senderCtx)
    if not (senderCtx and senderCtx.pc and senderCtx.playerUId) then return end
    local uid = guidStr(senderCtx.playerUId)
    local now = os.clock()
    -- called on every vanilla otomo selection, so dedup the WHOLE greet per sender
    if greeted[uid] and (now - greeted[uid]) <= GREET_WINDOW_S then return end
    greeted[uid] = now
    -- hidden pong drives the client's detection + version compare
    NetChannel.sendSignal(senderCtx.pc, "pong|" .. tostring(Config.modVersion))
    -- one visible [SYSTEM] line, delivered to just this player. The world context
    -- is the world object (as the working community mods pass), NOT the controller;
    -- the receiver list is a TArray<FGuid> (plural in the 1.0 build).
    pcall(function()
        local util = palUtility()
        local world = FindFirstOf("World")
        local g = senderCtx.playerUId
        if util and world then
            util:SendSystemToPlayerChat(world,
                "Palvolve v" .. tostring(Config.modVersion) .. " active on this server",
                { { A = g.A, B = g.B, C = g.C, D = g.D } })
        end
    end)
    Log("Handshake: greeted client (pong v" .. tostring(Config.modVersion) .. ")")
end

-- handler(senderCtx, pairIndex, holder) -> ok, message
-- Runs entirely on the game thread inside the RPC's own hook frame: RPC
-- handlers already execute on the game thread, and the holder reference from
-- `self` only stays valid within that frame (deferring it via LoopAsync lets
-- it go stale). The pre-hook validates
-- and stashes; the post-hook runs the evolve AFTER the vanilla body, so the
-- native selection call completes cleanly first.
function NetChannel.initHost(handler)
    -- The pre-hook only stashes PLAIN DATA (a UObject wrapper from the
    -- pre-hook's `self:get()` does not survive being stored - it reads back
    -- nil). The post-hook re-derives the holder from ITS OWN fresh `self`
    -- parameter (same holder, valid in the post scope) and runs the evolve.
    local pendingPairIndex = nil -- set by pre when a valid evolve arrives
    local pendingRestore = nil   -- selection value to restore after the body

    local hostHookOk = pcall(function()
        RegisterHook("/Script/Pal.PalOtomoHolderComponentBase:SetSelectOtomoID_ToServer",
            function(self, ID, Index)
                pendingPairIndex = nil
                pendingRestore = nil
                pcall(function()
                    local id = ID:get()
                    if (id & MAGIC_MASK) ~= MAGIC then return end -- vanilla selection
                    local holder = self:get()
                    local owner = holder:GetOwner()
                    if not (owner and owner:IsValid()) then return end

                    -- AUTHORITY GATE: this hook is registered in every process. On a
                    -- client it ALSO fires for the player's own outgoing send. Only
                    -- the authority may touch the magic evolve payload (rewriting it
                    -- on a client destroys it before it reaches the server).
                    local isAuth = false
                    pcall(function() isAuth = owner:HasAuthority() end)
                    if not isAuth then return end

                    local opcode = id & 0xFFFF
                    local raw = Index:get()
                    local reqId = (raw >> 8) & 0x7FFFFF
                    local pairIndex = raw & 0xFF

                    -- neutralize the vanilla side effect: overwrite the params
                    -- with the player's current legitimate selection before the
                    -- native body runs (otherwise the magic int becomes the
                    -- selected otomo slot and breaks the summon key)
                    pcall(function()
                        local cur = holder:GetSelectedOtomoID()
                        ID:set(cur)
                        Index:set(cur)
                        pendingRestore = cur
                    end)

                    local senderCtx = Role.playerCtxFor(owner)
                    if not (senderCtx and senderCtx.playerUId) then
                        if opcode == OP_EVOLVE then Log("Evolve request dropped: sender player id unresolved") end
                        return
                    end

                    local drop = gate(guidStr(senderCtx.playerUId), reqId)
                    if drop then
                        if opcode == OP_EVOLVE then Log("Evolve request dropped: " .. drop) end
                        return
                    end

                    if opcode == OP_EVOLVE then
                        pendingPairIndex = pairIndex
                        Log(string.format("Evolve request received (reqId %d, option %d)", reqId, pairIndex))
                    end
                end)
            end,
            function(self, ID, Index)
                pcall(function()
                    local pairIndex = pendingPairIndex
                    local restore = pendingRestore
                    pendingPairIndex = nil
                    pendingRestore = nil
                    if pairIndex == nil and restore == nil then return end

                    -- fresh holder from the POST-hook's own self (survives here,
                    -- unlike a stored pre-hook reference)
                    local holder = self:get()
                    if not (holder and holder:IsValid()) then
                        if pairIndex ~= nil then Log("Evolve aborted: holder invalid at post-hook") end
                        return
                    end

                    -- keep the player's real selection (the vanilla body just
                    -- re-applied `cur`, but restore defensively)
                    if restore ~= nil then
                        local after = nil
                        pcall(function() after = holder:GetSelectedOtomoID() end)
                        if after ~= restore then
                            pcall(function() holder:SetSelectOtomoID(restore) end)
                        end
                    end

                    if pairIndex ~= nil then
                        -- the owner (controller) is a stable actor; the handler
                        -- re-resolves the holder from it via GetComponentByClass
                        local owner = holder:GetOwner()
                        if not (owner and owner:IsValid()) then
                            Log("Evolve aborted: request owner invalid")
                            return
                        end
                        local senderCtx = Role.playerCtxFor(owner)
                        if not senderCtx then
                            Log("Evolve aborted: sender context unresolved at post-hook")
                            return
                        end
                        -- the handler (headless path) drives the phase signals
                        -- itself via NetChannel.sendSignal; here we relay a
                        -- failure reason to the requester AND log it server-side,
                        -- so a rejected evolve leaves a trace even when the chat
                        -- channel does not render on the client
                        local ok, msg = handler(senderCtx, pairIndex)
                        if not ok then
                            Log("Evolve rejected: " .. tostring(msg or "no reason given"))
                            if msg then Role.chat(senderCtx, msg) end
                        end
                    end
                end)
            end)
    end)

    -- Join handshake: greet a connecting player when their character finishes
    -- initializing (name + UID are populated by then). This is the community-proven
    -- join trigger (used by PalworldEssentials/SphereProject for "welcome" lines):
    -- the host greets each joining client server-side, so no client->server ping is
    -- needed. The hook also fires on a client for its own character, but only the
    -- authority sends the greet.
    local joinHookOk = pcall(function()
        RegisterHook("/Script/Pal.PalPlayerCharacter:OnCompleteInitializeParameter",
            function(Context)
                pcall(function()
                    local char = Context:get()
                    if not (char and char:IsValid()) then return end
                    local controller = char.Controller
                    if not (controller and controller:IsValid()) then return end
                    local isAuth, isLocal = false, false
                    pcall(function() isAuth = controller:HasAuthority() end)
                    pcall(function() isLocal = controller:IsLocalPlayerController() end)
                    if isLocal then
                        -- OUR OWN character entered a world. ServerCheck classifies
                        -- that world from the engine net mode, so hand it the
                        -- character as the world context object.
                        if NetChannel.onLocalEnterWorld then
                            pcall(NetChannel.onLocalEnterWorld, char)
                        end
                    elseif isAuth and worldIsAuthority(char) then
                        -- authority side: a CONNECTED client's character finished
                        -- initializing -> greet that client. The net-mode check is a
                        -- belt so a client can never emit a greet on a stray
                        -- HasAuthority read.
                        greetSender(Role.playerCtxFor(controller))
                    end
                end)
            end)
    end)
    if not joinHookOk then
        Log("Network channel join handshake hook FAILED to register")
    end

    if hostHookOk then
        Log("Network channel active (host): evolve requests via carrier C")
    else
        Log("Network channel host hook FAILED to register - evolve requests will NOT reach the server")
    end
end

-- Host -> client phase signal (parameterless kind: "start"/"ready"/"reveal").
function NetChannel.sendSignal(pc, kind)
    if not (pc and pc:IsValid()) then return end
    pcall(function()
        pc:SendScreenLogToClient(SIGNAL_PREFIX .. kind,
            { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }, 0.1, FName("PalvolveSig"))
    end)
end

-- Client side: hook the host's phase signals (SendScreenLogToClient) and
-- dispatch the kind to onSignal(kind). Registered in every process; on the
-- host it also sees its own outgoing signal, but the client handlers no-op
-- without a local player, so it is harmless there.
function NetChannel.initClient(onSignal, onPong)
    pcall(function()
        RegisterHook("/Script/Pal.PalPlayerController:SendScreenLogToClient",
            function(self, Message)
                pcall(function()
                    local text = ""
                    pcall(function() text = Message:get():ToString() end)
                    if text and text:sub(1, #SIGNAL_PREFIX) == SIGNAL_PREFIX then
                        local kind = text:sub(#SIGNAL_PREFIX + 1)
                        local pong = kind:match("^pong|(.*)$")
                        if pong ~= nil then
                            if onPong then ExecuteInGameThread(function() pcall(onPong, pong) end) end
                        else
                            ExecuteInGameThread(function() pcall(onSignal, kind) end)
                        end
                    end
                end)
            end)
        Log("Network channel active (client): phase signals hooked")
    end)
end

return NetChannel
