-- Palvolve-Konfiguration: Evolutions-Map und Einstellungen.
-- Kategorien: "evolution" (kleine -> grosse Form), "funchain" (ueber Familiengrenzen),
-- "adaptation" (Elementwechsel). stone: "evolution" | "adaptation" - Item-Kosten greifen
-- erst, wenn die PalSchema-Steine existieren (requireStone=false solange).
--
-- Map-Grundlage: DT_PalMonsterParameter (buildid 24088745), verifizierte Zeilennamen -
-- siehe Workspace/docs/Palvolve/RESEARCH.md. findPair nimmt den ERSTEN enabled-Treffer:
-- Evolutionen stehen deshalb VOR Adaptationen derselben Basis (z.B. Penguin).
-- BOSS_/GYM_/RAID_/_Oilrig/_Tower-IDs duerfen NIE Ziel sein (Boss-/Spawn-Logik).

local Config = {
    -- Dev-Modus: laedt die Probe-Suite (F3/F5-F10/EINFG-Cheats). VOR RELEASE auf false
    -- setzen UND probes.lua nicht paketieren.
    devMode = true,

    -- Zweistufiger Confirm: erster Druck prueft und meldet, zweiter Druck bestaetigt.
    confirmKey = "F2",
    confirmWindowSeconds = 10,
    debounceSeconds = 0.5,

    -- IV-Bonus pro Evolutionsstufe (auf Talent_HP/Melee/Shot/Defense, Cap 100)
    ivBonusPerStage = 5,
    ivCap = 100,

    -- Item-Kosten (Steine existieren via PalSchema; false = Gratis-Modus)
    requireStone = true,
    stoneCount = 1,
    stoneItemIds = {
        evolution = "Palvolve_EvolutionStone",
        adaptation = "Palvolve_AdaptionStone",
    },
    stoneNames = {
        evolution = "Entwicklungsstein",
        adaptation = "Adaptionsstein",
    },

    -- Schema-Version der Map (fuer spaetere Migrationen)
    schemaVersion = 2,
    gameBuild = 24088745,

    map = {
        -- ==================== Echte Evolutionen (kleine -> grosse Form) ====================
        { from = "Penguin",            to = "CaptainPenguin",   category = "evolution", minLevel = 30, stone = "evolution", enabled = true },  -- Pengullet -> Penking
        { from = "MopBaby",            to = "MopKing",          category = "evolution", minLevel = 25, stone = "evolution", enabled = true },  -- Swee -> Sweepa
        { from = "Alpaca",             to = "KingAlpaca",       category = "evolution", minLevel = 35, stone = "evolution", enabled = true },
        { from = "SoldierBee",         to = "QueenBee",         category = "evolution", minLevel = 35, stone = "evolution", enabled = true },
        { from = "SnakeGirl",          to = "SnakeQueen",       category = "evolution", minLevel = 40, stone = "evolution", enabled = true },
        { from = "MoonChild",          to = "MoonQueen",        category = "evolution", minLevel = 40, stone = "evolution", enabled = true },
        { from = "MonochromeMushroom", to = "MonochromeQueen",  category = "evolution", minLevel = 35, stone = "evolution", enabled = true },
        { from = "SmallYeti",          to = "Yeti",             category = "evolution", minLevel = 40, stone = "evolution", enabled = true },

        -- ==================== Fun-Ketten (ueber Familiengrenzen) ====================
        { from = "MopKing",         to = "Yeti",       category = "funchain", minLevel = 45, stone = "evolution", enabled = true },   -- Sweepa -> Wumpo
        -- Thematische Kandidaten (Kuratierungs-Entscheidung, default AUS):
        { from = "Bastet",          to = "Sekhmet",    category = "funchain", minLevel = 45, stone = "evolution", enabled = false },
        { from = "PinkCat",         to = "BadCatgirl", category = "funchain", minLevel = 35, stone = "evolution", enabled = false },
        { from = "SmallArmadillo",  to = "DrillGame",  category = "funchain", minLevel = 30, stone = "evolution", enabled = false },
        { from = "LeafPrincess",    to = "LilyQueen",  category = "funchain", minLevel = 45, stone = "evolution", enabled = false },

        -- ==================== Element-Adaptationen (Basis -> Variante) ====================
        -- Standard-Schwelle 30; alle Paare mechanisch verifiziert (beide Zeilen existieren).
        { from = "AmaterasuWolf",    to = "AmaterasuWolf_Dark",    category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Baphomet",         to = "Baphomet_Dark",         category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Bastet",           to = "Bastet_Ice",            category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "BerryGoat",        to = "BerryGoat_Dark",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "BirdDragon",       to = "BirdDragon_Ice",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "BlackPuppy",       to = "BlackPuppy_Ice",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "BlueDragon",       to = "BlueDragon_Ice",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "BluePlatypus",     to = "BluePlatypus_Fire",     category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "CactusDoll",       to = "CactusDoll_Dark",       category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "CaptainPenguin",   to = "CaptainPenguin_Black",  category = "adaptation", minLevel = 35, stone = "adaptation", enabled = true },
        { from = "CatMage",          to = "CatMage_Fire",          category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "CubeTurtle",       to = "CubeTurtle_Neutral",    category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "DarkScorpion",     to = "DarkScorpion_Ground",   category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Deer",             to = "Deer_Ground",           category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "ElecSnail",        to = "ElecSnail_Fire",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "ElecSnail",        to = "ElecSnail_Ground",      category = "adaptation", minLevel = 30, stone = "adaptation", enabled = false }, -- Alternative zu _Fire
        { from = "FairyDragon",      to = "FairyDragon_Water",     category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "FengyunDeeper",    to = "FengyunDeeper_Electric", category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "FireKirin",        to = "FireKirin_Dark",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "FlowerDinosaur",   to = "FlowerDinosaur_Electric", category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "FlowerDoll",       to = "FlowerDoll_Fire",       category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "FlyingManta",      to = "FlyingManta_Thunder",   category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "FoxMage",          to = "FoxMage_Dark",          category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "GhostAnglerfish",  to = "GhostAnglerfish_Fire",  category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "GhostDragon",      to = "GhostDragon_Fire",      category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "GhostRabbit",      to = "GhostRabbit_Grass",     category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Gorilla",          to = "Gorilla_Ground",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "GrassGolem",       to = "GrassGolem_Dark",       category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "GrassMammoth",     to = "GrassMammoth_Ice",      category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "GrassMinotaur",    to = "GrassMinotaur_Ice",     category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "GrassPanda",       to = "GrassPanda_Electric",   category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "HadesBird",        to = "HadesBird_Electric",    category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Hedgehog",         to = "Hedgehog_Ice",          category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "HerculesBeetle",   to = "HerculesBeetle_Ground", category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Horus",            to = "Horus_Water",           category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "IceHorse",         to = "IceHorse_Dark",         category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "IceNarwhal",       to = "IceNarwhal_Fire",       category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "IceSeal",          to = "IceSeal_Ground",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Kelpie",           to = "Kelpie_Fire",           category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "KendoFrog",        to = "KendoFrog_Dark",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "KingAlpaca",       to = "KingAlpaca_Ice",        category = "adaptation", minLevel = 35, stone = "adaptation", enabled = true },
        { from = "KingBahamut",      to = "KingBahamut_Dragon",    category = "adaptation", minLevel = 40, stone = "adaptation", enabled = true },
        { from = "KingSunfish",      to = "KingSunfish_Thunder",   category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Kirin",            to = "Kirin_Ice",             category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Kitsunebi",        to = "Kitsunebi_Ice",         category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "LazyCatfish",      to = "LazyCatfish_Gold",      category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "LazyDragon",       to = "LazyDragon_Electric",   category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "LilyQueen",        to = "LilyQueen_Dark",        category = "adaptation", minLevel = 35, stone = "adaptation", enabled = true },
        { from = "LizardMan",        to = "LizardMan_Fire",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Manticore",        to = "Manticore_Dark",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Monkey",           to = "Monkey_Fire",           category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Monkey",           to = "Monkey_Ice",            category = "adaptation", minLevel = 30, stone = "adaptation", enabled = false }, -- Alternative zu _Fire
        { from = "MushroomDragon",   to = "MushroomDragon_Dark",   category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "NegativeOctopus",  to = "NegativeOctopus_Neutral", category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "NightBlueHorse",   to = "NightBlueHorse_Neutral", category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "NightLady",        to = "NightLady_Dark",        category = "adaptation", minLevel = 35, stone = "adaptation", enabled = true },
        { from = "OctopusGirl",      to = "OctopusGirl_Neutral",   category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Penguin",          to = "Penguin_Electric",      category = "adaptation", minLevel = 30, stone = "adaptation", enabled = false }, -- von Evolution ueberlagert (findPair-Prioritaet)
        { from = "PinkRabbit",       to = "PinkRabbit_Grass",      category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "PlantSlime",       to = "PlantSlime_Flower",     category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "RaijinDaughter",   to = "RaijinDaughter_Water",  category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "RobinHood",        to = "RobinHood_Ground",      category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "RockBeast",        to = "RockBeast_Ice",         category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Ronin",            to = "Ronin_Dark",            category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "SakuraSaurus",     to = "SakuraSaurus_Water",    category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "ScorpionMan",      to = "ScorpionMan_Electric",  category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Serpent",          to = "Serpent_Ground",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "SharkKid",         to = "SharkKid_Fire",         category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "SkyDragon",        to = "SkyDragon_Grass",       category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "StuffedShark",     to = "StuffedShark_Fire",     category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Suzaku",           to = "Suzaku_Water",          category = "adaptation", minLevel = 40, stone = "adaptation", enabled = true },
        { from = "SweetsSheep",      to = "SweetsSheep_Ground",    category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "SwordCutlassfish", to = "SwordCutlassfish_Fire", category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "TentacleTurtle",   to = "TentacleTurtle_Ground", category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "ThunderBird",      to = "ThunderBird_Ice",       category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "ThunderDog",       to = "ThunderDog_Ice",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Umihebi",          to = "Umihebi_Fire",          category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "VolcanicMonster",  to = "VolcanicMonster_Ice",   category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "VolcanoDragon",    to = "VolcanoDragon_Ice",     category = "adaptation", minLevel = 40, stone = "adaptation", enabled = true },
        { from = "WeaselDragon",     to = "WeaselDragon_Fire",     category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Werewolf",         to = "Werewolf_Ice",          category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "WhiteDeer",        to = "WhiteDeer_Dark",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "WhiteMoth",        to = "WhiteMoth_Neutral",     category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "WhiteTiger",       to = "WhiteTiger_Ground",     category = "adaptation", minLevel = 35, stone = "adaptation", enabled = true },
        { from = "WindChimes",       to = "WindChimes_Ice",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "WingGolem",        to = "WingGolem_Fire",        category = "adaptation", minLevel = 30, stone = "adaptation", enabled = true },
        { from = "Yeti",             to = "Yeti_Grass",            category = "adaptation", minLevel = 45, stone = "adaptation", enabled = true },  -- Wumpo -> Wumpo Botan
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

return Config
