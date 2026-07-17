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

local Config = {
    -- Dev mode: enables the diagnostic key bindings (probes.lua) and the
    -- [diag] sequence telemetry in the log.
    devMode = false,

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
                               -- (dissolve = old form, reveal = target form)
    },

    -- Two-stage confirm: first press checks and announces, second press confirms.
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

    -- Eggs only ever hatch base forms (evolved forms are normalized back to
    -- their base species while hatching); funchain results stay allowed.
    eggFilter = {
        enabled = true,
    },

    -- Map schema version; 4 = per-pair conditions
    schemaVersion = 4,
    -- Palworld revision: the trailing digits of the title-screen version
    -- (v1.0.1.100619 -> 619), the identifier the official mod loader uses
    gameBuild = 619,

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

function Config.findPair(characterId)
    for _, pair in ipairs(Config.map) do
        if pair.enabled and pair.from == characterId then
            return pair
        end
    end
    return nil
end

-- ALL enabled options for a species (evolution + adaptations) - the choice
-- menu presents these filtered by affordability.
function Config.findPairs(characterId)
    local result = {}
    for _, pair in ipairs(Config.map) do
        if pair.enabled and pair.from == characterId then
            table.insert(result, pair)
        end
    end
    return result
end

-- Reverse map for the egg filter: evolved/adapted form -> base form, walked
-- transitively (Yeti -> SmallYeti). Funchain links are excluded so cross-
-- family results (MopKing -> Yeti) do not normalize into the wrong family.
-- Disabled pairs count too: an egg of a disabled target still normalizes.
local baseFormCache = nil
function Config.baseFormOf(characterId)
    if baseFormCache == nil then
        local parentOf = {}
        for _, pair in ipairs(Config.map) do
            if pair.category ~= "funchain" and not parentOf[pair.to] then
                parentOf[pair.to] = pair.from
            end
        end
        baseFormCache = {}
        for child, _ in pairs(parentOf) do
            local seen = { [child] = true }
            local cur = child
            while parentOf[cur] and not seen[parentOf[cur]] do
                cur = parentOf[cur]
                seen[cur] = true
            end
            baseFormCache[child] = cur
        end
    end
    return baseFormCache[characterId]
end

-- Optional user overlay: the configurator at palvolve.doodesch.de generates
-- a config_user.lua. It replaces the pair map wholesale and merges a
-- whitelist of globals. Preferred location (identical on every PC, works for
-- Workshop installs where the mod folder is managed by Steam):
--   %LocalAppData%\Pal\Saved\Palvolve\config_user.lua
-- Fallback: next to this file. Mod updates never touch the user file.
local function loadUserConfig()
    local localAppData = os.getenv("LOCALAPPDATA")
    if localAppData then
        local dir = localAppData .. "\\Pal\\Saved\\Palvolve"
        local path = dir .. "\\config_user.lua"
        local chunk = loadfile(path)
        if chunk then
            local okChunk, result = pcall(chunk)
            if okChunk and type(result) == "table" then return result, path end
        else
            -- make the documented drop folder exist so users only have to
            -- paste the path; probe first to avoid a shell call on every start
            local probe = io.open(dir .. "\\.palvolve", "w")
            if probe then
                probe:close()
                os.remove(dir .. "\\.palvolve")
            else
                pcall(os.execute, 'mkdir "' .. dir .. '" >nul 2>nul')
            end
        end
    end
    local okReq, result = pcall(require, "config_user")
    if okReq and type(result) == "table" then return result, "scripts" end
    return nil
end

local user, userSource = loadUserConfig()
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
            Config.map = cleaned
            baseFormCache = nil
        end
    end
    if type(user.eggFilter) == "table" and user.eggFilter.enabled ~= nil then
        Config.eggFilter.enabled = user.eggFilter.enabled == true
    end
    if user.requireStone ~= nil then
        Config.requireStone = user.requireStone == true
    end
    if type(user.costs) == "table" then
        for _, k in ipairs({ "enabled", "slots", "minRate", "countScale", "maxCount" }) do
            if user.costs[k] ~= nil then Config.costs[k] = user.costs[k] end
        end
    end
    print(string.format("[Palvolve] user config loaded (%d pairs, %s)\n", #Config.map, tostring(userSource)))
end

return Config
