-- Palvolve faint tracker for the faintedAgo condition. The game keeps no record
-- of when a Pal last fainted, only whether it is fainted right now, so this
-- module polls every party slot of every player controller the process can see
-- and remembers the last moment each individual was down. Session only: a
-- restart forgets every faint.
--
-- A fainted party Pal stays dead until its revive timer runs out or it goes into
-- the Palbox, which takes far longer than one poll, so a faint is never missed
-- by the interval. The poll only starts once a pair asks for faintedAgo; a
-- config without it costs nothing.

local GameLoop = require("gameloop")

local FaintWatch = {}

local POLL_MS = 3000
-- FindAllOf walks every object in the game, so the controller list is only
-- rebuilt every few polls. A player who just joined waits at most this long.
local CONTROLLER_REFRESH_POLLS = 10

local lastFaintAt = {}
local controllers = {}
local pollsSinceRefresh = CONTROLLER_REFRESH_POLLS
local holderClass = nil
local started = false
local lastError = nil

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local function individualKeyUnsafe(param)
    local g = param.IndividualId.InstanceId
    return string.format("%08X-%08X-%08X-%08X", g.A, g.B, g.C, g.D)
end

local function individualKey(param)
    local ok, key = pcall(individualKeyUnsafe, param)
    if not ok or key == "00000000-00000000-00000000-00000000" then return nil end
    return key
end

local function isDeadUnsafe(param)
    return param:IsDead() == true
end

local function holderOfUnsafe(pc)
    if not (holderClass and holderClass:IsValid()) then
        holderClass = StaticFindObject("/Script/Pal.PalOtomoHolderComponentBase")
    end
    if not (holderClass and holderClass:IsValid()) then error("holder class not found") end
    local holder = pc:GetComponentByClass(holderClass)
    if holder and holder:IsValid() then return holder end
    return nil
end

local function scanControllerUnsafe(pc, now)
    if not pc:IsValid() then return end
    local holder = holderOfUnsafe(pc)
    if not holder then return end
    local n = holder:GetMaxOtomoNum()
    for i = 0, n - 1 do
        local handle = holder:GetOtomoIndividualHandle(i)
        if handle and handle:IsValid() then
            local param = handle:TryGetIndividualParameter()
            if param and param:IsValid() and param:IsDead() then
                local key = individualKey(param)
                if key then
                    if lastFaintAt[key] == nil then Log("faint tracker: Pal " .. key .. " fainted") end
                    lastFaintAt[key] = now
                end
            end
        end
    end
end

local function pollUnsafe()
    pollsSinceRefresh = pollsSinceRefresh + 1
    if pollsSinceRefresh >= CONTROLLER_REFRESH_POLLS then
        pollsSinceRefresh = 0
        controllers = FindAllOf("PalPlayerController") or {}
    end
    local now = os.time()
    for _, pc in ipairs(controllers) do
        local ok, err = pcall(scanControllerUnsafe, pc, now)
        if not ok then
            -- once per distinct message, the poll repeats every few seconds
            local reason = tostring(err)
            if reason ~= lastError then
                lastError = reason
                Log("[WARN] faint tracker: party scan failed: " .. reason)
            end
        end
    end
end

--- Never returns true: the tracker runs for the rest of the session.
local function poll()
    local ok, err = pcall(pollUnsafe)
    if not ok then
        local reason = tostring(err)
        if reason ~= lastError then
            lastError = reason
            Log("[WARN] faint tracker: poll failed: " .. reason)
        end
    end
    return false
end

--- Starts the poll once. Safe to call from any game-thread path.
function FaintWatch.ensureStarted()
    if started then return true end
    started = GameLoop.start(POLL_MS, poll, "faint tracker") ~= nil
    if started then
        Log("faint tracker started")
    else
        Log("[ERROR] faint tracker failed to start")
    end
    return started
end

--- Minutes since this Pal last fainted in this session: 0 while it is down,
--- math.huge when it never fainted, nil when the Pal or the tracker cannot be
--- read.
function FaintWatch.minutesSince(param)
    if not FaintWatch.ensureStarted() then return nil end
    local key = individualKey(param)
    if not key then return nil end
    local okDead, dead = pcall(isDeadUnsafe, param)
    if okDead and dead then
        lastFaintAt[key] = os.time()
        return 0
    end
    local at = lastFaintAt[key]
    if not at then return math.huge end
    return math.max(0, os.difftime(os.time(), at)) / 60
end

return FaintWatch
