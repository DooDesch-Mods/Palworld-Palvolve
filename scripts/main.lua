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

-- Role detection: UI modules and their retry pollers must not run on a
-- dedicated server. Their endless LoopAsync+ExecuteInGameThread retries
-- (the hooked widgets never load headless) churn transient callback refs,
-- which UE4SS's callback GC occasionally frees while still scheduled -
-- observed as corrupted closures and silent server deaths.
local Role = require("role")
if Role.isDedicated() then
    Log("dedicated server detected: UI modules disabled")
end

-- Workbench unlock stage: PalSchema data, so this only rewrites the data half's
-- building file and the new stage applies at the NEXT start. Runs on every
-- launch, which also repairs the value after a reinstall replaced the PalSchema
-- folder with its shipped default. Ahead of the core on purpose: it is pure
-- file I/O with no world state behind it, and a failure must not be able to
-- ride along on anything the core does.
do
    local okTech, errTech = pcall(function() require("techlevel").apply() end)
    if not okTech then Log("tech level: " .. tostring(errTech)) end
end

-- In-game options (Mod Options Framework): publishes the settings schema and
-- applies whatever the framework has saved. OPTIONAL - without the framework
-- installed this logs one line and config.lua/config_user.lua keep deciding
-- everything. Registered EARLY on purpose: the framework answers inside a
-- finite ~3.85s startup window it owns, and that window should start as soon
-- as the config exists. The answer therefore always lands AFTER this whole
-- file has run, which is why hook-arming options ride the options cache into
-- the next launch instead (see the third layer in config.lua).
-- Behind the UI gate like every other menu-touching module: the framework
-- draws itself into the ESC menu, so headless there is nothing to open, no
-- one to open it, and no reason to pay for the registration ladder or the
-- shared-variable traffic.
if not Role.isDedicated() then
    local okOpts, errOpts = pcall(function() require("modoptions").init() end)
    if not okOpts then Log("in-game options: " .. tostring(errOpts)) end
end

-- In-game settings page (DarnMenu): the SECOND menu onto the same 36 settings,
-- for players who have that mod rather than the options framework (or both).
-- Registers by writing two files into <UE4SS Mods>/shared/ and then polls the
-- file DarnMenu's Apply writes, off the pump modoptions.lua already owns - no
-- new loop, no timer. OPTIONAL and inert without DarnMenu installed, and it
-- writes NOTHING config.lua reads directly: every applied value is mirrored
-- into the one options cache, so the two menus share one store and the last
-- Apply wins. Immediately after modoptions on purpose - it takes the row table
-- and the value plumbing from there, so that module must have loaded first.
-- Behind the same not-dedicated gate: DarnMenu draws into the ESC menu.
if not Role.isDedicated() then
    local okDarn, errDarn = pcall(function() require("darnmenu").init() end)
    if not okDarn then Log("settings page: " .. tostring(errDarn)) end
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

-- Status page evolutions (targets + requirements on the pal detail overlay)
if Evolution and not Role.isDedicated() then
    local okStatus, errStatus = pcall(function()
        require("statuspage").init({
            describe = Evolution.describeEvolutionsFor,
        })
    end)
    if not okStatus then
        Log("status page integration failed to load: " .. tostring(errStatus))
    end
end

-- Palpedia evolutions (species entry: targets + requirements)
if Evolution and not Role.isDedicated() then
    local okDex, errDex = pcall(function()
        require("palpedia").init({
            describeSpecies = Evolution.describeEvolutionsForSpecies,
        })
    end)
    if not okDex then
        Log("palpedia integration failed to load: " .. tostring(errDex))
    end
end

-- Survival Guide pages describing the loaded tree. PalSchema data like the
-- workbench stage above, so this only writes a file and the pages appear at the
-- NEXT start. Pointless on a dedicated server, which has no guide to read them.
--
-- Generation hangs off the world-entry callback rather than off a timer: the
-- species names the pages print do not exist before a world is up, and a
-- load-time timer's window expires while the player is still in the menu. That
-- callback slot already belongs to the server check, so the existing handler is
-- CHAINED, never replaced - which is why this block sits after servercheck.init
-- and not before it.
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
    if not okGuide then
        Log("guide pages failed to load: " .. tostring(errGuide))
    end
end

-- Egg filter (config-gated inside)
local okEgg, errEgg = pcall(function()
    require("eggfilter").init()
end)
if not okEgg then
    Log("egg filter failed to load: " .. tostring(errEgg))
end

-- Wild level limit (config-gated inside): a wild pal too low-level for its
-- rolled species is devolved to the stage its level allows (or level-floored)
-- BEFORE the actor spawns. Authority-side world logic - runs on dedicated
-- servers too, so it is NOT behind the UI gate.
local okWild, errWild = pcall(function()
    require("wildfilter").init()
end)
if not okWild then
    Log("wild level limit failed to load: " .. tostring(errWild))
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

-- Dev probes (loaded only while devMode is true)
local okCfg, cfg = pcall(require, "config")
if okCfg and cfg.devMode then
    local okProbes, errProbes = pcall(require, "probes")
    if not okProbes then
        Log("probes failed to load: " .. tostring(errProbes))
    end
    -- Saddle-tech census (v1.7.5): read-only one-shot dump feeding the
    -- saddle-sync generator; devMode-gated like the probes
    local okTech, errTech = pcall(function() require("techcensus").init() end)
    if not okTech then
        Log("techcensus failed to load/init: " .. tostring(errTech))
    end
end
