-- Palvolve configuration: evolution map and settings.
-- Categories: "evolution" (small -> big form), "funchain" (across family lines),
-- "adaptation" (element variant). stone: "evolution" | "adaptation" - item costs
-- only apply while requireStone is true.
--
-- Optional per-pair field `conditions = { "night", "knowsMove:Dragon", ... }`:
-- every listed condition must hold at evolve time (AND). An either/or split is
-- two pairs with the same from/to and different conditions - the gates try all
-- same-target candidates. Vocabulary and colon syntax ("knowsMove:<Element>",
-- "inParty:<CharacterID>") live in conditions.lua; unknown ids are dropped at
-- load with a log line.
--
-- Map basis: DT_PalMonsterParameter row names (buildid 24088745). findPair
-- returns the FIRST enabled match: evolutions are therefore listed BEFORE
-- adaptations of the same base (e.g. Penguin). BOSS_/GYM_/RAID_/_Oilrig/
-- _Tower ids must NEVER be targets (boss/spawn logic is attached to them).
local Conditions = require("conditions")
-- only for Role.isDedicated(), which picks where the user config is looked up;
-- role.lua requires nothing itself, so pulling it in this early cannot loop
-- back into config
local Role = require("role")

local Config = {
    -- Dev mode: enables the diagnostic key bindings (probes.lua) and the
    -- [diag] sequence telemetry in the log.
    devMode = false,

    -- Reveal telemetry, on top of devMode. Separate because it keeps a polling
    -- closure alive for 12s per evolution and two overlapping ones crash the game.
    diagReveal = false,

    -- Mod version, reported to connected clients by the host handshake. Keep in
    -- sync with Info.json (the release flow checks this).
    modVersion = "1.8.0",

    -- Unlock the catch-gated technologies (saddle, Pal gear) of the target species when a
    -- pal evolves, the same way capturing one would. Needs the native companion in
    -- dlls/main.dll; without it this is skipped and evolution works as before.
    unlockCatchTech = true,

    -- Player level at which the Pal Alchemy Workbench becomes buildable in the
    -- technology tree. The stage lives in PalSchema data, not in Lua, so this is
    -- applied by rewriting that file and takes effect on the next game start.
    -- Keeping it here means it survives a Workshop update, which overwrites the
    -- PalSchema file itself. 10 is the shipped default.
    techLevelCap = 10,

    -- Server check: a connected client asks the host whether Palvolve runs
    -- server-side and which version. Without a host-side answer, evolution and
    -- the bench recipe patch are disabled for the session and the client is told
    -- why (so a client-only install no longer half-works and confuses players).
    serverCheck = {
        enabled = true,
        -- Grace window for the host's join greet. The greet fires from the
        -- client's server-side character init, which on a busy dedicated server
        -- can lag the client's own world entry by many seconds, so keep this
        -- generous. Hitting the timeout only soft-gates silently (the player is
        -- told at the moment they reach for evolution, not with a banner).
        timeoutSeconds = 25,
    },

    -- Timings for the evolution staging
    -- (spin-up -> shrink -> peak hold -> grow -> finale hold)
    digimon = {
        spinUpMs = 3000,       -- phase A: accelerating spin, effects ramp up
        shrinkMs = 2500,       -- phase B: keeps spinning, scales down to nothing
        growMs = 3500,         -- reveal: grows back while the spin winds down
        peakDegPerSec = 1080,  -- top angular speed at the end of the shrink
        finaleHoldMs = 3500,   -- finale: keeps turning majestically while the
                               -- effects fade, steering into the face-player
                               -- yaw at the very end
        elementColors = true   -- tint bursts/glow with the pals' elements
                               -- (dissolve = old form, reveal = target form);
                               -- false also disables the layered finale's
                               -- element layer (its base layer still runs)
    },

    -- Layered grand finale at the reveal (finale_recipes.lua + finale.lua)
    finale = {
        style = "layered",     -- "layered" | "legacy" (legacy = the old
                               -- 5-point burst rosette)
        maxLiveSystems = 14,   -- cap on simultaneously tracked live systems
        debugLog = false,      -- per-event spawn + anchor logging
    },

    -- The evolution page in the Palpedia carries no close control of its own by
    -- default: that screen closes with ESC like every other menu, and switching
    -- tabs leaves the page as well, so a second way out is one the reader has to
    -- read past. Set this to true to put it back.
    treeCloseButton = false,

    -- How much the mod says in the chat. Every line is private to the player it
    -- concerns, but on a busy server that is still a lot of lines for one
    -- person, which is what a player asked to be rid of.
    --   "all"     everything: greeting, what an evolution is doing, refusals
    --   "replies" only answers to something the player did: refusals and the
    --             replies to !palvolve commands
    --   "off"     nothing at all; the log still has every line
    -- Answers to a chat command are never silenced: a command that produces
    -- silence reads as a broken mod.
    chatMessages = "all",

    -- Two-stage confirm: first press checks and announces, second press confirms.
    -- Off by default since 1.6.4, because a mod that claims a function key on
    -- every install collides with the rest of a player's setup for a path the
    -- wheel and the chat command already cover. Set it to true to get the key
    -- back; nothing else about evolving changes either way.
    confirmKeyEnabled = false,
    confirmKey = "F2",
    confirmWindowSeconds = 10,
    debounceSeconds = 0.5,

    -- Multiplayer request channel (host-side limits per requesting player)
    net = {
        rateLimitSeconds = 2, -- minimum spacing between evolve requests
        reqIdCacheSize = 32,  -- replay protection window (request ids)
    },

    -- IV bonus per evolution stage (applied to Talent_HP/Melee/Shot/Defense, capped)
    ivBonusPerStage = 5,
    ivCap = 100,

    -- Item costs (stones exist via PalSchema; false = free mode)
    requireStone = true,
    stoneCount = 1,
    stoneItemIds = {
        evolution = "Palvolve_EvolutionStone",
        -- per-element adaptation stones (crafted from Evolution Stone +
        -- MeteorDrop + the matching element essence)
        adaptation = {
            Normal      = "Palvolve_AdaptationStone_Normal",
            Fire        = "Palvolve_AdaptationStone_Fire",
            Water       = "Palvolve_AdaptationStone_Water",
            Leaf        = "Palvolve_AdaptationStone_Leaf",
            Electricity = "Palvolve_AdaptationStone_Electricity",
            Ice         = "Palvolve_AdaptationStone_Ice",
            Earth       = "Palvolve_AdaptationStone_Earth",
            Dark        = "Palvolve_AdaptationStone_Dark",
            Dragon      = "Palvolve_AdaptationStone_Dragon",
        },
        -- legacy generic stone: kept for stones already in inventories,
        -- accepted whenever the target element cannot be resolved
        adaptationFallback = "Palvolve_AdaptionStone",
    },
    stoneNames = {
        evolution = "Evolution Stone",
        adaptation = "Adaptation Stone"
    },

    -- Material costs on top of the stone. Materials derive from drop tables
    -- (evolutions price the BASE pal's drops, adaptations the TARGET form's);
    -- a per-pair `materials = { { id = "...", count = n }, ... }` overrides.
    -- Off by default: the stone + essence chain already carries the price,
    -- extra per-pal materials are opt-in for players who want more grind.
    costs = {
        enabled = false,
        slots = 2,        -- max distinct material types taken from a drop row
        minRate = 50.0,   -- ignore drop slots rarer than this (percent)
        countScale = 4.0, -- count = ceil(avg(min,max) * countScale), clamped
        maxCount = 30,
        fallbackMaterials = {
            -- species without a drop table row
        },
    },

    -- Egg filter, opt-in (off by default): when enabled, eggs only ever hatch
    -- base forms (evolved forms are normalized back to their base species while
    -- hatching); funchain results stay allowed.
    eggFilter = {
        enabled = false,
    },

    -- Map schema version; 5 = negatable conditions ("!" prefix), 4 = per-pair
    -- conditions
    schemaVersion = 5,

    -- How the author arranged their tree, when their config carries it. Purely
    -- presentational: nothing here decides whether an evolution happens, and a
    -- config without it behaves exactly as before. The in-game tree view draws
    -- from this so it shows the picture its author built rather than a second
    -- layout that disagrees with the website.
    --
    -- All coordinates are whole pixels in the website's canvas space, and the
    -- two anchors differ - reading a frame as a center shifts it by half its
    -- own size:
    --   positions[palId] = { x, y }               the pal's CENTER
    --   copies[i] = { gid, palId, x, y }          the copy's CENTER
    --   frames[i] = { x, y, w, h, color, label }  TOP-LEFT corner, w/h run
    --                                             right and down from it
    -- A copy is a second picture of one pal; palId names the pal it stands for
    -- and gid tells two copies of the same pal apart. color is whatever the
    -- author picked and label may be empty, so whatever draws a frame needs a
    -- fallback for a color it does not know.
    arrangement = { positions = {}, frames = {}, copies = {} },
    -- Palworld revision: the last five digits of the title-screen version
    -- (v1.0.3.101283 -> 1283), the identifier the official mod loader uses.
    -- Five, not three: v1.0.1.100619 gave 619 either way, which hid the rule
    -- until a version arrived where the two readings disagree.
    gameBuild = 1283,

    map = {
    -- ==================== True evolutions (small -> big form) ====================
    {
        from = "Penguin",
        to = "CaptainPenguin",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        enabled = true
    }, -- Pengullet -> Penking
    {
        from = "MopBaby",
        to = "MopKing",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        conditions = { "inParty:MopKing" },
        enabled = true
    }, -- Swee -> Sweepa (inParty:MopKing)
    {
        from = "Alpaca",
        to = "KingAlpaca",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Melpaca -> Kingpaca
    {
        from = "SoldierBee",
        to = "QueenBee",
        category = "evolution",
        minLevel = 35,
        stone = "evolution",
        enabled = true
    }, -- Beegarde -> Elizabee
    {
        from = "MoonChild",
        to = "MoonQueen",
        category = "evolution",
        minLevel = 50,
        stone = "evolution",
        enabled = true
    }, -- Wistella -> Selyne
    {
        from = "SmallYeti",
        to = "Yeti",
        category = "evolution",
        minLevel = 22,
        stone = "evolution",
        enabled = true
    }, -- Snugloo -> Wumpo
    {
        from = "Penguin_Electric",
        to = "CaptainPenguin_Black",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        enabled = true
    }, -- Pengullet Lux -> Penking Lux
    {
        from = "Bastet",
        to = "Sekhmet",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        conditions = { "day", "inDesert" },
        enabled = true
    }, -- Mau -> Sekhmet (day + inDesert)
    {
        from = "Kelpie",
        to = "Umihebi",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "electrified" },
        enabled = true
    }, -- Kelpsea -> Jormuntide (electrified)
    {
        from = "Kelpie",
        to = "Umihebi",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "knowsMove:Dragon" },
        enabled = true
    }, -- Kelpsea -> Jormuntide (knowsMove:Dragon)
    {
        from = "Kelpie_Fire",
        to = "Umihebi_Fire",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "electrified" },
        enabled = true
    }, -- Kelpsea Ignis -> Jormuntide Ignis (electrified)
    {
        from = "Kelpie_Fire",
        to = "Umihebi_Fire",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "knowsMove:Dragon" },
        enabled = true
    }, -- Kelpsea Ignis -> Jormuntide Ignis (knowsMove:Dragon)
    {
        from = "Carbunclo",
        to = "BerryGoat",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        enabled = true
    }, -- Lifmunk -> Caprity
    {
        from = "BerryGoat",
        to = "SkyDragon_Grass",
        category = "evolution",
        minLevel = 42,
        stone = "evolution",
        enabled = true
    }, -- Caprity -> Quivern Botan
    {
        from = "PinkRabbit_Grass",
        to = "FlowerDoll",
        category = "evolution",
        minLevel = 30,
        stone = "evolution",
        enabled = true
    }, -- Ribbuny Botan -> Petallia
    {
        from = "PinkRabbit",
        to = "FlowerDoll_Fire",
        category = "evolution",
        minLevel = 30,
        stone = "evolution",
        enabled = true
    }, -- Ribbuny -> Petallia Ignis
    {
        from = "FlowerRabbit",
        to = "VenusFlytrap",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Flopie -> Carnibora
    {
        from = "LeafPrincess",
        to = "LilyQueen",
        category = "evolution",
        minLevel = 40,
        stone = "evolution",
        enabled = true
    }, -- Lullu -> Lyleen
    {
        from = "LeafMomonga",
        to = "GrassPanda",
        category = "evolution",
        minLevel = 32,
        stone = "evolution",
        enabled = true
    }, -- Herbil -> Mossanda
    {
        from = "CloverFairy",
        to = "GrassMinotaur",
        category = "evolution",
        minLevel = 30,
        stone = "evolution",
        enabled = true
    }, -- Clovee -> Elgrove
    {
        from = "LittleBriarRose",
        to = "SakuraSaurus",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Bristla -> Broncherry
    {
        from = "SakuraSaurus",
        to = "Plesiosaur",
        category = "evolution",
        minLevel = 48,
        stone = "evolution",
        enabled = true
    }, -- Broncherry -> Braloha
    {
        from = "NegativeKoala",
        to = "BadCatgirl",
        category = "evolution",
        minLevel = 36,
        stone = "evolution",
        enabled = true
    }, -- Depresso -> Nyafia
    {
        from = "OctopusGirl",
        to = "SnakeGirl",
        category = "evolution",
        minLevel = 40,
        stone = "evolution",
        enabled = true
    }, -- Gloopie -> Venusa
    {
        from = "WizardOwl",
        to = "BlackGriffon",
        category = "evolution",
        minLevel = 48,
        stone = "evolution",
        enabled = true
    }, -- Hoocrates -> Shadowbeak
    {
        from = "Bastet",
        to = "GhostBlackCat",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        conditions = { "night" },
        enabled = true
    }, -- Mau -> Wispaw (night)
    {
        from = "Bastet",
        to = "GhostBlackCat",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        conditions = { "inCave" },
        enabled = true
    }, -- Mau -> Wispaw (inCave)
    {
        from = "NightFox",
        to = "AmaterasuWolf_Dark",
        category = "evolution",
        minLevel = 36,
        stone = "evolution",
        enabled = true
    }, -- Nox -> Kitsun Noct
    {
        from = "CatBat",
        to = "CatVampire",
        category = "evolution",
        minLevel = 35,
        stone = "evolution",
        enabled = true
    }, -- Tombat -> Felbat
    {
        from = "ElecCat",
        to = "ElecPanda",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        enabled = true
    }, -- Sparkit -> Grizzbolt
    {
        from = "ElecLizard",
        to = "KingSunfish_Thunder",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        enabled = true
    }, -- Slowatt -> Solmora Lux
    {
        from = "ElecPomeranian",
        to = "ThunderDog",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        enabled = true
    }, -- Puffolt -> Rayhound
    {
        from = "ThunderDog",
        to = "ThunderDragonMan",
        category = "evolution",
        minLevel = 42,
        stone = "evolution",
        enabled = true
    }, -- Rayhound -> Orserk
    {
        from = "Penguin_Electric",
        to = "ThunderFluffyBird",
        category = "evolution",
        minLevel = 31,
        stone = "evolution",
        conditions = { "electrified" },
        enabled = true
    }, -- Pengullet Lux -> Dynamoff (electrified)
    {
        from = "Penguin_Electric",
        to = "ThunderFluffyBird",
        category = "evolution",
        minLevel = 31,
        stone = "evolution",
        conditions = { "inSanctuary" },
        enabled = true
    }, -- Pengullet Lux -> Dynamoff (inSanctuary)
    {
        from = "Kitsunebi",
        to = "FlameBuffalo",
        category = "evolution",
        minLevel = 32,
        stone = "evolution",
        enabled = true
    }, -- Foxparks -> Arsox
    {
        from = "SharkKid_Fire",
        to = "StuffedShark_Fire",
        category = "evolution",
        minLevel = 36,
        stone = "evolution",
        enabled = true
    }, -- Gobfin Ignis -> Finsider Ignis
    {
        from = "Kelpie_Fire",
        to = "Suzaku",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "inWater" },
        enabled = true
    }, -- Kelpsea Ignis -> Suzaku (inWater)
    {
        from = "Kelpie",
        to = "Suzaku_Water",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "inWater" },
        enabled = true
    }, -- Kelpsea -> Suzaku Aqua (inWater)
    {
        from = "LavaGirl",
        to = "FoxMage",
        category = "evolution",
        minLevel = 32,
        stone = "evolution",
        enabled = true
    }, -- Flambelle -> Wixen
    {
        from = "FoxMage",
        to = "KabukiMan",
        category = "evolution",
        minLevel = 42,
        stone = "evolution",
        enabled = true
    }, -- Wixen -> Renjishi
    {
        from = "FireKirin",
        to = "Manticore",
        category = "evolution",
        minLevel = 35,
        stone = "evolution",
        enabled = true
    }, -- Pyrin -> Blazehowl
    {
        from = "FireKirin_Dark",
        to = "Manticore_Dark",
        category = "evolution",
        minLevel = 35,
        stone = "evolution",
        enabled = true
    }, -- Pyrin Noct -> Blazehowl Noct
    {
        from = "IceSeal_Ground",
        to = "SumoDog",
        category = "evolution",
        minLevel = 36,
        stone = "evolution",
        enabled = true
    }, -- Polapup Terra -> Bulldosu
    {
        from = "SamuraiDog",
        to = "BrownRabbit",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Pupperai -> Lapiron
    {
        from = "TentacleTurtle_Ground",
        to = "DrillGame",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        enabled = true
    }, -- Turtacle Terra -> Digtoise
    {
        from = "DrillGame",
        to = "CubeTurtle",
        category = "evolution",
        minLevel = 42,
        stone = "evolution",
        enabled = true
    }, -- Digtoise -> Tetroise 
    {
        from = "Kitsunebi_Ice",
        to = "IceFox",
        category = "evolution",
        minLevel = 32,
        stone = "evolution",
        enabled = true
    }, -- Foxparks Cryst -> Foxcicle
    {
        from = "BirdDragon_Ice",
        to = "ThunderBird_Ice",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        enabled = true
    }, -- Vanwyrm Cryst -> Beakon Cryst
    {
        from = "Hedgehog_Ice",
        to = "WhiteTiger",
        category = "evolution",
        minLevel = 36,
        stone = "evolution",
        enabled = true
    }, -- Jolthog Cryst -> Cryolinx
    {
        from = "FluffyBird",
        to = "WhiteMoth",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Muffly -> Sibelyx
    {
        from = "Bastet_Ice",
        to = "BlackPuppy_Ice",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        enabled = true
    }, -- Mau Cryst -> Smokie Cryst
    {
        from = "PinkCat",
        to = "LongCat",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Cattiva -> Valentail
    {
        from = "SweetsSheep",
        to = "PinkLizard",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        enabled = true
    }, -- Woolipop -> Lovander
    {
        from = "CuteFox",
        to = "SifuDog",
        category = "evolution",
        minLevel = 30,
        stone = "evolution",
        enabled = true
    }, -- Vixy -> Dogen
    {
        from = "NightBlueHorse_Neutral",
        to = "LegendDeer",
        category = "evolution",
        minLevel = 50,
        stone = "evolution",
        enabled = true
    }, -- Starryon Primo -> Hartalis
    {
        from = "NegativeOctopus_Neutral",
        to = "OctopusGirl_Neutral",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        enabled = true
    }, -- Killamari Primo -> Gloopie Primo
    -- ==================== Fun chains (deliberate jokes) ====================
    {
        from = "MopKing",
        to = "SmallYeti",
        category = "funchain",
        minLevel = 45,
        stone = "evolution",
        enabled = true
    }, -- Sweepa -> Snugloo
    {
        from = "PinkCat",
        to = "BadCatgirl",
        category = "funchain",
        minLevel = 35,
        stone = "evolution",
        enabled = false
    }, -- Cattiva -> Nyafia
    {
        from = "SmallArmadillo",
        to = "DrillGame",
        category = "funchain",
        minLevel = 16,
        stone = "evolution",
        enabled = true
    }, -- Kikit -> Digtoise
    {
        from = "Ganesha",
        to = "GrassMammoth_Ice",
        category = "funchain",
        minLevel = 40,
        stone = "evolution",
        enabled = true
    }, -- Teafant -> Mammorest Cryst
    -- ==================== Element adaptations (same species) ====================
    {
        from = "AmaterasuWolf",
        to = "AmaterasuWolf_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Kitsun -> Kitsun Noct
    {
        from = "Baphomet",
        to = "Baphomet_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Incineram -> Incineram Noct
    {
        from = "Bastet",
        to = "Bastet_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Mau -> Mau Cryst
    {
        from = "BerryGoat",
        to = "BerryGoat_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Caprity -> Caprity Noct
    {
        from = "BirdDragon",
        to = "BirdDragon_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Vanwyrm -> Vanwyrm Cryst
    {
        from = "BlackPuppy",
        to = "BlackPuppy_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Smokie -> Smokie Cryst
    {
        from = "BlueDragon",
        to = "BlueDragon_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Azurobe -> Azurobe Cryst
    {
        from = "BluePlatypus",
        to = "BluePlatypus_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Fuack -> Fuack Ignis
    {
        from = "CactusDoll",
        to = "CactusDoll_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Needoll -> Needoll Noct
    {
        from = "CaptainPenguin",
        to = "CaptainPenguin_Black",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, -- Penking -> Penking Lux
    {
        from = "CatMage",
        to = "CatMage_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Katress -> Katress Ignis
    {
        from = "CubeTurtle",
        to = "CubeTurtle_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Tetroise  -> Tetroise Primo
    {
        from = "DarkScorpion",
        to = "DarkScorpion_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Menasting -> Menasting Terra
    {
        from = "Deer",
        to = "Deer_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Eikthyrdeer -> Eikthyrdeer Terra
    {
        from = "ElecSnail",
        to = "ElecSnail_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Snock -> Snock Ignis
    {
        from = "ElecSnail",
        to = "ElecSnail_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Snock -> Snock Lux
    {
        from = "FairyDragon",
        to = "FairyDragon_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Elphidran -> Elphidran Aqua
    {
        from = "FengyunDeeper",
        to = "FengyunDeeper_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Fenglope -> Fenglope Lux
    {
        from = "FireKirin",
        to = "FireKirin_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Pyrin -> Pyrin Noct
    {
        from = "FlowerDinosaur",
        to = "FlowerDinosaur_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Dinossom -> Dinossom Lux
    {
        from = "FlowerDoll",
        to = "FlowerDoll_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Petallia -> Petallia Ignis
    {
        from = "FlyingManta",
        to = "FlyingManta_Thunder",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Celaray -> Celaray Lux
    {
        from = "FoxMage",
        to = "FoxMage_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Wixen -> Wixen Noct
    {
        from = "GhostAnglerfish",
        to = "GhostAnglerfish_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Ghangler -> Ghangler Ignis
    {
        from = "GhostDragon",
        to = "GhostDragon_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Eidrolon -> Eidrolon Ignis
    {
        from = "GhostRabbit",
        to = "GhostRabbit_Grass",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Nitemary -> Nitemary Botan
    {
        from = "Gorilla",
        to = "Gorilla_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Gorirat -> Gorirat Terra
    {
        from = "GrassGolem",
        to = "GrassGolem_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Dualith -> Dualith Noct
    {
        from = "GrassMammoth",
        to = "GrassMammoth_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Mammorest -> Mammorest Cryst
    {
        from = "GrassMinotaur",
        to = "GrassMinotaur_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Elgrove -> Elgrove Cryst
    {
        from = "GrassPanda",
        to = "GrassPanda_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Mossanda -> Mossanda Lux
    {
        from = "HadesBird",
        to = "HadesBird_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Helzephyr -> Helzephyr Lux
    {
        from = "Hedgehog",
        to = "Hedgehog_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Jolthog -> Jolthog Cryst
    {
        from = "HerculesBeetle",
        to = "HerculesBeetle_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Warsect -> Warsect Terra
    {
        from = "Horus",
        to = "Horus_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Faleris -> Faleris Aqua
    {
        from = "IceHorse",
        to = "IceHorse_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Frostallion -> Frostallion Noct
    {
        from = "IceNarwhal",
        to = "IceNarwhal_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Whalaska -> Whalaska Ignis
    {
        from = "IceSeal",
        to = "IceSeal_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Polapup -> Polapup Terra
    {
        from = "Kelpie",
        to = "Kelpie_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Kelpsea -> Kelpsea Ignis
    {
        from = "KendoFrog",
        to = "KendoFrog_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Croajiro -> Croajiro Noct
    {
        from = "KingAlpaca",
        to = "KingAlpaca_Ice",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, -- Kingpaca -> Kingpaca Cryst
    {
        from = "KingBahamut",
        to = "KingBahamut_Dragon",
        category = "adaptation",
        minLevel = 40,
        stone = "adaptation",
        enabled = true
    }, -- Blazamut -> Blazamut Ryu
    {
        from = "KingSunfish",
        to = "KingSunfish_Thunder",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Solmora -> Solmora Lux
    {
        from = "Kirin",
        to = "Kirin_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Univolt -> Univolt Cryst
    {
        from = "Kitsunebi",
        to = "Kitsunebi_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Foxparks -> Foxparks Cryst
    {
        from = "LazyCatfish",
        to = "LazyCatfish_Gold",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Dumud -> Dumud Gild
    {
        from = "LazyDragon",
        to = "LazyDragon_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        conditions = { "electrified" },
        enabled = true
    }, -- Relaxaurus -> Relaxaurus Lux (electrified)
    {
        from = "LilyQueen",
        to = "LilyQueen_Dark",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, -- Lyleen -> Lyleen Noct
    {
        from = "LizardMan",
        to = "LizardMan_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Leezpunk -> Leezpunk Ignis
    {
        from = "Manticore",
        to = "Manticore_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Blazehowl -> Blazehowl Noct
    {
        from = "Monkey",
        to = "Monkey_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Tanzee -> Tanzee Ignis
    {
        from = "Monkey",
        to = "Monkey_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Tanzee -> Tanzee Cryst
    {
        from = "MushroomDragon",
        to = "MushroomDragon_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Shroomer -> Shroomer Noct
    {
        from = "NegativeOctopus",
        to = "NegativeOctopus_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Killamari -> Killamari Primo
    {
        from = "NightBlueHorse",
        to = "NightBlueHorse_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Starryon -> Starryon Primo
    {
        from = "NightLady",
        to = "NightLady_Dark",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, -- Bellanoir -> Bellanoir Libero
    {
        from = "OctopusGirl",
        to = "OctopusGirl_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Gloopie -> Gloopie Primo
    {
        from = "Penguin",
        to = "Penguin_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Pengullet -> Pengullet Lux
    {
        from = "PinkRabbit",
        to = "PinkRabbit_Grass",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Ribbuny -> Ribbuny Botan
    {
        from = "PlantSlime",
        to = "PlantSlime_Flower",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Gumoss -> Gumoss Botan
    {
        from = "RaijinDaughter",
        to = "RaijinDaughter_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Dazzi -> Dazzi Noct
    {
        from = "RobinHood",
        to = "RobinHood_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Robinquill -> Robinquill Terra
    {
        from = "RockBeast",
        to = "RockBeast_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Pierdon -> Pierdon Cryst
    {
        from = "Ronin",
        to = "Ronin_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Bushi -> Bushi Noct
    {
        from = "SakuraSaurus",
        to = "SakuraSaurus_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Broncherry -> Broncherry Aqua
    {
        from = "ScorpionMan",
        to = "ScorpionMan_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Prixter -> Prixter Lux
    {
        from = "Serpent",
        to = "Serpent_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Surfent -> Surfent Terra
    {
        from = "SharkKid",
        to = "SharkKid_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Gobfin -> Gobfin Ignis
    {
        from = "SkyDragon",
        to = "SkyDragon_Grass",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Quivern -> Quivern Botan
    {
        from = "StuffedShark",
        to = "StuffedShark_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Finsider -> Finsider Ignis
    {
        from = "Suzaku",
        to = "Suzaku_Water",
        category = "adaptation",
        minLevel = 40,
        stone = "adaptation",
        conditions = { "inWater" },
        enabled = true
    }, -- Suzaku -> Suzaku Aqua (inWater)
    {
        from = "SweetsSheep",
        to = "SweetsSheep_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Woolipop -> Woolipop Terra
    {
        from = "SwordCutlassfish",
        to = "SwordCutlassfish_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Skutlass -> Skutlass Ignis
    {
        from = "TentacleTurtle",
        to = "TentacleTurtle_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Turtacle -> Turtacle Terra
    {
        from = "ThunderBird",
        to = "ThunderBird_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Beakon -> Beakon Cryst
    {
        from = "ThunderDog",
        to = "ThunderDog_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Rayhound -> Rayhound Cryst
    {
        from = "Umihebi",
        to = "Umihebi_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Jormuntide -> Jormuntide Ignis
    {
        from = "VolcanicMonster",
        to = "VolcanicMonster_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Reptyro -> Reptyro Cryst
    {
        from = "VolcanoDragon",
        to = "VolcanoDragon_Ice",
        category = "adaptation",
        minLevel = 40,
        stone = "adaptation",
        enabled = true
    }, -- Moldron -> Moldron Cryst
    {
        from = "WeaselDragon",
        to = "WeaselDragon_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Chillet -> Chillet Ignis
    {
        from = "Werewolf",
        to = "Werewolf_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Loupmoon -> Loupmoon Cryst
    {
        from = "WhiteDeer",
        to = "WhiteDeer_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Celesdir -> Celesdir Noct
    {
        from = "WhiteMoth",
        to = "WhiteMoth_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Sibelyx -> Sibelyx Primo
    {
        from = "WhiteTiger",
        to = "WhiteTiger_Ground",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, -- Cryolinx -> Cryolinx Terra
    {
        from = "WindChimes",
        to = "WindChimes_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Hangyu -> Hangyu Cryst
    {
        from = "WingGolem",
        to = "WingGolem_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Knocklem -> Knocklem Ignis
    {
        from = "Yeti",
        to = "Yeti_Grass",
        category = "adaptation",
        minLevel = 45,
        stone = "adaptation",
        enabled = true
    }, -- Wumpo -> Wumpo Botan
    },
}

-- An FName compares without regard to case but remembers the spelling it was
-- first registered with, and that is what ToString hands back. Palworld's own
-- data contains 42 species under two spellings - "SheepBall" 260 times and
-- "Sheepball" once - so which one a session reports depends on load order.
-- Comparing those with == silently drops every pair of that species: the
-- Evolve option greys out and the log claims the species has no evolution.
local canonicalById = nil
local function buildCanonical()
    canonicalById = {}
    -- Later sources overwrite earlier ones, so the most authoritative spelling
    -- ends up in the index: elements_static carries DT_PalMonsterParameter's
    -- own row names, while the two before it reach species that table leaves
    -- out, such as raid-only forms.
    for _, source in ipairs({ "drops_static", "boss_static", "elements_static" }) do
        local okSource, data = pcall(require, source)
        if okSource and type(data) == "table" then
            for id in pairs(data) do
                if type(id) == "string" then canonicalById[id:lower()] = id end
            end
        end
    end
    -- And the map last: a config names the spelling its own pairs are matched
    -- against, so that one has the final say.
    for _, pair in ipairs(Config.map or {}) do
        if type(pair.from) == "string" then canonicalById[pair.from:lower()] = pair.from end
        if type(pair.to) == "string" then canonicalById[pair.to:lower()] = pair.to end
    end
end

-- The spelling the config and the data tables use, for an id the game handed
-- back in whatever case it happened to register. Unknown ids come back
-- unchanged, so a custom species still behaves exactly as before.
function Config.canonicalId(rawId)
    if type(rawId) ~= "string" then return rawId end
    if canonicalById == nil then buildCanonical() end
    local lower = rawId:lower()
    local known = canonicalById[lower]
    if known then return known end
    -- An Alpha carries a BOSS_ prefix, and the game spells those two ways as
    -- well ("BOSS_MopKing" next to "BOSS_Mopking"). The index holds bare
    -- species ids, so resolve the species behind the prefix and put one fixed
    -- prefix spelling back in front of it. Every comparison runs both of its
    -- sides through here, so which spelling that is does not matter.
    local base = lower:match("^boss_(.+)$")
    base = base and canonicalById[base]
    if base then return "BOSS_" .. base end
    return rawId
end

-- Called after the user config replaced or extended the map, so ids that only
-- exist in that file are in the index too.
function Config.resetCanonical()
    canonicalById = nil
end

--- Reads the arrangement a config carries, dropping anything malformed.
---
--- Every value is checked because this file is a stranger's data: a published
--- config travels the internet, and a table where a number belongs would reach
--- the widget that draws it and fail there instead of here. Missing sections
--- are normal - a config from the quick setup has no arrangement at all.
---
--- Whatever happens, Config.arrangement ends up a table with all three
--- sections, so a caller never has to test for nil.
function Config.loadArrangement(user)
    local out = { positions = {}, frames = {}, copies = {} }
    -- Same limit the website enforces before it lets a config be published;
    -- the two have to move together or a valid arrangement starts losing pals.
    local LIMIT = 100000

    if type(user) ~= "table" then user = {} end

    --- A coordinate, or nil for anything a canvas cannot place: not a number
    --- (n ~= n catches NaN), or past the edge of the world in either direction
    --- (which is where an infinity lands).
    local function coord(v)
        local n = tonumber(v)
        if not n or n ~= n or n < -LIMIT or n > LIMIT then return nil end
        return n
    end

    if type(user.positions) == "table" then
        for id, p in pairs(user.positions) do
            if type(id) == "string" and type(p) == "table" then
                local x, y = coord(p.x), coord(p.y)
                if x and y then out.positions[Config.canonicalId(id)] = { x = x, y = y } end
            end
        end
    end

    if type(user.frames) == "table" then
        for _, f in ipairs(user.frames) do
            if type(f) == "table" then
                local x, y, w, h = coord(f.x), coord(f.y), coord(f.w), coord(f.h)
                if x and y and w and h and w > 0 and h > 0 then
                    table.insert(out.frames, {
                        x = x, y = y, w = w, h = h,
                        color = type(f.color) == "string" and f.color or "Neutral",
                        label = type(f.label) == "string" and f.label or "",
                    })
                end
            end
        end
    end

    if type(user.copies) == "table" then
        for _, c in ipairs(user.copies) do
            if type(c) == "table" and type(c.gid) == "string" and type(c.palId) == "string" then
                local x, y = coord(c.x), coord(c.y)
                if x and y then
                    table.insert(out.copies, {
                        gid = c.gid, palId = Config.canonicalId(c.palId), x = x, y = y,
                    })
                end
            end
        end
    end

    Config.arrangement = out
    return out
end

--- True when the config brought a picture worth drawing.
---
--- Placed pals are what decides it. Frames and copies only make sense around
--- pals that already sit somewhere, so a file that carries those and no
--- positions has nothing to draw them against and counts as no picture.
function Config.hasArrangement()
    local a = Config.arrangement
    if type(a) ~= "table" then return false end
    return next(a.positions or {}) ~= nil
end

function Config.findPair(characterId)
    characterId = Config.canonicalId(characterId)
    for _, pair in ipairs(Config.map) do
        if pair.enabled and pair.from == characterId then
            return pair
        end
    end
    return nil
end

-- ALL enabled options for a species (evolution + adaptations) - the choice
-- menu presents these filtered by affordability.
-- Identity of a tree, as a short hex string. FNV-1a over the canonicalized pair
-- list: sorted, so two configs that hold the same pairs in a different order
-- hash the same, and only the fields that decide what an evolution DOES take
-- part. A host and a client comparing this can tell whether they are playing by
-- the same rules without moving the tree itself across the wire.
function Config.treeHash(map)
    map = map or Config.map
    if type(map) ~= "table" then return "0" end

    local lines = {}
    for _, p in ipairs(map) do
        if p.enabled then
            local conds = ""
            if type(p.conditions) == "table" and #p.conditions > 0 then
                local sorted = {}
                for _, c in ipairs(p.conditions) do table.insert(sorted, tostring(c)) end
                table.sort(sorted)
                conds = table.concat(sorted, ",")
            end
            table.insert(lines, string.format("%s>%s|%s|%d|%s|%s",
                tostring(p.from), tostring(p.to), tostring(p.category or ""),
                tonumber(p.minLevel) or 0, tostring(p.stone or ""), conds))
        end
    end
    table.sort(lines)

    -- FNV-1a, with the 32-bit multiply split into 16-bit halves. The plain
    -- form overflows into a float on the way, and a float has no integer
    -- representation for the next xor - which means the same tree would hash
    -- differently depending on where it ran.
    -- Hex literals, because a decimal constant past 2^31 can arrive as a float
    -- in a Lua that maps numbers onto doubles, and a float cannot be xored.
    local PRIME = 0x01000193
    local hash = 0x811C9DC5

    local function mix(byte)
        hash = hash ~ byte
        -- every intermediate stays under 2^33 on purpose
        local lo = ((hash & 0xFFFF) * PRIME) & 0xFFFFFFFF
        local hi = ((((hash >> 16) & 0xFFFF) * PRIME) & 0xFFFF) << 16
        hash = (lo + hi) & 0xFFFFFFFF
    end

    for _, line in ipairs(lines) do
        for i = 1, #line do mix(line:byte(i)) end
        mix(10)     -- record separator, so concatenation cannot forge a match
    end
    return string.format("%08x", hash), #lines
end

function Config.findPairs(characterId)
    characterId = Config.canonicalId(characterId)
    local result = {}
    for _, pair in ipairs(Config.map) do
        if pair.enabled and pair.from == characterId then
            table.insert(result, pair)
        end
    end
    return result
end

-- Reverse maps for the egg filter, split by category so eggs follow EVOLUTION
-- chains only. Funchain links are always excluded. Both maps point at parents:
-- the walk below only ever moves towards the base of a chain.
--   evoParents[to] = { evolution froms }
--   adaParents[to] = { adaptation froms }
local evoParentsCache, adaParentsCache = nil, nil

--- Everything the config derives from its pair map, built once and kept. When
--- a server hands this client its own tree the map underneath them changes, and
--- a stale spelling table or a stale parent map is the old tree still deciding.
function Config.invalidateDerived()
    canonicalById = nil
    evoParentsCache, adaParentsCache = nil, nil
end

local function eggParents()
    if evoParentsCache == nil then
        evoParentsCache, adaParentsCache = {}, {}
        local function add(map, k, v)
            local list = map[k]
            if not list then list = {}; map[k] = list end
            for _, x in ipairs(list) do if x == v then return end end
            table.insert(list, v)
        end
        for _, pair in ipairs(Config.map) do
            if pair.enabled then
                if pair.category == "evolution" then
                    add(evoParentsCache, pair.to, pair.from)
                elseif pair.category == "adaptation" then
                    add(adaParentsCache, pair.to, pair.from)
                end
            end
        end
    end
    return evoParentsCache, adaParentsCache
end

-- Raw base candidates for an egg of `characterId`, following EVOLUTION chains
-- only. First, peel the id's own adaptation layers to reach the evolution chain
-- beneath it. Then walk evolution parents STRICTLY below the seeds; every node
-- reached that is an adaptation form OR an evolution root is a "family point".
-- Finally, expand each family point to that point itself plus the plain base it
-- adapted from. So an interleaved chain contributes candidates at every
-- adaptation form it passes through, not only at the very bottom. A pure
-- adaptation with no evolution beneath yields nothing, so element variants
-- hatch unchanged. Config.baseFormsOf below resolves these to terminal forms.
local function rawBaseForms(characterId)
    local evoParents, adaParents = eggParents()

    -- plain base(s) of Y: peel Y's adaptation layers to forms with no adaptation
    -- parent (Y itself when it is not an adaptation form)
    local function plainBases(Y)
        if not adaParents[Y] then return { Y } end
        local out, seen, st = {}, {}, { Y }
        while #st > 0 do
            local cur = table.remove(st)
            local ps = adaParents[cur]
            if ps and #ps > 0 then
                for _, p in ipairs(ps) do
                    if not seen[p] then seen[p] = true; table.insert(st, p) end
                end
            else
                table.insert(out, cur)
            end
        end
        return out
    end

    -- A candidate is the reached form itself plus the forms that can be adapted INTO it,
    -- never its sibling variants. Adaptation runs one way (base -> variant), so handing out
    -- a sibling strands the player: from Kelpsea Ignis there is no way back to Kelpsea, while
    -- Kelpsea can still become Ignis and is therefore a fair stand-in for it.
    local family, famSet = {}, {}
    local function addFamily(pointId)
        local function add(id)
            if not famSet[id] then famSet[id] = true; table.insert(family, id) end
        end
        add(pointId)
        for _, b in ipairs(plainBases(pointId)) do add(b) end
    end

    -- seeds: characterId plus its adaptation ancestors
    local seeds, seedSet, astack = {}, { [characterId] = true }, { characterId }
    while #astack > 0 do
        local cur = table.remove(astack)
        table.insert(seeds, cur)
        local ps = adaParents[cur]
        if ps then
            for _, p in ipairs(ps) do
                if not seedSet[p] then seedSet[p] = true; table.insert(astack, p) end
            end
        end
    end

    -- evolution walk strictly below the seeds; expand every family point
    -- (adaptation form or evolution root) it reaches
    local visited, estack = {}, {}
    for _, s in ipairs(seeds) do
        local ps = evoParents[s]
        if ps then for _, p in ipairs(ps) do table.insert(estack, p) end end
    end
    while #estack > 0 do
        local cur = table.remove(estack)
        if not visited[cur] then
            visited[cur] = true
            if adaParents[cur] or not evoParents[cur] then addFamily(cur) end
            local ps = evoParents[cur]
            if ps then
                for _, p in ipairs(ps) do
                    if not visited[p] then table.insert(estack, p) end
                end
            end
        end
    end

    -- never resolve to the egg's own species
    if famSet[characterId] then
        local filtered = {}
        for _, id in ipairs(family) do
            if id ~= characterId then table.insert(filtered, id) end
        end
        return filtered
    end
    return family
end

-- All distinct base forms an egg of `characterId` may hatch. Resolves the raw
-- candidates to TERMINAL forms: a candidate that is itself an evolution target
-- (an intermediate on an interleaved chain, where an element-adapted form also
-- evolves from something) is replaced by its own base forms. This makes every
-- returned candidate a fixed point, so the egg filter's per-egg pick is stable
-- and repeated hook fires never re-normalize a chosen base to a deeper one.
function Config.baseFormsOf(characterId)
    local result, resultSet, seen = {}, {}, {}
    local worklist = {}
    for _, c in ipairs(rawBaseForms(characterId)) do table.insert(worklist, c) end
    while #worklist > 0 do
        local cur = table.remove(worklist)
        if not seen[cur] then
            seen[cur] = true
            local sub = rawBaseForms(cur)
            if #sub == 0 then
                if cur ~= characterId and not resultSet[cur] then
                    resultSet[cur] = true
                    table.insert(result, cur)
                end
            else
                for _, s in ipairs(sub) do
                    if not seen[s] then table.insert(worklist, s) end
                end
            end
        end
    end
    return result
end

-- Deterministic single base (first reachable) - kept for any caller that does
-- not want the random pick; the egg filter uses baseFormsOf directly.
function Config.baseFormOf(characterId)
    return (Config.baseFormsOf(characterId))[1]
end

-- Where the mod's scripts folder would find its own config_user.lua, or nil.
-- Both durable locations win over this one, and a mod update replaces the
-- whole folder, so a config kept here is lost on the next update.
local function scriptsConfigPath()
    local found = nil
    pcall(function() found = package.searchpath("config_user", package.path) end)
    return found
end

-- The install's own Saved folder, derived from this file's path:
--   <root>\Pal\Saved\Palvolve
-- On a rented dedicated server this is the only durable spot an admin can
-- reach over FTP: %LocalAppData% belongs to the host's Windows account, and
-- the mod folder is replaced whenever the mod is updated.
-- Cutting at "Binaries" instead of walking up from the Win64 folder keeps
-- every install layout in reach: the game-managed one nests the mod four
-- levels deeper (Win64\Mods\NativeMods\UE4SS\Mods\Palvolve).
local function installSavedDir()
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    local palDir = src:match("^@?(.*)[/\\][Bb]inaries[/\\]")
    if not palDir then
        -- Some loaders hand out a chunk name rather than a path. The module
        -- search knows where this file really came from, and it answers with an
        -- absolute path on every layout tested.
        local found = nil
        pcall(function() found = package.searchpath("config", package.path) end)
        if found then palDir = found:match("^(.*)[/\\][Bb]inaries[/\\]") end
    end
    if not palDir then return nil end
    return palDir .. "\\Saved\\Palvolve"
end

-- Existence is probed separately from loadfile so a file that IS there but
-- does not compile reports its syntax error instead of silently falling
-- through as if nothing had been dropped in the folder.
local function readConfigAt(path)
    local present = io.open(path, "r")
    if not present then return nil end
    present:close()
    local chunk, loadErr = loadfile(path)
    if not chunk then
        print(string.format("[Palvolve] user config at %s does not compile: %s\n",
            path, tostring(loadErr)))
        return nil
    end
    local okChunk, result = pcall(chunk)
    if okChunk and type(result) == "table" then return result end
    print(string.format("[Palvolve] user config at %s did not return a table: %s\n",
        path, tostring(result)))
    return nil
end

-- Makes a drop folder exist so users only have to paste the path; probes
-- first to avoid a shell call on every start.
--- Makes the drop folder exist and says whether it does. It used to try once
--- and never look: a server where os.execute is not allowed to spawn a shell
--- kept reporting nothing at all, and the admin saw no folder and no reason.
local function ensureDir(dir)
    local function writable()
        local probe = io.open(dir .. "\\.palvolve", "w")
        if not probe then return false end
        probe:close()
        os.remove(dir .. "\\.palvolve")
        return true
    end
    if writable() then return true end
    pcall(os.execute, 'mkdir "' .. dir .. '" >nul 2>nul')
    if writable() then return true end
    print(string.format("[Palvolve] could not create %s - create the folder by hand "
        .. "and put config_user.lua in it\n", dir))
    return false
end

-- Optional user overlay: the configurator at palvolve.doodesch.de generates
-- a config_user.lua. It replaces the pair map wholesale and merges a
-- whitelist of globals. Players keep it where they always have:
--   %LocalAppData%\Pal\Saved\Palvolve\config_user.lua
-- A dedicated server cannot reach that account, so it looks in its own install
-- first:
--   <install>\Pal\Saved\Palvolve\config_user.lua
-- Last resort is the mod's own scripts folder, which a mod update wipes.
local function loadUserConfig()
    local checked = {}
    local localAppData = os.getenv("LOCALAPPDATA")
    local appDataDir = localAppData and (localAppData .. "\\Pal\\Saved\\Palvolve") or nil
    -- The install folder is a server-only location. A game client has no
    -- Pal\Saved there at all - it keeps everything, saves included, under
    -- %LocalAppData%, which is where players have always put this file.
    local dirs = {}
    if Role.isDedicated() then
        local installDir = installSavedDir()
        if installDir then
            table.insert(dirs, installDir)
            -- Made to exist before anything is read, not after a failed search.
            -- An admin who already had a config somewhere else never saw this
            -- folder appear, because the lookup below returns on the first hit
            -- and the creation used to sit behind it. The folder is the whole
            -- point on a server: it is the one place FTP reaches that an update
            -- does not replace.
            ensureDir(installDir)
        else
            print("[Palvolve] could not work out where this server is installed, so "
                .. "the update-proof config folder was not created\n")
        end
    end
    if appDataDir then table.insert(dirs, appDataDir) end

    for _, dir in ipairs(dirs) do
        local path = dir .. "\\config_user.lua"
        table.insert(checked, path)
        local result = readConfigAt(path)
        if result then return result, path, checked end
    end
    -- only the folder that side can actually use gets created, so a client
    -- install never grows a stray folder inside the Steam directory
    -- A server already has its folder from above; this is the player's one.
    if not Role.isDedicated() and appDataDir then ensureDir(appDataDir) end

    local fallback = scriptsConfigPath()
    table.insert(checked, fallback or "scripts\\config_user.lua")
    local okReq, result = pcall(require, "config_user")
    if okReq and type(result) == "table" then
        -- The update-proof spot for this side: the install folder on a server,
        -- %LocalAppData% for a player.
        local preferred = dirs[1]
        if preferred then
            print(string.format("[Palvolve] this config sits in the mod folder, where the next "
                .. "mod update replaces it. Update-proof location: %s\\config_user.lua\n", preferred))
        end
        return result, fallback or "scripts", checked
    end
    return nil, nil, checked
end

-- Every setting a config_user.lua may set, and nothing else.
--
-- A whitelist, not a merge: this file is a stranger's data on a dedicated
-- server, and `for k, v in pairs(user)` would let it replace the stone item
-- ids, the schema version or the map loader itself. Naming the keys means a
-- config can only ever move a value inside a range this file chose.
--
-- The website generates exactly these paths from
-- Palvolve-Web/web/src/data/settings.vocab.json, and its
-- scripts/selfcheck-settings.ts reads THIS table to prove the two lists match.
-- A setting the site writes and this table omits would download cleanly and do
-- nothing in game, which is the hardest kind of bug to report.
--
-- kind:
--   bool  anything but true is false
--   int   clamped, then floored (a fraction would reach something that counts)
--   num   clamped, fraction kept (durations and rates: 0.5 s is a real value,
--         and costs.countScale = 1.5 is documented as one)
--   enum  one of `values`, case-insensitively, or the shipped value stands
local USER_KEYS = {
    -- gameplay
    { path = "eggFilter.enabled", kind = "bool" },
    { path = "requireStone", kind = "bool" },
    -- written into the PalSchema building file, where a junk level breaks the
    -- technology entry
    { path = "techLevelCap", kind = "int", min = 1, max = 100 },
    { path = "unlockCatchTech", kind = "bool" },
    { path = "ivBonusPerStage", kind = "int", min = 0, max = 100 },
    { path = "ivCap", kind = "int", min = 0, max = 100 },

    -- costs
    { path = "stoneCount", kind = "int", min = 1, max = 99 },
    { path = "costs.enabled", kind = "bool" },
    { path = "costs.slots", kind = "int", min = 0, max = 10000 },
    { path = "costs.minRate", kind = "num", min = 0, max = 10000 },
    { path = "costs.countScale", kind = "num", min = 0, max = 10000 },
    { path = "costs.maxCount", kind = "int", min = 0, max = 10000 },

    -- multiplayer
    { path = "chatMessages", kind = "enum", values = { "all", "replies", "off" } },
    { path = "net.rateLimitSeconds", kind = "num", min = 0, max = 60 },
    { path = "net.reqIdCacheSize", kind = "int", min = 8, max = 512 },
    { path = "serverCheck.enabled", kind = "bool" },
    { path = "serverCheck.timeoutSeconds", kind = "num", min = 5, max = 300 },

    -- evolution sequence
    { path = "finale.style", kind = "enum", values = { "layered", "legacy" } },
    { path = "finale.maxLiveSystems", kind = "int", min = 1, max = 64 },
    { path = "digimon.elementColors", kind = "bool" },
    { path = "digimon.spinUpMs", kind = "int", min = 0, max = 20000 },
    { path = "digimon.shrinkMs", kind = "int", min = 0, max = 20000 },
    { path = "digimon.growMs", kind = "int", min = 0, max = 20000 },
    { path = "digimon.finaleHoldMs", kind = "int", min = 0, max = 20000 },
    { path = "digimon.peakDegPerSec", kind = "num", min = 0, max = 10000 },

    -- interface and keys
    { path = "treeCloseButton", kind = "bool" },
    { path = "confirmKeyEnabled", kind = "bool" },
    -- An unknown name would reach RegisterKeyBind(Key[name]) as nil and take
    -- the binding down with it, so the list is the one the website offers.
    -- F11 belongs to the game's fullscreen toggle and F12 to Steam.
    { path = "confirmKey", kind = "enum", upper = true, values = {
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
        "INS", "DEL", "HOME", "END", "PAGE_UP", "PAGE_DOWN",
    } },
    { path = "confirmWindowSeconds", kind = "num", min = 1, max = 120 },
    { path = "debounceSeconds", kind = "num", min = 0, max = 5 },

    -- diagnostics: the traces that name a CharacterID sit behind devMode, and
    -- the copy of this file next to the mod belongs to Steam on a Workshop
    -- install, where the next update reverts an edit to it
    { path = "devMode", kind = "bool" },
    { path = "diagReveal", kind = "bool" },
    { path = "finale.debugLog", kind = "bool" },
}

local function readPath(root, path)
    local cur = root
    for part in path:gmatch("[^.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[part]
    end
    return cur
end

local function writePath(root, path, value)
    local parts = {}
    for part in path:gmatch("[^.]+") do parts[#parts + 1] = part end
    local cur = root
    for i = 1, #parts - 1 do
        if type(cur[parts[i]]) ~= "table" then cur[parts[i]] = {} end
        cur = cur[parts[i]]
    end
    cur[parts[#parts]] = value
end

--- Copies the whitelisted settings out of a user config into Config.
---
--- A value that cannot be used is REPORTED, never silently swallowed: the whole
--- point of a config file is that the author believes it took effect, and a typo
--- that produces no line in the log is a support thread that starts from
--- nothing.
local function applyUserKeys(user)
    for _, entry in ipairs(USER_KEYS) do
        local raw = readPath(user, entry.path)
        if raw ~= nil then
            local value, why = nil, nil
            if entry.kind == "bool" then
                value = raw == true
                -- Anything that is not a boolean counts as false, so a quoted
                -- `requireStone = "true"` switches the setting OFF - the one
                -- outcome nobody would look for in their own file.
                if type(raw) ~= "boolean" then
                    why = string.format("expected true or false, read a %s", type(raw))
                end
            elseif entry.kind == "enum" then
                if type(raw) == "string" then
                    local want = entry.upper and raw:upper() or raw:lower()
                    for _, allowed in ipairs(entry.values) do
                        if allowed == want then value = allowed break end
                    end
                    if value == nil then
                        why = string.format("'%s' is not one of %s",
                            raw, table.concat(entry.values, ", "))
                    end
                else
                    why = "expected a string"
                end
            else
                local n = tonumber(raw)
                if n == nil or n ~= n then
                    why = "expected a number"
                else
                    if entry.min and n < entry.min then n = entry.min end
                    if entry.max and n > entry.max then n = entry.max end
                    value = (entry.kind == "int") and math.floor(n) or n
                end
            end

            if value ~= nil then
                writePath(Config, entry.path, value)
                if why then
                    print(string.format("[Palvolve] %s: %s - reading it as %s\n",
                        entry.path, why, tostring(value)))
                end
            else
                print(string.format("[Palvolve] %s: %s - keeping %s\n",
                    entry.path, why or "unusable value", tostring(readPath(Config, entry.path))))
            end
        end
    end
end

local user, userSource, userChecked = loadUserConfig()
if user then
    if type(user.map) == "table" then
        local cleaned = {}
        for _, p in ipairs(user.map) do
            if type(p) == "table" and type(p.from) == "string" and type(p.to) == "string" then
                p.category = p.category or "evolution"
                p.minLevel = tonumber(p.minLevel) or 1
                p.stone = p.stone or (p.category == "adaptation" and "adaptation" or "evolution")
                if p.enabled == nil then p.enabled = true end
                if p.conditions ~= nil then
                    -- unknown ids are dropped (fail open: a config written for
                    -- a newer vocabulary must not brick this pair entirely);
                    -- runtime failures of KNOWN ids fail closed in conditions.lua
                    local clean, dropped = Conditions.sanitize(p.conditions)
                    p.conditions = (#clean > 0) and clean or nil
                    if #dropped > 0 then
                        print(string.format("[Palvolve] %s -> %s: dropped unknown conditions: %s\n",
                            p.from, p.to, table.concat(dropped, ", ")))
                    end
                end
                table.insert(cleaned, p)
            end
        end
        if #cleaned > 0 then
            -- Keep the shipped tree reachable. Two processes running the same
            -- mod version ship the same built-in map, so a client that knows
            -- the host runs the built-in tree already holds it byte for byte
            -- and needs nothing transferred. Dropping the reference here would
            -- make that impossible for anyone who loaded their own config.
            Config.builtinMap = Config.builtinMap or Config.map
            Config.map = cleaned
            evoParentsCache = nil
            -- a user map may name species the shipped list does not
            Config.resetCanonical()
        end
    end
    applyUserKeys(user)
    Config.loadArrangement(user)
    print(string.format("[Palvolve] user config loaded (%d pairs, %s)\n", #Config.map, tostring(userSource)))
    -- Pushed rather than pulled: role.lua is what this file requires, so it
    -- cannot ask back without closing the circle.
    Role.chatMode = Config.chatMessages
    local shadowed = scriptsConfigPath()
    if shadowed and shadowed ~= userSource then
        print(string.format("[Palvolve] a second config_user.lua sits at %s and is IGNORED while the one above loads\n",
            shadowed))
    end
else
    -- Without this line a config that never arrived is indistinguishable from one
    -- that loaded: the mod just runs its built-in tree, and the only symptom is a
    -- species the player configured showing no evolution at all.
    print(string.format("[Palvolve] no user config found, running the built-in tree (%d pairs). Checked: %s\n",
        #Config.map, table.concat(userChecked or {}, ", ")))
end

return Config
