-- Palvolve: Evolve your captured Pals into stronger related forms (Pengullet -> Penking),
-- keeping their full identity: level, passives, IVs, souls, condenser rank and learned moves.
local MOD_NAME = "Palvolve"

local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- Required line for the dev loop: tail-ue4ss-log waits for "[Palvolve] loaded"
Log("loaded")

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
if Evolution then
    local okRadial, errRadial = pcall(function()
        require("radialmenu").init(Evolution.check, Evolution.isArmed)
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

-- Dev probes (devMode only; set devMode=false before release and do not package probes.lua)
local okCfg, cfg = pcall(require, "config")
if okCfg and cfg.devMode then
    local okProbes, errProbes = pcall(require, "probes")
    if not okProbes then
        Log("probes failed to load: " .. tostring(errProbes))
    end
end
