-- Palvolve: Evolve your captured Pals into stronger related forms (Pengullet -> Penking),
-- keeping their full identity: level, passives, IVs, souls, condenser rank and learned moves.
local MOD_NAME = "Palvolve"

local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- Pflicht-Zeile fuer den Dev-Loop: tail-ue4ss-log prueft auf "[Palvolve] loaded"
Log("loaded")

-- Evolutions-Kern
local okCore, errCore = pcall(function()
    require("evolution").init()
end)
if not okCore then
    Log("Kern nicht geladen: " .. tostring(errCore))
end

-- Dev-Proben (temporaer, vor Release entfernen)
local okProbes, errProbes = pcall(require, "probes")
if not okProbes then
    Log("Proben nicht geladen: " .. tostring(errProbes))
end
