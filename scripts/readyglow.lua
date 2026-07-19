-- Palvolve ready-to-evolve glow: uses Palworld's own native, toggleable
-- outline visual effect (VisualEffectComponent:AddVisualEffect) as a
-- periodic double-blink accent while a Pal has at least one evolution
-- available RIGHT NOW. Client-side cosmetic only.
--
-- Baseline is UNHIGHLIGHTED. The Pal is never left glowing steadily -
-- becoming "ready" starts the blink schedule but does not turn the effect
-- on by itself, and every blink burst ends back at unhighlighted. This is
-- deliberate: a steady highlight read as "in combat" to players, which was
-- confusing.
--
-- Effect IDs are from Palworld's own EPalVisualEffectID enum:
-- 6 = PalOutlineFadeIn, 7 = PalOutlineFadeOut.
--
-- Blink scheduling piggybacks on the existing 2s poll (using os.time(),
-- real wall-clock seconds, not the os.clock() CPU-time measure that caused
-- an earlier bug). Each blink burst is a short chain of one-shot delayed
-- calls (LoopAsync returning true = fire once), not a fast-ticking counter,
-- so each phase can have its own duration and nothing runs continuously in
-- the background beyond the trusted 2s poll.

local Role = require("role")
local NeverEvolve = require("neverevolve")
local Conditions = require("conditions")

local ReadyGlow = {}
local COMBAT_GATE = { conditions = { "inCombat" } }

local POLL_MS         = 2000
local START_DELAY_MS  = 12000
local EFFECT_ON  = 6   -- PalOutlineFadeIn
local EFFECT_OFF = 7   -- PalOutlineFadeOut

local BLINK_INTERVAL_S = 4     -- wall-clock seconds between blink bursts
local BLINK_FLASH_MS   = 500   -- how long each individual flash stays lit
local BLINK_GAP_MS     = 900   -- pause between the two flashes in a burst
local TICK_MS = 100

-- The burst: flash on, pause (off), flash on again, then settle back to
-- unhighlighted. waitMs is how long to hold AFTER setting `on`.
local BLINK_STEPS = {
    { on = true,  ticks = math.ceil(BLINK_FLASH_MS / TICK_MS) },
    { on = false, ticks = math.ceil(BLINK_GAP_MS   / TICK_MS) },
    { on = true,  ticks = math.ceil(BLINK_FLASH_MS / TICK_MS) },
    { on = false, ticks = 1 },
}

local function Log(msg)
    print(string.format("[Palvolve] readyglow: %s\n", msg))
end

-- ---------------------------------------------------------------- effect

local function setVisualEffect(actor, on)
    if not (actor and actor:IsValid()) then return end
    if not (actor.VisualEffectComponent and actor.VisualEffectComponent:IsValid()) then return end
    pcall(function()
        actor.VisualEffectComponent:AddVisualEffect(on and EFFECT_ON or EFFECT_OFF, { FloatValues = {} })
    end)
end

local function clearLegacyOverlay(actor)
    pcall(function()
        if actor and actor:IsValid() then actor:GetMainMesh():SetOverlayMaterial(nil) end
    end)
end

-- ---------------------------------------------------------------- blink burst

local blinkState = nil

local function runBlink(actor)
    if blinkState and not blinkState.stopped then return end
    local state = { actor = actor, stopped = false, stepIndex = 1, ticksInStep = 0, applied = false }
    blinkState = state

    -- ONE persistent registration for the whole burst - never re-registered
    -- mid-sequence. Chaining fresh one-shot LoopAsync calls (the previous
    -- design) creates exactly the short-lived "transient callback ref"
    -- this codebase already documents as vulnerable to UE4SS's callback GC
    -- ("Ref was not function... removing hook!", confirmed in a real log).
    LoopAsync(TICK_MS, function()
        if state.stopped or state ~= blinkState then return true end
        pcall(function()
            ExecuteInGameThread(function()
                if state.stopped or state ~= blinkState then return end
                if not (state.actor and state.actor:IsValid()) then
                    state.stopped = true
                    return
                end
                local step = BLINK_STEPS[state.stepIndex]
                if not step then
                    state.stopped = true
                    return
                end
                if not state.applied then
                    setVisualEffect(state.actor, step.on)
                    state.applied = true
                end
                state.ticksInStep = state.ticksInStep + 1
                if state.ticksInStep >= step.ticks then
                    state.stepIndex = state.stepIndex + 1
                    state.ticksInStep = 0
                    state.applied = false
                    if state.stepIndex > #BLINK_STEPS then
                        state.stopped = true
                    end
                end
            end)
        end)
        return false
    end)
end

-- ---------------------------------------------------------------- poll

local Evolution = nil
local trackedKey = nil
local trackedActor = nil
local currentOn = nil
local lastBlinkAt = 0

local function readinessFromCore()
    if not (Evolution and Evolution.canOffer and Evolution.listOptions) then return nil end
    if not Evolution.canOffer() then return false end
    local opts = Evolution.listOptions()
    if type(opts) ~= "table" then return nil end
    for _, o in ipairs(opts) do
        if not o.blocked then return true end
    end
    return false
end

local function pollOnce()
    local playerCtx = Role.localPlayerCtx()
    if not playerCtx then return end
    local actor, param = NeverEvolve.summoned(playerCtx)
    local key = param and NeverEvolve.keyFor(param) or nil

    if key ~= trackedKey then
        if blinkState then blinkState.stopped = true end
        if trackedActor then setVisualEffect(trackedActor, false) end  -- defensive: never leave a stray highlight
        trackedKey, trackedActor, currentOn = key, actor, nil
        if actor then clearLegacyOverlay(actor) end
    else
        trackedActor = actor or trackedActor
    end

    if not actor then return end

    local ready
    if param and NeverEvolve.isBlocked(param) then
        ready = false
    else
        ready = readinessFromCore()
    end

     if ready == true then
        local inCombat = Conditions.evaluate(COMBAT_GATE, { playerCtx = playerCtx }) == true
        if inCombat then
            if currentOn ~= "combat" then
                if blinkState then blinkState.stopped = true end
                setVisualEffect(actor, true)
                currentOn = "combat"
                Log("ready but in combat (highlight on)")
            end
        else
            if currentOn ~= true then
                -- became ready (or combat just ended): unhighlighted, arm the blink schedule
                currentOn = true
                lastBlinkAt = os.time()
                Log("ready (unhighlighted; first blink in " .. BLINK_INTERVAL_S .. "s)")
            elseif (os.time() - lastBlinkAt) >= BLINK_INTERVAL_S and (not blinkState or blinkState.stopped) then
                lastBlinkAt = os.time()
                runBlink(actor)
            end
        end
    else
        if currentOn ~= false then
            if blinkState then blinkState.stopped = true end
            setVisualEffect(actor, false)
            currentOn = false
            Log("not ready (unhighlighted)")
        end
    end
end

function ReadyGlow.init()
    local okEvo, evo = pcall(require, "evolution")
    if okEvo then Evolution = evo end
    if not (Evolution and Evolution.listOptions) then
        Log("evolution core unavailable; glow disabled")
        return
    end
    ExecuteWithDelay(START_DELAY_MS, function()
        LoopAsync(POLL_MS, function()
            ExecuteInGameThread(function()
                local ok, err = pcall(pollOnce)
                if not ok then Log("poll error: " .. tostring(err)) end
            end)
            return false
        end)
    end)
    Log("active (poll " .. POLL_MS .. "ms)")
end

return ReadyGlow