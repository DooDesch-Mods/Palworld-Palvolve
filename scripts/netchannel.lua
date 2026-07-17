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

-- ---------------------------------------------------------------- host receive

-- per-sender rate limit + replay window (uid string -> state)
local senders = {}

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

    pcall(function()
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

                    -- AUTHORITY GATE: this hook is registered in every process.
                    -- On a client it ALSO fires for the player's own outgoing
                    -- send (UE4SS hooks the local UFunction execution). Doing
                    -- anything here on a client - rewriting the params or
                    -- processing locally - destroys the magic payload before it
                    -- reaches the server. Only the authority may touch it.
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
                    if not (senderCtx and senderCtx.playerUId) then return end
                    local drop = gate(guidStr(senderCtx.playerUId), reqId)
                    if drop then
                        if Config.devMode then Log("[net] dropped (" .. drop .. ")") end
                        return
                    end

                    if opcode == OP_EVOLVE then
                        pendingPairIndex = pairIndex
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
                    if not (holder and holder:IsValid()) then return end

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
                        if not (owner and owner:IsValid()) then return end
                        local senderCtx = Role.playerCtxFor(owner)
                        if not senderCtx then return end
                        -- the handler (headless path) drives the phase signals
                        -- itself via NetChannel.sendSignal; here we only relay a
                        -- failure reason to the requester
                        local ok, msg = handler(senderCtx, pairIndex)
                        if (not ok) and msg then Role.chat(senderCtx, msg) end
                    end
                end)
            end)
        Log("Network channel active (host): evolve requests via carrier C")
    end)
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
function NetChannel.initClient(onSignal)
    pcall(function()
        RegisterHook("/Script/Pal.PalPlayerController:SendScreenLogToClient",
            function(self, Message)
                pcall(function()
                    local text = ""
                    pcall(function() text = Message:get():ToString() end)
                    if text and text:sub(1, #SIGNAL_PREFIX) == SIGNAL_PREFIX then
                        local kind = text:sub(#SIGNAL_PREFIX + 1)
                        ExecuteInGameThread(function() pcall(onSignal, kind) end)
                    end
                end)
            end)
        Log("Network channel active (client): phase signals hooked")
    end)
end

return NetChannel
