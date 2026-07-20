-- Palvolve ready-to-evolve glow: uses Palworld's own native, toggleable
-- outline visual effect (VisualEffectComponent:AddVisualEffect) on the
-- summoned Pal while it has at least one evolution available RIGHT NOW.
-- Client-side cosmetic only.
--
-- DELIBERATELY a single on/off toggle, no blinking, no repeating timer of
-- any kind. Every flashing design tried was eventually implicated in real
-- crashes during Evolve menu use, across several different failure
-- signatures. This plain toggle is the one version proven stable through
-- extensive testing, including combat and menu use - it's the known-safe
-- baseline. No combat-specific handling is needed: with no blink to
-- interrupt, the effect is already just "on" while ready, in or out of
-- combat.
--
-- Effect IDs are from Palworld's own EPalVisualEffectID enum:
-- 6 = PalOutlineFadeIn, 7 = PalOutlineFadeOut.

local Role = require("role")
local NeverEvolve = require("neverevolve")

local ReadyGlow = {}

local POLL_MS        = 2000
local START_DELAY_MS = 12000
local EFFECT_ON  = 6   -- PalOutlineFadeIn
local EFFECT_OFF = 7   -- PalOutlineFadeOut

local function Log(msg)
    print(string.format("[Palvolve] readyglow: %s\n", msg))
end

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

local Evolution = nil
local trackedKey = nil
local trackedActor = nil
local currentOn = nil

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
        if trackedActor and currentOn then setVisualEffect(trackedActor, false) end
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

    if ready == true and currentOn ~= true then
        setVisualEffect(actor, true)
        currentOn = true
        Log("effect ON")
    elseif ready ~= true and currentOn ~= false then
        setVisualEffect(actor, false)
        currentOn = false
        Log("effect OFF")
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