-- Palvolve: Evolve your captured Pals into stronger related forms (Pengullet -> Penking),
-- keeping their full identity: level, passives, IVs, souls, condenser rank and learned moves.
local MOD_NAME = "Palvolve"

local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- Required line for the dev loop: tail-ue4ss-log waits for "[Palvolve] loaded"
Log("loaded")

-- Role detection: UI modules and their retry pollers must not run on a
-- dedicated server. Their endless LoopAsync+ExecuteInGameThread retries
-- (the hooked widgets never load headless) churn transient callback refs,
-- which UE4SS's callback GC occasionally frees while still scheduled -
-- observed as corrupted closures and silent server deaths.
local Role = require("role")
if Role.isDedicated() then
    Log("dedicated server detected: UI modules disabled")
end

-- Evolution core
local Evolution = nil
local okCore, errCore = pcall(function()
    Evolution = require("evolution")
    Evolution.init()
end)
if not okCore then
    Log("core failed to load: " .. tostring(errCore))
end

-- Radial menu integration (Evolve entry in the hold-4 wheel)
if Evolution and not Role.isDedicated() then
    local okRadial, errRadial = pcall(function()
        require("radialmenu").init({
            check = Evolution.check,
            canOffer = Evolution.canOffer,
            listOptions = Evolution.listOptions,
            executeOption = Evolution.executeOption,
        })
    end)
    if not okRadial then
        Log("radial menu integration failed to load: " .. tostring(errRadial))
    end
end

-- Egg filter (config-gated inside)
local okEgg, errEgg = pcall(function()
    require("eggfilter").init()
end)
if not okEgg then
    Log("egg filter failed to load: " .. tostring(errEgg))
end

-- Pal Alchemy Workbench visual (teal tint on the reused medicine bench)
if not Role.isDedicated() then
    local okBench, errBench = pcall(function()
        require("benchvisual").init()
    end)
    if not okBench then
        Log("bench visual failed to load: " .. tostring(errBench))
    end
end

-- Pal Alchemy Workbench recipe filter (per-instance converter target patch)
local okFilter, errFilter = pcall(function()
    require("benchfilter").init()
end)
if not okFilter then
    Log("bench filter failed to load: " .. tostring(errFilter))
end

-- Dev probes (devMode only; set devMode=false before release and do not package probes.lua)
local okCfg, cfg = pcall(require, "config")
if okCfg and cfg.devMode then
    local okProbes, errProbes = pcall(require, "probes")
    if not okProbes then
        Log("probes failed to load: " .. tostring(errProbes))
    end
end
