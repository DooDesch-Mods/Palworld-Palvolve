-- Palvolve: Evolve your captured Pals into stronger related forms (Pengullet -> Penking),
-- keeping their full identity: level, passives, IVs, souls, condenser rank and learned moves.
local MOD_NAME = "Palvolve"

local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- Startup marker; external tooling waits for this exact line
Log("loaded")

-- Version banner: records the running mod version in the log next to UE4SS's
-- and PalSchema's own banners, so a support log (server or client) identifies
-- the build at a glance. Its own line, so the "loaded" marker above stays
-- exactly as external tooling expects.
do
    local okVer, cfg = pcall(require, "config")
    if okVer and cfg and cfg.modVersion then
        Log("version " .. tostring(cfg.modVersion)
            .. " (game build " .. tostring(cfg.gameBuild) .. ")")
    end
end

-- Install check for the native companion. Its bindings are registered before any
-- Lua mod runs, so a missing global here means the dll is not loaded at all -
-- worth one line, because everything it does fails quietly rather than loudly.
if type(PalvolveNative_SetWorkSuitability) ~= "function"
    and type(PalvolveNative_UnlockCaptureRecord) ~= "function" then
    Log("the native companion did not load: dlls\\main.dll is missing or blocked. Evolving "
        .. "still works, but work suitability and the catch record of the new form do not update")
end

-- Role detection: UI modules and their retry pollers must not run on a
-- dedicated server. Their endless LoopAsync+ExecuteInGameThread retries
-- (the hooked widgets never load headless) churn transient callback refs,
-- which UE4SS's callback GC occasionally frees while still scheduled -
-- observed as corrupted closures and silent server deaths.
local Role = require("role")
if Role.isDedicated() then
    Log("dedicated server detected: UI modules disabled")
end

-- No poller here on purpose. A one second LoopAsync that asked the engine for
-- the role during world startup killed the dedicated server on the first try:
-- the log ends on the line the probe itself wrote, with a minidump next to it.
-- That is the hazard the comment above describes, and the mod is not allowed to
-- add one for its own convenience.
--
-- The role resolves on first use instead. That is late enough to be safe and
-- early enough to matter: everything that depends on it runs after a world
-- exists anyway.

-- Workbench unlock stage: PalSchema data, so this only writes the file and the
-- new stage applies on the next start. Runs on every launch, which also repairs
-- the value after a Workshop update replaced the PalSchema folder.
do
    local okTech, errTech = pcall(function() require("techlevel").apply() end)
    if not okTech then Log("tech level: " .. tostring(errTech)) end
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

-- Server check: a connected client asks the host whether Palvolve runs there and,
-- if not, disables evolution for the session and tells the player why. The
-- authority (host/single-player) runs the mod itself, so it never pings.
if Evolution and not Role.isDedicated() then
    local okSC, errSC = pcall(function()
        require("servercheck").init()
    end)
    if not okSC then
        Log("server check failed to load: " .. tostring(errSC))
    end
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

-- Survival Guide pages describing the loaded tree. PalSchema data like the
-- workbench stage above, so this writes a file and the pages appear on the next
-- start. Pointless on a dedicated server, which has no guide to read them.
--
-- Generation hangs off the world-entry callback rather than a timer, because
-- the species names it prints do not exist before a world is up. The slot is
-- already taken by the server check, so the existing handler is chained rather
-- than replaced.
if Evolution and not Role.isDedicated() then
    local okGuide, errGuide = pcall(function()
        local GuidePages = require("guidepages")
        GuidePages.init(Evolution.displayName)
        local NetChannel = require("netchannel")
        local previous = NetChannel.onLocalEnterWorld
        NetChannel.onLocalEnterWorld = function(char)
            if previous then pcall(previous, char) end
            pcall(GuidePages.onEnterWorld, char)
        end
    end)
    if not okGuide then Log("guide pages failed to load: " .. tostring(errGuide)) end
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

-- The evolution tree as a third tab in the game's Palpedia. Client-side and
-- read-only, so it loads wherever a player is: a dedicated server has no
-- Palpedia and the module simply never finds one to hook.
if not Role.isDedicated() then
    local okTree, errTree = pcall(require, "paldextree")
    if not okTree then
        Log("the Palpedia tree failed to load: " .. tostring(errTree))
    end
end

-- Dev probes (loaded only while devMode is true)
local okCfg, cfg = pcall(require, "config")
if okCfg and cfg.devMode then
    local okProbes, errProbes = pcall(require, "probes")
    if not okProbes then
        Log("probes failed to load: " .. tostring(errProbes))
    end
end
