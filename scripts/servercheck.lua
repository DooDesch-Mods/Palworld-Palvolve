-- servercheck.lua: decide, per world the local player enters, whether Palvolve's
-- server-authoritative features can work there at all.
--
-- A client-only install used to half-work on a server without Palvolve: the tech
-- shows but never persists, evolve silently does nothing. So on entering a world
-- the client classifies it and reacts:
--   single-player / listen host -> we own the world, everything works, stay silent
--   host WITH Palvolve          -> the host greets us (hidden pong + its own
--                                  [SYSTEM] chat line carrying the version)
--   host WITHOUT Palvolve       -> no greet arrives; disable evolution for the
--                                  session and tell the player once
--
-- The world is classified from the ENGINE NET MODE (KismetSystemLibrary:IsStandalone
-- / :IsServer), a world-level property that is already correct when the join hook
-- fires - unlike an actor's HasAuthority, which is not settled at that instant and
-- previously mislabelled single-player as a connected client.
local Config = require("config")
local Role = require("role")
local NetChannel = require("netchannel")
local I18n = require("i18n")

local ServerCheck = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- IDLE      no world entered yet (main menu)
-- RESOLVING connected client, waiting for the host's greet
-- LOCAL     we own the world (single-player / listen host) - never disabled
-- REMOTE    connected to a host that runs Palvolve
-- ABSENT    connected to a host WITHOUT Palvolve - features disabled this session
local ST = {
    IDLE = "idle", RESOLVING = "resolving", LOCAL = "local",
    REMOTE = "remote", ABSENT = "absent",
}
local state = ST.IDLE
local serverVersion = nil
-- bumped on every world entry, so a timeout or pong left over from a previous
-- world can never settle the current one
local generation = 0
-- The host greets as soon as OUR character finishes initializing on ITS side,
-- which regularly beats our own client-side init hook - the greet then arrives
-- before there is a world to attribute it to. Hold it here instead of dropping
-- it, and consume it the moment the world entry is classified.
local earlyPong = nil
local EARLY_PONG_MAX_AGE_S = 30

function ServerCheck.getStatus() return state end
function ServerCheck.getServerVersion() return serverVersion end

-- Features are disabled ONLY once we positively know the host lacks Palvolve.
-- Single-player, listen host and the short resolving window stay enabled (the
-- host revalidates every request anyway).
function ServerCheck.blocked() return state == ST.ABSENT end

-- True only on a confirmed Palvolve host - the gate for transmitting an
-- evolve request over the net channel (never send a carrier to a vanilla host).
function ServerCheck.remoteReady() return state == ST.REMOTE end

-- FText from a Lua string. UE4SS resolves the engine converter behind FText()
-- once per session; if that first lookup ran before init it stays broken, so
-- fall back to the engine's own string->text converter for a fresh lookup.
local function toText(s)
    local ok, t = pcall(FText, s)
    if ok and t then return t end
    local converted = nil
    pcall(function()
        local ktl = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        if ktl and ktl:IsValid() then converted = ktl:Conv_StringToText(s) end
    end)
    return converted
end

-- Client-local message, used only for the important/rare cases (host has no
-- Palvolve, or a version mismatch). Prefers the non-modal HUD warning banner -
-- what the game itself uses for local warnings - and falls back to the
-- full-screen alert dialog if the HUD service is unavailable. The routine
-- "server runs Palvolve vX" confirmation is the host's own [SYSTEM] chat line,
-- so it is never duplicated here.
local function showLocalMessage(text)
    Log(text)
    pcall(function()
        local ctx = Role.localPlayerCtx()
        local pc = ctx and ctx.pc
        if not (pc and pc:IsValid()) then return end
        local util = StaticFindObject("/Script/Pal.Default__PalUtility")
        local ftext = toText(text)
        if not (util and ftext) then return end
        local shown = false
        pcall(function()
            local hud = util:GetHUDService(pc)
            if hud and hud:IsValid() then
                hud:ShowCommonWarning({
                    Message = ftext,
                    DisplayType = 0, -- EPalUICommonWarningType::Default
                    PreserveID = { A = 0, B = 0, C = 0, D = 0 },
                })
                shown = true
            end
        end)
        if not shown then
            pcall(function() util:Alert(pc, ftext) end)
        end
    end)
end

-- ------------------------------------------------------------- classification

local function kismet()
    local k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if k and k:IsValid() then return k end
    return nil
end

-- "LOCAL" (we own this world) or "CLIENT" (connected to a remote host). An
-- unreadable result biases to CLIENT on purpose: treating a real client as an
-- authority is the dangerous direction, while a misread single-player is caught
-- by the authority re-check at the timeout below.
local function classifyWorld(wc)
    local k = kismet()
    if not (k and wc) then return "CLIENT" end
    local standalone, isServer = nil, nil
    pcall(function() standalone = k:IsStandalone(wc) end)
    pcall(function() isServer = k:IsServer(wc) end)
    if standalone == true then return "LOCAL" end -- single-player
    if isServer == true then return "LOCAL" end   -- listen host
    return "CLIENT"
end

-- Settled authority read, used only at the timeout boundary: by then the
-- controller has definitely settled, so a flaky net-mode read at join time can
-- never end up disabling a world we own.
local function authorityNow()
    local auth = false
    pcall(function()
        local pc = Role.getLocalPlayerController()
        local k = kismet()
        if pc and pc:IsValid() and k then auth = k:IsServer(pc) end
    end)
    if auth then return true end
    return Role.hasWorldAuthority()
end

-- ------------------------------------------------------------------- settling

local function settleLocal()
    state = ST.LOCAL
    serverVersion = Config.modVersion
end

local function settleRemote(ver)
    -- accepted while resolving (the normal case) and out of ABSENT, so a greet
    -- that only makes it through after the timeout still rescues the session
    -- instead of forcing a relog. Any other state ignores duplicates.
    if state ~= ST.RESOLVING and state ~= ST.ABSENT then return end
    local recovered = (state == ST.ABSENT)
    state = ST.REMOTE
    serverVersion = ver
    if recovered then
        showLocalMessage(I18n.msg("serverPalvolveRestored"))
    end
    local mine = tostring(Config.modVersion)
    -- matching versions need no client message: the host already posted its own
    -- [SYSTEM] line. Only a mismatch is worth interrupting the player for.
    if ver and ver ~= "" and ver ~= mine then
        showLocalMessage(I18n.msg("serverVersionMismatch", ver, mine))
    end
end

local function settleAbsent()
    state = ST.ABSENT
    showLocalMessage(I18n.msg("serverNoPalvolve"))
end

-- -------------------------------------------------------------------- triggers

-- One-shot timeout for the resolving window. ExecuteWithDelay is forbidden
-- (UE4SS-LESSONS 1): a LoopAsync that returns true on its first fire is the safe
-- equivalent, and it costs a single transient callback ref instead of a poll.
local function armResolveTimeout(gen)
    local timeoutMs = (Config.serverCheck.timeoutSeconds or 10) * 1000
    LoopAsync(timeoutMs, function()
        if gen ~= generation or state ~= ST.RESOLVING then return true end
        ExecuteInGameThread(function()
            pcall(function()
                if gen ~= generation or state ~= ST.RESOLVING then return end
                if authorityNow() then
                    settleLocal() -- safety net: never disable a world we own
                else
                    settleAbsent()
                end
            end)
        end)
        return true
    end)
end

-- Called from the join hook when the LOCAL player's character finished
-- initializing, with that character as the world context. Every world entry
-- re-baselines from scratch, so nothing leaks from single-player into a server
-- (or between servers) later in the same session.
function ServerCheck.onEnterWorld(wc)
    if not (Config.serverCheck and Config.serverCheck.enabled) then return end
    generation = generation + 1
    local gen = generation
    serverVersion = nil
    local buffered = earlyPong
    earlyPong = nil

    if classifyWorld(wc) == "LOCAL" then
        settleLocal() -- single-player / listen host: instant, silent, never blocked
        return
    end
    state = ST.RESOLVING -- connected client: wait for the host's greet
    if buffered and (os.clock() - buffered.at) <= EARLY_PONG_MAX_AGE_S then
        settleRemote(buffered.ver) -- the greet already arrived during the join
        return
    end
    armResolveTimeout(gen)
end

-- Wired into NetChannel.initClient: the host's hidden greet carrying its version.
function ServerCheck.onPong(ver)
    Log("Handshake: host greet received (v" .. tostring(ver) .. ") while " .. state)
    if state == ST.IDLE then
        earlyPong = { ver = ver, at = os.clock() }
        return
    end
    settleRemote(ver)
end

function ServerCheck.init()
    if not (Config.serverCheck and Config.serverCheck.enabled) then
        state = ST.LOCAL -- feature off: never block anything
        return
    end
    state = ST.IDLE
    NetChannel.onLocalEnterWorld = ServerCheck.onEnterWorld
end

return ServerCheck
