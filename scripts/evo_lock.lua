-- Palvolve sequence lock: whether an evolution is running, its time budget, and
-- the heartbeat that tells whether the game-thread timers still run.

local GameLoop = require("gameloop")
local I18n = require("i18n")
local Role = require("role")

local EvoLock = {}

local MOD_NAME = "Palvolve"
local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- Global sequence lock: never two evolutions in parallel. A watchdog aborts a
-- stuck sequence once its per-run budget (derived from the configured phase
-- timings) has elapsed, in case an error path ever leaks the lock.
EvoLock.sequenceRunning = false
EvoLock.sequenceStartedAt = 0
EvoLock.sequenceBudgetS = 30
EvoLock.currentAbort = nil
-- Heartbeat for the mod's own timers. Every timed step runs on a game-thread
-- loop UE4SS schedules for the mod (gameloop.lua). When those were LoopAsync
-- loops, one callback reference garbage collected while still scheduled ("Ref
-- was not function") removed UE4SS's Lua tick hook, and from then on nothing
-- timed happened: an evolution that is mid-flight never reaches its next
-- phase, the Pal stays hidden and the stone is already spent, with no line in
-- the log to say why. The beat runs on the same mechanism as every timed step,
-- so it goes quiet with them. Hooks keep firing though, so anything
-- hook-driven can still notice the silence.
EvoLock.lastBeat = os.clock()
EvoLock.lastTimersNotice = -1000
GameLoop.start(1000, function()
    EvoLock.lastBeat = os.clock()
    return false
end, "heartbeat")
-- Deliberately generous: five missed beats, so a loading screen or a frame
-- spike is never mistaken for a dead tick.
local function timersDead()
    return (os.clock() - EvoLock.lastBeat) > 5
end
-- Long past any stall a running process can produce, so this one is safe to
-- act on: starting an evolution here would take the cost and then stop at the
-- first timed step, leaving the player a hidden Pal and a spent stone.
local function timersGone()
    return (os.clock() - EvoLock.lastBeat) > 15
end
-- Said from both entry points, at most twice a minute: the state does not heal
-- on its own, so repeating it on every press would bury the chat.
local function reportDeadTimers(playerCtx)
    if (os.clock() - EvoLock.lastTimersNotice) <= 30 then return end
    EvoLock.lastTimersNotice = os.clock()
    Log("the timers are not running: UE4SS removed this mod's Lua tick hook, "
        .. "so no timed step of the mod happens any more. A game restart brings them back.")
    -- A reply, not a notice: both callers are the player reaching for evolution
    -- and getting nothing back. Silenced, the key and the wheel entry would just
    -- stop working with no reason given.
    Role.chat(playerCtx or Role.localPlayerCtx(), I18n.msg("timersDead"), "reply")
end
-- Frees a stuck lock (budget exceeded); returns true while the lock is busy.
local function lockBusy()
    if not EvoLock.sequenceRunning then return false end
    if timersDead() then
        Log("the timers stopped while an evolution was running, so the sequence "
            .. "cannot finish: UE4SS removed this mod's Lua tick hook, which is "
            .. "what delivers every timed step. Aborting the run; the cost comes "
            .. "back unless the species swap already went through.")
        if EvoLock.currentAbort then pcall(EvoLock.currentAbort) else EvoLock.sequenceRunning = false end
        return EvoLock.sequenceRunning
    end
    if (os.clock() - EvoLock.sequenceStartedAt) > EvoLock.sequenceBudgetS then
        Log("Sequence lock stuck - watchdog aborting the sequence")
        if EvoLock.currentAbort then pcall(EvoLock.currentAbort) else EvoLock.sequenceRunning = false end
        return EvoLock.sequenceRunning
    end
    return true
end

EvoLock.timersDead = timersDead
EvoLock.timersGone = timersGone
EvoLock.reportDeadTimers = reportDeadTimers
EvoLock.lockBusy = lockBusy

return EvoLock
