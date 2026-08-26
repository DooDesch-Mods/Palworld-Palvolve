-- Palvolve sequence timing: the ONE place that decides how long a run takes.
--
-- The phase lengths used to be read twice, by digimonCfg() in fx.lua for the
-- animation and by timings() in finale.lua for the effect schedule. Two readers
-- of the same numbers is one reader too many: the moment prestige wants its own
-- lengths, the two can disagree and the schedule drifts against the animation
-- with nothing to show for it in any log.
--
-- So it is resolved ONCE per run, as soon as the stage is known, and everything
-- downstream reads ctx.timing. Nothing reads Config.digimon on its own any more.
--
-- Prestige runs longer than an evolution, and later stages run longer than
-- earlier ones. A single prestige length would leave stage 1 padded or force
-- stage 10 to spend its extra weight on more particles instead of more time.

local Config = require("config")

local Timing = {}

-- Endpoints of the prestige ramp. Stage 1 sits just past an evolution, stage 10
-- earns twenty seconds. Everything between is interpolated.
local PRESTIGE_FIRST = { spinUpMs = 3200, shrinkMs = 2600, growMs = 3700, finaleHoldMs = 4000 }
local PRESTIGE_LAST  = { spinUpMs = 4800, shrinkMs = 3700, growMs = 5200, finaleHoldMs = 6300 }
local PRESTIGE_MAX_STAGE = 10

local function round100(v)
    return math.floor(v / 100 + 0.5) * 100
end

local function lerpMs(first, last, t)
    return round100(first + (last - first) * t)
end

--- The evolution lengths, straight from the shipped config.
local function evolutionPhases()
    local c = Config.digimon or {}
    return {
        spinUpMs = math.max(c.spinUpMs or 1200, 1),
        shrinkMs = math.max(c.shrinkMs or 1200, 1),
        growMs = math.max(c.growMs or 1600, 1),
        finaleHoldMs = math.max(c.finaleHoldMs or 1800, 0),
        peakDegPerSec = math.max(c.peakDegPerSec or 1080, 0),
    }
end

local function prestigePhases(stage)
    local n = math.max(1, math.min(math.floor(tonumber(stage) or 1), PRESTIGE_MAX_STAGE))
    local t = (n - 1) / (PRESTIGE_MAX_STAGE - 1)
    local c = Config.digimon or {}
    return {
        spinUpMs = lerpMs(PRESTIGE_FIRST.spinUpMs, PRESTIGE_LAST.spinUpMs, t),
        shrinkMs = lerpMs(PRESTIGE_FIRST.shrinkMs, PRESTIGE_LAST.shrinkMs, t),
        growMs = lerpMs(PRESTIGE_FIRST.growMs, PRESTIGE_LAST.growMs, t),
        finaleHoldMs = lerpMs(PRESTIGE_FIRST.finaleHoldMs, PRESTIGE_LAST.finaleHoldMs, t),
        -- the spin speed is not part of the ramp: it is a look, not a length
        peakDegPerSec = math.max(c.peakDegPerSec or 1080, 0),
    }
end

--- Resolves the complete timing of one run.
---
--- @param isPrestige boolean
--- @param stage number|nil prestige stage, 1 when unknown
--- @return table immutable timing, in milliseconds unless the name says otherwise
function Timing.resolve(isPrestige, stage)
    local phases = isPrestige and prestigePhases(stage) or evolutionPhases()

    local dissolveMs = phases.spinUpMs + phases.shrinkMs
    local revealTotalMs = phases.growMs + phases.finaleHoldMs

    -- The quiet tail: the stretch after the last effect, in which the pal steers
    -- back into its facing and the presentation lands. It grows with the hold,
    -- so a longer run ends calmly instead of ending abruptly later.
    local alignMs = math.min(800, phases.finaleHoldMs * 0.4)
    local quietLeadMs = 300
    if isPrestige then
        alignMs = math.min(1600, phases.finaleHoldMs * 0.25)
        quietLeadMs = round100(300 + 600 * ((math.max(1, math.min(tonumber(stage) or 1,
            PRESTIGE_MAX_STAGE)) - 1) / (PRESTIGE_MAX_STAGE - 1)))
    end

    return {
        isPrestige = isPrestige and true or false,
        stage = isPrestige and (tonumber(stage) or 1) or nil,

        spinUpMs = phases.spinUpMs,
        shrinkMs = phases.shrinkMs,
        growMs = phases.growMs,
        finaleHoldMs = phases.finaleHoldMs,
        peakDegPerSec = phases.peakDegPerSec,

        dissolveMs = dissolveMs,
        revealTotalMs = revealTotalMs,
        fullPresentationMs = dissolveMs + revealTotalMs,

        alignMs = alignMs,
        quietLeadMs = quietLeadMs,
        -- measured from the reveal, like every anchor in the schedule
        quietCutoffMs = revealTotalMs - alignMs - quietLeadMs,
    }
end

--- The timing a context should use, resolved once and then reused. Callers that
--- have no context at all (a standalone preview of a single beat) get the
--- evolution timing, which is the shortest and therefore the safest default.
function Timing.forContext(ctx)
    if type(ctx) ~= "table" then return Timing.resolve(false, nil) end
    if not ctx.timing then
        ctx.timing = Timing.resolve(ctx.isPrestige == true, ctx.prestigeStage)
    end
    return ctx.timing
end

return Timing
