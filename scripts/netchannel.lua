-- netchannel.lua: client -> host transport for evolve requests on a
-- dedicated server or a connected co-op client. Uses Carrier C
-- (PalOtomoHolderComponentBase:SetSelectOtomoID_ToServer with a magic int) -
-- see docs/Palvolve/SERVER-COMPAT.md for the carrier decision, the vanilla
-- side-effect neutralization and the ack channel.
--
-- Wire format:
--   ID    = MAGIC (high 16 bits) | opcode (low 16 bits)
--   Index = (reqId << 8) | targetIndex   (int32, stays positive)
--   opcode 7 = legacy evolve, 8 = prestige, 9 = v3-aware evolve
-- The client only ever sends WHICH target-list option it picked (a small
-- index), never the target species. The host re-derives the pair or prestige
-- target from its OWN config and re-validates ownership/level/cost - a hostile
-- or desynced client can never name something the host did not authorize.
local Config = require("config")
local Role = require("role")

local NetChannel = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local MAGIC = 0x50560000
local MAGIC_MASK = 0xFFFF0000
local OP_EVOLVE_LEGACY = 7
local OP_PRESTIGE = 8
local OP_EVOLVE_V3 = 9
-- The lock is not an evolution and carries no option index, but it has to make
-- the same trip: it writes a passive on the Pal, and on a connected client that
-- write lands on a replica the host never sees. The index byte carries the
-- wanted state instead of a pair.
local OP_AUTOLOCK = 10
-- Fusions: the index byte is the partner party slot + 1 for a battle fusion,
-- and 1 for the altar (the altar knows its two Pals itself).
local OP_FUSE_BATTLE = 11
local OP_FUSE_ALTAR = 12
-- The altar pick travels ahead of the altar request: the index byte of
-- OP_FUSE_PICK is a bit mask over the passive pool (at most eight entries),
-- and OP_FUSE_ALTAR then says 1 = no pick, 2 = pick + male, 3 = pick + female.
local OP_FUSE_PICK = 13
NetChannel.OP_FUSE_BATTLE = OP_FUSE_BATTLE
NetChannel.OP_FUSE_ALTAR = OP_FUSE_ALTAR
NetChannel.OP_FUSE_PICK = OP_FUSE_PICK
NetChannel.OP_EVOLVE_LEGACY = OP_EVOLVE_LEGACY
NetChannel.OP_PRESTIGE = OP_PRESTIGE
NetChannel.OP_EVOLVE_V3 = OP_EVOLVE_V3
NetChannel.OP_AUTOLOCK = OP_AUTOLOCK

-- host -> client phase signals, carried in SendScreenLogToClient (invisible
-- in the retail HUD; the client mod hooks that RPC and parses the prefix).
-- The host drives the MP evolution presentation as a small state machine:
--   start  = identifies the transformation and starts the client presentation
--   reveal = the fresh actor is placed and frozen; the client grows/reveals it
local SIGNAL_PREFIX = "PVLV1|sig|"
local PHASE_PREFIX = "PVLV3|phase|"
-- host -> client: an altar fusion starts, play its picture (fusionfx.lua)
local SCENE_PREFIX = "PVLV3|scene|"

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

local function validTargetIndex(index)
    local n = tonumber(index)
    return n and n % 1 == 0 and n >= 1 and n <= 255
end

local function v3TreeReady()
    local serverCheck = package.loaded["servercheck"]
    local sync = package.loaded["treesync"]
    if not (serverCheck and serverCheck.getGeneration and sync and sync.hasV3ForGeneration) then
        return false
    end
    if serverCheck.remoteV3Ready then return serverCheck.remoteV3Ready() end
    return sync.hasV3ForGeneration(serverCheck.getGeneration())
end

function NetChannel.v3TreeReady()
    return v3TreeReady()
end

local function sendRequest(playerCtx, opcode, targetIndex)
    if not validTargetIndex(targetIndex) then return false, "invalid option index" end
    if not (playerCtx and playerCtx.pc) then return false, "no player" end
    targetIndex = math.floor(targetIndex)
    local ok = pcall(function()
        if not playerCtx.pc:IsValid() then error("invalid player") end
        local util = palUtility()
        local holder = util and util:GetOtomoHolderComponent(playerCtx.pc)
        if not (holder and holder:IsValid()) then error("no otomo holder component") end
        reqCounter = (reqCounter + 1) & 0x7FFFFF
        local index = ((reqCounter << 8) | targetIndex) & 0x7FFFFFFF
        holder:SetSelectOtomoID_ToServer(MAGIC | opcode, index)
    end)
    if not ok then Log("[net] send failed") end
    return ok
end

-- Sends "evolve my summoned pal via radial option <pairIndex>" to the host.
-- Returns ok (the send was issued; delivery/result comes back as a chat ack).
function NetChannel.sendEvolve(playerCtx, pairIndex)
    local opcode = v3TreeReady() and OP_EVOLVE_V3 or OP_EVOLVE_LEGACY
    return sendRequest(playerCtx, opcode, pairIndex)
end

-- Prestige is never sent on version knowledge alone. The v3 tree proves that
-- this exact connection generation received the target list whose index the
-- client is about to transmit.
function NetChannel.sendPrestige(playerCtx, targetIndex)
    if not v3TreeReady() then return false, "v3 tree not ready" end
    return sendRequest(playerCtx, OP_PRESTIGE, targetIndex)
end

-- Asks the host to flip the auto-evolve lock on the player's summoned Pal.
--
-- A toggle rather than a wanted state, because the wheel entry carries no state
-- to compare against and the host holds the authoritative passive list anyway.
-- The index byte is 1 and means toggle. It is not 0 because validTargetIndex
-- rejects that on both sides; an explicit lock or unlock from a client would be
-- 2 and 3, and neither has a caller yet.
function NetChannel.sendAutoLock(playerCtx)
    return sendRequest(playerCtx, OP_AUTOLOCK, 1)
end

--- Asks the host to fuse the summoned Pal with the one in party slot partnerSlot (0-based).
function NetChannel.sendFuseBattle(playerCtx, partnerSlot)
    return sendRequest(playerCtx, OP_FUSE_BATTLE, (tonumber(partnerSlot) or -1) + 1)
end

--- Asks the host to run the fusion at the player's nearby altar.
function NetChannel.sendFuseAltar(playerCtx)
    return sendRequest(playerCtx, OP_FUSE_ALTAR, 1)
end

-- The second half of a picked altar fusion, sent once the host's rate limit
-- lets the next request through. The wait runs on the LoopAsync thread; the
-- send itself is a UFunction call and goes to the game thread.
local pendingAltar = nil
local altarDue = nil
local function sendAltarGameThread()
    local p = altarDue
    altarDue = nil
    if not p then return end
    if sendRequest(p.ctx, OP_FUSE_ALTAR, p.gender == 2 and 3 or 2) then
        Log("[net] altar request sent after the pick")
    else
        Log("[net] altar request after the pick could not be sent")
    end
end
local function altarTick()
    local p = pendingAltar
    if not p then return true end
    if os.clock() < p.at then return false end
    pendingAltar = nil
    altarDue = p
    ExecuteInGameThread(sendAltarGameThread)
    return true
end
NetChannel._altarTick = altarTick -- held by the module so the callback is never collected
NetChannel._sendAltarGameThread = sendAltarGameThread

--- Sends the pick (pool positions and gender) and then the altar request.
function NetChannel.sendFuseAltarChoice(playerCtx, passiveIndexes, gender)
    local mask = 0
    for _, i in ipairs(passiveIndexes or {}) do
        if i >= 1 and i <= 8 then mask = mask | (1 << (i - 1)) end
    end
    if mask == 0 then
        -- no passive picked: the gender still has to travel, and a zero mask
        -- is not a valid index, so the pick is left out and the host keeps none
        return sendRequest(playerCtx, OP_FUSE_ALTAR, gender == 2 and 3 or 2)
    end
    if not sendRequest(playerCtx, OP_FUSE_PICK, mask) then return false end
    local gap = (Config.net and Config.net.rateLimitSeconds) or 2
    pendingAltar = { ctx = playerCtx, gender = gender, at = os.clock() + gap + 0.3 }
    LoopAsync(100, NetChannel._altarTick)
    return true
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

-- An unset FGuid is still a table, so it passes a nil check and then identifies nobody.
-- Treating it as a real sender id lets per-player gating and record lookups key off a
-- value every player shares.
local function isZeroGuid(g)
    return not g or (g.A == 0 and g.B == 0 and g.C == 0 and g.D == 0)
end

local zeroUidLogged = false

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
    -- Sent whatever the chat setting says. Which version a server runs is the
    -- first question every support case starts with, and it is the one line a
    -- player cannot look up anywhere else - a quiet server that swallows it
    -- leaves every later symptom unexplained. Everything else the mod says on
    -- its own still follows the setting.
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

    -- Payload measurement, dev builds only. It has to start here rather than
    -- from a chat command: on a dedicated server the client's chat never
    -- reaches this process, so the command runs on the sender and measures
    -- nothing. The join is the one moment the host knows a remote client by
    -- name, which is also when a tree sync would have to start.
    -- Deliberately behind its own switch rather than devMode: this fires on
    -- every join, and a ladder that reaches too high kills the server process
    -- rather than failing. Set Config.probeNetPayloadOnJoin = true to measure.
    -- The tree this server runs, handed over in one message. Before this, every
    -- player needed the same config_user.lua by hand, and a client whose file
    -- differed did not just see a wrong tree: it sends an option INDEX, and the
    -- host resolves that index against its own list.
    pcall(function()
        local okSync, sync = pcall(require, "treesync")
        if okSync and sync and sync.sendTo then sync.sendTo(senderCtx) end
    end)

    if Config.devMode then
        local okP, probes = pcall(require, "probes")
        if okP and probes then
            if Config.probeNetPayloadOnJoin == true and probes.probeNetPayload then
                pcall(probes.probeNetPayload, senderCtx)
            end
            -- decides for itself whether it is armed; probes.lua never ships
            if probes.maybeBurstOnJoin then pcall(probes.maybeBurstOnJoin, senderCtx) end
        end
    end
end

-- handler(senderCtx, request) -> ok, message
-- request is plain data: { opcode, index }. The host-side handler resolves the
-- indexed pair or prestige target from its own config and never receives a
-- species id from the client.
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
    local pendingRequest = nil -- set by pre when a valid request arrives
    local pendingRestore = nil -- selection value to restore after the body

    local hostHookOk = pcall(function()
        RegisterHook("/Script/Pal.PalOtomoHolderComponentBase:SetSelectOtomoID_ToServer",
            function(self, ID, Index)
                pendingRequest = nil
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
                    local targetIndex = raw & 0xFF

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

                    local knownOpcode = opcode == OP_EVOLVE_LEGACY
                        or opcode == OP_PRESTIGE or opcode == OP_EVOLVE_V3
                        or opcode == OP_AUTOLOCK
                        or opcode == OP_FUSE_BATTLE or opcode == OP_FUSE_ALTAR
                        or opcode == OP_FUSE_PICK
                    if not knownOpcode then
                        Log(string.format("Request dropped: unknown opcode %d", opcode))
                        return
                    end
                    if not validTargetIndex(targetIndex) then
                        Log(string.format("Request dropped: opcode %d has invalid option %d",
                            opcode, targetIndex))
                        return
                    end

                    local senderCtx = Role.playerCtxFor(owner)
                    if not (senderCtx and senderCtx.playerUId) then
                        Log("Request dropped: sender player id unresolved")
                        return
                    end
                    -- Deliberately not a drop: a zero id still identifies the requester well
                    -- enough for the evolve itself, and refusing here would turn a missing
                    -- recipe unlock into no evolutions at all. Note it once so a support log
                    -- says whether this is what broke the record lookup.
                    if isZeroGuid(senderCtx.playerUId) and not zeroUidLogged then
                        zeroUidLogged = true
                        Log("Sender player id is a zero guid - per-player lookups will not match")
                    end

                    local drop = gate(guidStr(senderCtx.playerUId), reqId)
                    if drop then
                        Log("Request dropped: " .. drop)
                        return
                    end

                    pendingRequest = { opcode = opcode, index = targetIndex }
                    Log(string.format("Request received (reqId %d, opcode %d, option %d)",
                        reqId, opcode, targetIndex))
                end)
            end,
            function(self, ID, Index)
                pcall(function()
                    local request = pendingRequest
                    local restore = pendingRestore
                    pendingRequest = nil
                    pendingRestore = nil
                    if request == nil and restore == nil then return end

                    -- fresh holder from the POST-hook's own self (survives here,
                    -- unlike a stored pre-hook reference)
                    local holder = self:get()
                    if not (holder and holder:IsValid()) then
                        if request ~= nil then Log("Request aborted: holder invalid at post-hook") end
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

                    if request ~= nil then
                        -- the owner (controller) is a stable actor; the handler
                        -- re-resolves the holder from it via GetComponentByClass
                        local owner = holder:GetOwner()
                        if not (owner and owner:IsValid()) then
                            Log("Request aborted: owner invalid")
                            return
                        end
                        local senderCtx = Role.playerCtxFor(owner)
                        if not senderCtx then
                            Log("Request aborted: sender context unresolved at post-hook")
                            return
                        end
                        -- the handler (headless path) drives the phase stream
                        -- itself via NetChannel.sendPhaseStart/Reveal; here we relay a
                        -- failure reason to the requester AND log it server-side,
                        -- so a rejected evolve leaves a trace even when the chat
                        -- channel does not render on the client
                        local ok, msg = handler(senderCtx, request)
                        if not ok then
                            Log("Request rejected: " .. tostring(msg or "no reason given"))
                            if msg then Role.chat(senderCtx, msg, "reply") end
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
                        -- Releasing a borrowed tree is ServerCheck's call, not
                        -- this hook's: it classifies the world with a grace
                        -- window, and the host's greet regularly arrives before
                        -- this hook does. Deciding here as well would mean two
                        -- owners for one question, and the earlier one racing
                        -- a tree that just landed.
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
        Log("Network channel active (host): indexed requests via carrier C")
    else
        Log("Network channel host hook FAILED to register - indexed requests will NOT reach the server")
    end
end

local phaseCounter = 0

local function sendClientText(pc, text, tag)
    if not pc then return false end
    return pcall(function()
        if not pc:IsValid() then error("invalid player controller") end
        pc:SendScreenLogToClient(text,
            { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }, 0.1, FName(tag))
    end)
end

local function phaseFieldSafe(value)
    local s = tostring(value or "")
    return s ~= "" and not s:find("|", 1, true) and not s:find("[\r\n]")
end

local function nextPhaseSequence()
    phaseCounter = (phaseCounter + 1) & 0x7FFFFFFF
    if phaseCounter == 0 then phaseCounter = 1 end
    return phaseCounter
end

-- The legacy signal stays unchanged for 1.8 clients and for the handshake.
function NetChannel.sendSignal(pc, kind)
    return sendClientText(pc, SIGNAL_PREFIX .. tostring(kind or ""), "PalvolveSig")
end

-- Starts one identified presentation and returns its sequence. The v3 message
-- is sent first so the usual path claims the sequence before its legacy mirror;
-- the receiver still handles either order because carrier ordering is unproven.
--- @param stage number|nil prestige stage, carried only by the start2 frame
function NetChannel.sendPhaseStart(pc, mode, fromId, toId, stone, stage)
    local legacyOk = false
    if not (phaseFieldSafe(mode) and phaseFieldSafe(fromId)
        and phaseFieldSafe(toId) and phaseFieldSafe(stone)) then
        Log("[net] v3 phase start not sent: invalid presentation field")
        legacyOk = NetChannel.sendSignal(pc, "start")
        return nil, false, legacyOk
    end
    local seq = nextPhaseSequence()

    -- Two frames, start2 FIRST. The old `start` shape is exactly matched by the
    -- receiver's pattern, so a field could not be appended to it without
    -- breaking every client that has not updated yet. start2 carries the extra
    -- field; a client that does not know it drops the line and takes the `start`
    -- that follows. A client that does know it claims the sequence, and the
    -- receiver's own dedupe then discards the second frame.
    --
    -- Without this a connected client drew every prestige as stage 1: it cannot
    -- read the stage off the passives instead, because those may replicate after
    -- the frame arrives.
    local v3Ok = false
    if stage ~= nil and phaseFieldSafe(tostring(stage)) then
        local frame2 = table.concat({ PHASE_PREFIX:sub(1, -2), tostring(seq), "start2",
            tostring(mode), tostring(fromId), tostring(toId), tostring(stone),
            tostring(stage) }, "|")
        v3Ok = sendClientText(pc, frame2, "PalvolvePhase")
    end
    local frame = table.concat({ PHASE_PREFIX:sub(1, -2), tostring(seq), "start",
        tostring(mode), tostring(fromId), tostring(toId), tostring(stone) }, "|")
    local plainOk = sendClientText(pc, frame, "PalvolvePhase")
    v3Ok = v3Ok or plainOk
    legacyOk = NetChannel.sendSignal(pc, "start")
    return seq, v3Ok, legacyOk
end

local function readIsLocal(pc) return pc:IsLocalPlayerController() end
local function readName(o) return o:GetFullName() end

--- Tells every connected player that an altar fusion starts, so each can play
--- its picture: the server's effects, sounds and camera reach nobody. info:
--- center {x,y,z}, land {x,y,z}, landYaw, idA, idB, idC. Returns how many
--- players it reached.
function NetChannel.broadcastAltarScene(info)
    for _, id in ipairs({ info.idA, info.idB, info.idC }) do
        if not phaseFieldSafe(id) then
            Log("[net] altar scene not sent: invalid species id")
            return 0
        end
    end
    local c, l = info.center, info.land
    local frame = SCENE_PREFIX .. table.concat({
        string.format("%.1f", c.x), string.format("%.1f", c.y), string.format("%.1f", c.z),
        string.format("%.1f", l.x), string.format("%.1f", l.y), string.format("%.1f", l.z),
        string.format("%.2f", info.landYaw or 0), info.idA, info.idB, info.idC,
    }, "|")
    local sent, failed = 0, 0
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        local okName, name = pcall(readName, pc)
        local okLocal, isLocal = pcall(readIsLocal, pc)
        if okName and not name:find("Default__", 1, true) and okLocal and not isLocal then
            if sendClientText(pc, frame, "PalvolveScene") then sent = sent + 1 else failed = failed + 1 end
        end
    end
    Log(string.format("[net] altar scene sent to %d player(s)%s", sent,
        failed > 0 and string.format(", %d failed", failed) or ""))
    return sent
end

function NetChannel.sendPhaseReveal(pc, seq)
    local n = tonumber(seq)
    local v3Ok = false
    if n and n % 1 == 0 and n >= 1 and n <= 0x7FFFFFFF then
        local frame = PHASE_PREFIX .. tostring(math.floor(n)) .. "|reveal"
        v3Ok = sendClientText(pc, frame, "PalvolvePhase")
    else
        Log("[net] v3 phase reveal not sent: invalid sequence")
    end
    local legacyOk = NetChannel.sendSignal(pc, "reveal")
    return v3Ok, legacyOk
end

local clientGeneration = 0
local signalHandler = nil
local pongHandler = nil
local phaseStates = {}
local phaseOrder = {}
local callbackQueue = {}
local callbackDrainScheduled = false
local legacyPending = {}
local legacyTimerArmed = false
local legacySuppress = { start = nil, reveal = nil }
local treeFrameQueue = {}
local treeDrainScheduled = false
local MAX_PHASE_STATES = 64
local LEGACY_GRACE_MS = 150

local function drainClientCallbacks()
    callbackDrainScheduled = false
    while #callbackQueue > 0 do
        local event = table.remove(callbackQueue, 1)
        if event.pong ~= nil or event.generation == clientGeneration then
            if event.pong ~= nil then
                if pongHandler then pcall(pongHandler, event.pong) end
            elseif signalHandler then
                pcall(signalHandler, event.kind, event.phase)
            end
        end
    end
end

local function queueClientCallback(kind, phase, pong)
    callbackQueue[#callbackQueue + 1] = {
        kind = kind, phase = phase, pong = pong, generation = clientGeneration,
    }
    if callbackDrainScheduled then return end
    callbackDrainScheduled = true
    local ok = pcall(ExecuteInGameThread, drainClientCallbacks)
    if not ok then
        callbackDrainScheduled = false
        callbackQueue = {}
    end
end

local armLegacyTimer
local function drainLegacySignals()
    legacyTimerArmed = false
    local ready = legacyPending
    legacyPending = {}
    for _, pending in ipairs(ready) do
        if pending.generation == clientGeneration then
            queueClientCallback(pending.kind, nil, nil)
        end
    end
    return true
end

armLegacyTimer = function()
    if legacyTimerArmed then return end
    legacyTimerArmed = true
    if not pcall(LoopAsync, LEGACY_GRACE_MS, drainLegacySignals) then
        legacyTimerArmed = false
        legacyPending = {}
    end
end

local function queueLegacySignal(kind)
    local suppressUntil = legacySuppress[kind]
    legacySuppress[kind] = nil
    if suppressUntil and suppressUntil >= os.clock() then
        return
    end
    legacyPending[#legacyPending + 1] = {
        kind = kind,
        generation = clientGeneration,
    }
    armLegacyTimer()
end

local function claimLegacyMirror(kind)
    for i, pending in ipairs(legacyPending) do
        if pending.generation == clientGeneration and pending.kind == kind then
            table.remove(legacyPending, i)
            return
        end
    end
    -- A mirror is sent next to its v3 phase. Expiring this claim prevents a
    -- lost legacy packet from suppressing an unrelated legacy-only sequence
    -- much later on the same connection.
    legacySuppress[kind] = os.clock() + 2
end

local function phaseState(seq)
    local stateForSeq = phaseStates[seq]
    if stateForSeq then return stateForSeq end
    stateForSeq = { seq = seq, generation = clientGeneration }
    phaseStates[seq] = stateForSeq
    phaseOrder[#phaseOrder + 1] = seq
    while #phaseOrder > MAX_PHASE_STATES do
        local old = table.remove(phaseOrder, 1)
        phaseStates[old] = nil
    end
    return stateForSeq
end

local function receiveV3Phase(text)
    if text:sub(1, #PHASE_PREFIX) ~= PHASE_PREFIX then return false end

    -- start2 is tried first: it is the same frame with the prestige stage
    -- appended, and both are sent for one presentation.
    local stageText
    local seqText, mode, fromId, toId, stone
    seqText, mode, fromId, toId, stone, stageText =
        text:match("^PVLV3|phase|(%d+)|start2|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if not seqText then
        seqText, mode, fromId, toId, stone =
            text:match("^PVLV3|phase|(%d+)|start|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    end
    if seqText then
        local seq = tonumber(seqText)
        if not seq or seq < 1 or seq > 0x7FFFFFFF or seq % 1 ~= 0 then return true end
        local stateForSeq = phaseState(seq)
        if stateForSeq.startReceived then return true end
        stateForSeq.startReceived = true
        stateForSeq.info = {
            seq = seq, mode = mode, from = fromId, to = toId, stone = stone,
            stage = tonumber(stageText),
            generation = clientGeneration,
        }
        claimLegacyMirror("start")
        stateForSeq.startQueued = true
        queueClientCallback("start", stateForSeq.info, nil)
        if stateForSeq.revealReceived and not stateForSeq.revealQueued then
            stateForSeq.revealQueued = true
            queueClientCallback("reveal", stateForSeq.info, nil)
        end
        return true
    end

    seqText = text:match("^PVLV3|phase|(%d+)|reveal$")
    if seqText then
        local seq = tonumber(seqText)
        if not seq or seq < 1 or seq > 0x7FFFFFFF or seq % 1 ~= 0 then return true end
        local stateForSeq = phaseState(seq)
        if stateForSeq.revealReceived then return true end
        stateForSeq.revealReceived = true
        claimLegacyMirror("reveal")
        if stateForSeq.startReceived and not stateForSeq.revealQueued then
            stateForSeq.revealQueued = true
            queueClientCallback("reveal", stateForSeq.info, nil)
        end
        return true
    end
    return true
end

function NetChannel.beginGeneration(gen)
    gen = math.floor(tonumber(gen) or 0)
    if gen == clientGeneration then return end
    clientGeneration = gen
    phaseStates = {}
    phaseOrder = {}
    legacyPending = {}
    legacySuppress = { start = nil, reveal = nil }
end

local function drainTreeFrames()
    treeDrainScheduled = false
    local okSync, sync = pcall(require, "treesync")
    if not (okSync and sync and sync.applyFrame) then
        local dropped = #treeFrameQueue
        treeFrameQueue = {}
        Log(string.format("[ERROR] dropped %d queued tree frame%s: treesync unavailable (%s)",
            dropped, dropped == 1 and "" or "s", tostring(sync)))
        return
    end
    while #treeFrameQueue > 0 do
        local frame = treeFrameQueue[1]
        local okApply, applied = pcall(sync.applyFrame, frame)
        table.remove(treeFrameQueue, 1)
        if not okApply then
            Log(string.format("[ERROR] tree frame application threw and the frame was dropped: %s",
                tostring(applied)))
        elseif not applied then
            Log("[WARN] rejected tree frame was deliberately dropped")
        else
            Log(string.format("[INFO] applied queued tree frame; %d remain", #treeFrameQueue))
        end
    end
end

local function queueTreeFrame(frame)
    treeFrameQueue[#treeFrameQueue + 1] = frame
    if treeDrainScheduled then
        Log(string.format("[INFO] queued tree frame behind the scheduled drain; %d waiting",
            #treeFrameQueue))
        return
    end
    treeDrainScheduled = true
    local okSchedule, scheduleErr = pcall(ExecuteInGameThread, drainTreeFrames)
    if not okSchedule then
        treeDrainScheduled = false
        Log(string.format("[ERROR] tree-frame drain scheduling failed; %d frame%s kept for the next scheduling attempt: %s",
            #treeFrameQueue, #treeFrameQueue == 1 and "" or "s", tostring(scheduleErr)))
    else
        Log(string.format("[INFO] tree-frame drain scheduled with %d frame%s queued",
            #treeFrameQueue, #treeFrameQueue == 1 and "" or "s"))
    end
end

local sceneFrames = {}

local function parseScene(text)
    local f = {}
    for part in (text:sub(#SCENE_PREFIX + 1) .. "|"):gmatch("([^|]*)|") do f[#f + 1] = part end
    if #f ~= 10 then return nil end
    local n = {}
    for i = 1, 7 do
        n[i] = tonumber(f[i])
        if not n[i] then return nil end
    end
    return {
        center = { x = n[1], y = n[2], z = n[3] }, land = { x = n[4], y = n[5], z = n[6] },
        landYaw = n[7], idA = f[8], idB = f[9], idC = f[10],
    }
end

function NetChannel._sceneGameThread()
    while #sceneFrames > 0 do
        local text = table.remove(sceneFrames, 1)
        local info = parseScene(text)
        if not info then
            Log("[WARN] [net] altar scene frame unreadable: " .. text)
        else
            local FusionFx = package.loaded["fusionfx"]
            if not FusionFx then
                Log("[WARN] [net] altar scene arrived, but the scene module is not loaded")
            else
                local ok, err = pcall(FusionFx.playRemote, info)
                if not ok then Log("[ERROR] [net] altar scene failed: " .. tostring(err)) end
            end
        end
    end
end

local function readMessageText(Message)
    return Message:get():ToString()
end

local function handleClientMessage(_, Message)
    local okText, text = pcall(readMessageText, Message)
    if not okText or type(text) ~= "string" then return end

    if text:sub(1, 11) == "PVLV2|tree|" or text:sub(1, 11) == "PVLV3|tree|"
        or text:sub(1, 11) == "PVLV3|fuse|" then
        queueTreeFrame(text)
        return
    end
    if receiveV3Phase(text) then return end
    if text:sub(1, #SCENE_PREFIX) == SCENE_PREFIX then
        sceneFrames[#sceneFrames + 1] = text
        ExecuteInGameThread(NetChannel._sceneGameThread)
        return
    end

    local xnet = text:match("^PVLV1|xnet|(.*)$")
    if xnet then
        local seq, size = xnet:match("^xnet|(%d+)|(%d+)|")
        local fill = xnet:match("^xnet|%d+|%d+|(.-)|%d+|end$")
        local claimed = xnet:match("|(%d+)|end$")
        local sum = 0
        if fill then
            for i = 1, #fill do sum = (sum * 31 + fill:byte(i)) % 1000000007 end
        end
        Log(string.format("[probe-xnet] recv seq=%s size=%s arrived=%d tail=%s sum=%s",
            tostring(seq), tostring(size), #xnet,
            xnet:sub(-4) == "|end" and "ok" or "MISSING",
            (claimed and tonumber(claimed) == sum) and "ok" or "BAD"))
        return
    end
    if text:sub(1, #SIGNAL_PREFIX) ~= SIGNAL_PREFIX then return end
    local kind = text:sub(#SIGNAL_PREFIX + 1)
    local pong = kind:match("^pong|(.*)$")
    if pong ~= nil then
        queueClientCallback(nil, nil, pong)
    elseif kind == "start" or kind == "reveal" then
        queueLegacySignal(kind)
    else
        queueClientCallback(kind, nil, nil)
    end
end

local function clientMessageHook(self, Message)
    local ok, err = pcall(handleClientMessage, self, Message)
    if not ok then Log("Network message parse failed: " .. tostring(err)) end
end

-- Client side: v3 phases are keyed by sequence before they reach the
-- presentation callback. Duplicate starts/reveals are discarded, an early
-- reveal waits for its start, and the unsequenced legacy mirror gets a short
-- grace window in which the matching v3 phase can claim it.
function NetChannel.initClient(onSignal, onPong)
    signalHandler = onSignal
    pongHandler = onPong
    pcall(function()
        RegisterHook("/Script/Pal.PalPlayerController:SendScreenLogToClient",
            clientMessageHook)
        Log("Network channel active (client): v3 phases and legacy signals hooked")
    end)
end

return NetChannel
