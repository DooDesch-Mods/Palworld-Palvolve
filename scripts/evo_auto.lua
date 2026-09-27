-- Palvolve auto-evolve watcher: scans every player's summoned Pal and starts an
-- evolution once exactly one path is ready.

local Conditions = require("conditions")
local Config = require("config")
local Costs = require("costs")
local GameLoop = require("gameloop")
local I18n = require("i18n")
local Role = require("role")
local EvoUtil = require("evo_util")
local EvoNames = require("evo_names")
local EvoState = require("evo_state")
local EvoLock = require("evo_lock")

local EvoAuto = {}

local MOD_NAME = "Palvolve"
local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- F2 is defined before the indexed authority handler below, but it must enter
-- that same pipeline rather than capture a pair table from the arm step.
EvoAuto.handleEvolveByIndex = nil
EvoAuto.handlePrestigeByIndex = nil
-- The scheduler wakes cheaply on the game thread (gameloop.lua) and only scans
-- when the adaptive deadline arrives, which still allows a half-second
-- condition window near a completed rule set.
local AUTO_SLOW_S = 5.0
local AUTO_FAST_S = 0.5
local AUTO_SCHEDULER_MS = 250
EvoAuto.autoWatchNextAt = 0
local autoOwnershipSkipped = {}
-- Pals already told "two ways are open", so a timer that runs every few seconds
-- does not repeat one line into the chat forever.
local autoHeldTold = {}
local function autoDelayFor(met, total)
    if not total or total <= 0 then return AUTO_SLOW_S end
    local ratio = math.max(0, math.min(1, (tonumber(met) or 0) / total))
    return AUTO_SLOW_S - ((AUTO_SLOW_S - AUTO_FAST_S) * ratio)
end
local function autoCostPasses(playerCtx, pair, level, holder)
    local costList = Costs.resolve(pair, level, holder)
    return Costs.check(playerCtx, costList) == true
end
-- Runs under pcall from scanAutoController. Every direct UObject call in this
-- hot path is therefore inside one named protected callback, with no closure
-- allocated for each controller or condition poll.
local function scanAutoControllerUnsafe(pc)
    if not (pc and pc:IsValid() and pc:HasAuthority()) then return AUTO_SLOW_S, false end
    if pc:IsRiding() == true then return AUTO_SLOW_S, false end

    local playerCtx = Role.playerCtxFor(pc)
    if not playerCtx then return AUTO_SLOW_S, false end
    if not (EvoUtil.otomoHolderClass and EvoUtil.otomoHolderClass:IsValid()) then
        EvoUtil.otomoHolderClass = StaticFindObject("/Script/Pal.PalOtomoHolderComponentBase")
    end
    if not EvoUtil.otomoHolderClass then return AUTO_SLOW_S, false end
    local holder = pc:GetComponentByClass(EvoUtil.otomoHolderClass)
    if not (holder and holder:IsValid()) then return AUTO_SLOW_S, false end
    local actor = holder:TryGetSpawnedOtomo()
    if not (actor and actor:IsValid()) then return AUTO_SLOW_S, false end
    local param = actor.CharacterParameterComponent:GetIndividualParameter()
    if not (param and param:IsValid()) then return AUTO_SLOW_S, false end

    local owner = param.SaveParameter.OwnerPlayerUId
    local uid = playerCtx.playerUId
    if not uid or (owner.A == 0 and owner.B == 0 and owner.C == 0 and owner.D == 0)
        or not (owner.A == uid.A and owner.B == uid.B
            and owner.C == uid.C and owner.D == uid.D) then
        local palKey = EvoUtil.guidString(param.IndividualId.InstanceId)
        if not autoOwnershipSkipped[palKey] then
            autoOwnershipSkipped[palKey] = true
            Log("auto-evolve skipped: the summoned Pal's recorded owner does not match its holder")
        end
        return AUTO_SLOW_S, false
    end

    local id, isAlpha = EvoUtil.baseCharacterId(param:GetCharacterID():ToString())
    local level = tonumber(param:GetLevel()) or 0
    local pairList = EvoState.optionPairsFor(id, param)
    local bestIndex, bestIsPrestige = nil, false
    local nextDelay = AUTO_SLOW_S
    local condCtx = { actor = actor, param = param, playerCtx = playerCtx, holder = holder }

    -- A Pal the player has locked is left alone entirely: no scan, no unlock.
    if EvoState.AutoLock.isLocked(param) then return AUTO_SLOW_S, false end
    -- Nor is a fused one: it goes back to being two Pals when the fusion ends.
    local okFusion, Fusion = pcall(require, "fusion")
    if okFusion and Fusion.isFused(param) then return AUTO_SLOW_S, false end

    -- EVERY ready candidate is collected, not the first one. The old loop broke
    -- out on the first match in `selected` mode, so which of several possible
    -- evolutions fired came down to their order in the config - an order nobody
    -- sets on purpose and the editor does not show.
    local ready = {}
    for i, pair in ipairs(pairList) do
        if pair.autoEvolve == true and not EvoUtil.unknownConditionReason(pair)
            and level >= EvoState.requiredLevelFor(pair, param)
            and not (isAlpha and not EvoUtil.swapTargetId(pair, true)) then
            local met, total = Conditions.progress(pair, condCtx)
            nextDelay = math.min(nextDelay, autoDelayFor(met, total))
            if met == total then
                local okCost, affordable = pcall(autoCostPasses,
                    playerCtx, pair, level, holder)
                if okCost and affordable then
                    ready[#ready + 1] = {
                        index = EvoState.pairIndexFor(pair, i),
                        pair = pair,
                    }
                end
            end
        end
    end

    -- More than one way is open at this very moment, so nothing fires on its
    -- own: picking for the player is how a Pal ends up as the form they did not
    -- want. Each of them is unlocked instead, which makes it available from the
    -- wheel from now on - the point being that most conditions are transient,
    -- and "electrified" is otherwise only reachable if the player happens to be
    -- at the wheel in that second.
    if #ready > 1 then
        for _, entry in ipairs(ready) do
            EvoState.AutoUnlock.remember(param, entry.pair)
        end
        -- Nothing happening is the whole point here, and nothing happening is
        -- indistinguishable from the feature never running. Both the player and
        -- the log are told, or the next report is "auto-evolve does nothing".
        -- Once per Pal per stretch, not once per scan: this runs on a timer.
        local heldKey = EvoUtil.guidString(param.IndividualId.InstanceId)
        if not autoHeldTold[heldKey] then
            autoHeldTold[heldKey] = true
            Log(string.format("auto-evolve held: '%s' has %d ways open at once", id, #ready))
            Role.chat(playerCtx, I18n.msg("autoEvolveHeld", EvoNames.palDisplayName(id)))
        end
        return nextDelay, false
    end
    if #ready == 1 then
        -- Cleared here and nowhere else. A condition that lapses puts the Pal
        -- back at nothing-to-do, and clearing there would let a pair of
        -- flickering conditions re-announce the same hold every few seconds.
        -- One evolution is the event that makes the next hold a new one.
        autoHeldTold[EvoUtil.guidString(param.IndividualId.InstanceId)] = nil
        bestIndex = ready[1].index
        bestIsPrestige = EvoState.isPrestigePair(ready[1].pair)
    end

    if bestIndex then
        local started
        if bestIsPrestige then
            started = EvoAuto.handlePrestigeByIndex(playerCtx, bestIndex)
        else
            started = EvoAuto.handleEvolveByIndex(playerCtx, bestIndex)
        end
        return nextDelay, started == true
    end
    return nextDelay, false
end
-- One line per distinct failure and never again, not one per scan: this runs
-- every few hundred milliseconds per player, so an unfiltered log would bury
-- everything else. Silence is not the alternative - a scan that throws on its
-- first call looks exactly like a scan that never finds anything ready.
local autoScanFailures = {}
local function scanAutoController(pc)
    local ok, delay, started = pcall(scanAutoControllerUnsafe, pc)
    if not ok then
        local reason = tostring(delay)
        if not autoScanFailures[reason] then
            autoScanFailures[reason] = true
            Log("auto-evolve scan failed: " .. reason)
        end
        return AUTO_SLOW_S, false
    end
    return delay or AUTO_SLOW_S, started == true
end
local function runAutoWatcherUnsafe()
    local nextDelay = AUTO_SLOW_S
    if not Config.autoEvolve or EvoLock.sequenceRunning then
        EvoAuto.autoWatchNextAt = os.clock() + nextDelay
        return
    end
    local controllers = FindAllOf("PalPlayerController") or {}
    for _, pc in ipairs(controllers) do
        local delay, started = scanAutoController(pc)
        nextDelay = math.min(nextDelay, delay)
        if started then break end
    end
    EvoAuto.autoWatchNextAt = os.clock() + nextDelay
end
local function runAutoWatcher()
    local ok, err = pcall(runAutoWatcherUnsafe)
    if not ok then
        EvoAuto.autoWatchNextAt = os.clock() + AUTO_SLOW_S
        -- once per distinct failure, like the scan above: this retries every
        -- five seconds
        local reason = tostring(err)
        if Config.devMode or not autoScanFailures[reason] then
            autoScanFailures[reason] = true
            Log("auto-evolve watcher failed: " .. reason)
        end
    end
end
local function autoWatcherLoop()
    if os.clock() < EvoAuto.autoWatchNextAt then return false end
    runAutoWatcher()
    return false
end
local function startAutoWatcher()
    if not Config.autoEvolve then return end
    EvoAuto.autoWatchNextAt = 0
    if not GameLoop.start(AUTO_SCHEDULER_MS, autoWatcherLoop, "auto-evolve watcher") then
        Log("auto-evolve watcher failed to start")
    end
end

EvoAuto.AUTO_SLOW_S = AUTO_SLOW_S
EvoAuto.AUTO_FAST_S = AUTO_FAST_S
EvoAuto.AUTO_SCHEDULER_MS = AUTO_SCHEDULER_MS
EvoAuto.autoOwnershipSkipped = autoOwnershipSkipped
EvoAuto.autoHeldTold = autoHeldTold
EvoAuto.autoDelayFor = autoDelayFor
EvoAuto.autoCostPasses = autoCostPasses
EvoAuto.scanAutoControllerUnsafe = scanAutoControllerUnsafe
EvoAuto.autoScanFailures = autoScanFailures
EvoAuto.scanAutoController = scanAutoController
EvoAuto.runAutoWatcherUnsafe = runAutoWatcherUnsafe
EvoAuto.runAutoWatcher = runAutoWatcher
EvoAuto.autoWatcherLoop = autoWatcherLoop
EvoAuto.startAutoWatcher = startAutoWatcher

return EvoAuto
