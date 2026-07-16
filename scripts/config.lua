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
    -- Dev mode: loads the probe suite (F3/F5-F10/INSERT cheats, requires
    -- probes.lua) and enables the [diag] sequence telemetry in the log.
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
        -- legacy generic stone: no longer craftable, still accepted whenever
        -- the target element cannot be resolved
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
            -- species without a drop table row (none right now)
        },
    },

    -- Eggs only ever hatch base forms (evolved forms are normalized back to
    -- their base species while hatching); funchain results stay allowed.
    eggFilter = {
        enabled = true,
    },

    -- Map schema version (for future migrations); 4 = per-pair conditions
    schemaVersion = 4,
    gameBuild = 24088745,

    map = { -- ==================== True evolutions (small -> big form) ====================
    {
        from = "Penguin",
        to = "CaptainPenguin",
        category = "evolution",
        minLevel = 30,
        stone = "evolution",
        enabled = true
    }, -- Pengullet -> Penking
    {
        from = "MopBaby",
        to = "MopKing",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        enabled = true
    }, -- Swee -> Sweepa
    {
        from = "Alpaca",
        to = "KingAlpaca",
        category = "evolution",
        minLevel = 35,
        stone = "evolution",
        enabled = true
    }, {
        from = "SoldierBee",
        to = "QueenBee",
        category = "evolution",
        minLevel = 35,
        stone = "evolution",
        enabled = true
    }, {
        from = "MoonChild",
        to = "MoonQueen",
        category = "evolution",
        minLevel = 40,
        stone = "evolution",
        enabled = true
    }, {
        from = "SmallYeti",
        to = "Yeti",
        category = "evolution",
        minLevel = 40,
        stone = "evolution",
        enabled = true
    }, -- ==================== Fun chains (across family lines) ====================
    {
        from = "MopKing",
        to = "SmallYeti",
        category = "funchain",
        minLevel = 45,
        stone = "evolution",
        enabled = true
    }, -- Sweepa -> Snugloo
    -- Thematic candidates (curation decisions, disabled by default):
    {
        from = "Bastet",
        to = "Sekhmet",
        category = "funchain",
        minLevel = 45,
        stone = "evolution",
        enabled = true
    }, {
        from = "PinkCat",
        to = "BadCatgirl",
        category = "funchain",
        minLevel = 35,
        stone = "evolution",
        enabled = true
    }, {
        from = "SmallArmadillo",
        to = "DrillGame",
        category = "funchain",
        minLevel = 30,
        stone = "evolution",
        enabled = true
    }, {
        from = "LeafPrincess",
        to = "LilyQueen",
        category = "funchain",
        minLevel = 45,
        stone = "evolution",
        enabled = true
    }, -- ==================== Element adaptations (base -> variant) ====================
    -- Default threshold 30; both DataTable rows exist for every pair.
    {
        from = "AmaterasuWolf",
        to = "AmaterasuWolf_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Baphomet",
        to = "Baphomet_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Bastet",
        to = "Bastet_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "BerryGoat",
        to = "BerryGoat_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "BirdDragon",
        to = "BirdDragon_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "BlackPuppy",
        to = "BlackPuppy_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "BlueDragon",
        to = "BlueDragon_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "BluePlatypus",
        to = "BluePlatypus_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "CactusDoll",
        to = "CactusDoll_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "CaptainPenguin",
        to = "CaptainPenguin_Black",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, {
        from = "CatMage",
        to = "CatMage_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "CubeTurtle",
        to = "CubeTurtle_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "DarkScorpion",
        to = "DarkScorpion_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Deer",
        to = "Deer_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "ElecSnail",
        to = "ElecSnail_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "ElecSnail",
        to = "ElecSnail_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Snock Lux, alongside _Fire
    {
        from = "FairyDragon",
        to = "FairyDragon_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "FengyunDeeper",
        to = "FengyunDeeper_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "FireKirin",
        to = "FireKirin_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "FlowerDinosaur",
        to = "FlowerDinosaur_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "FlowerDoll",
        to = "FlowerDoll_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "FlyingManta",
        to = "FlyingManta_Thunder",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "FoxMage",
        to = "FoxMage_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "GhostAnglerfish",
        to = "GhostAnglerfish_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "GhostDragon",
        to = "GhostDragon_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "GhostRabbit",
        to = "GhostRabbit_Grass",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Gorilla",
        to = "Gorilla_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "GrassGolem",
        to = "GrassGolem_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "GrassMammoth",
        to = "GrassMammoth_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "GrassMinotaur",
        to = "GrassMinotaur_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "GrassPanda",
        to = "GrassPanda_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "HadesBird",
        to = "HadesBird_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Hedgehog",
        to = "Hedgehog_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "HerculesBeetle",
        to = "HerculesBeetle_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Horus",
        to = "Horus_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "IceHorse",
        to = "IceHorse_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "IceNarwhal",
        to = "IceNarwhal_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "IceSeal",
        to = "IceSeal_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Kelpie",
        to = "Kelpie_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "KendoFrog",
        to = "KendoFrog_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "KingAlpaca",
        to = "KingAlpaca_Ice",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, {
        from = "KingBahamut",
        to = "KingBahamut_Dragon",
        category = "adaptation",
        minLevel = 40,
        stone = "adaptation",
        enabled = true
    }, {
        from = "KingSunfish",
        to = "KingSunfish_Thunder",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Kirin",
        to = "Kirin_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Kitsunebi",
        to = "Kitsunebi_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "LazyCatfish",
        to = "LazyCatfish_Gold",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "LazyDragon",
        to = "LazyDragon_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "LilyQueen",
        to = "LilyQueen_Dark",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, {
        from = "LizardMan",
        to = "LizardMan_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Manticore",
        to = "Manticore_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Monkey",
        to = "Monkey_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Monkey",
        to = "Monkey_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Tanzee Cryst, alongside _Fire
    {
        from = "MushroomDragon",
        to = "MushroomDragon_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "NegativeOctopus",
        to = "NegativeOctopus_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "NightBlueHorse",
        to = "NightBlueHorse_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "NightLady",
        to = "NightLady_Dark",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, {
        from = "OctopusGirl",
        to = "OctopusGirl_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Penguin",
        to = "Penguin_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Pengullet Lux, alongside the Penking evolution
    {
        from = "Penguin_Electric",
        to = "CaptainPenguin_Black",
        category = "evolution",
        minLevel = 30,
        stone = "evolution",
        enabled = true
    }, -- Pengullet Lux -> Penking Lux
    {
        from = "PinkRabbit",
        to = "PinkRabbit_Grass",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "PlantSlime",
        to = "PlantSlime_Flower",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "RaijinDaughter",
        to = "RaijinDaughter_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "RobinHood",
        to = "RobinHood_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "RockBeast",
        to = "RockBeast_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Ronin",
        to = "Ronin_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "SakuraSaurus",
        to = "SakuraSaurus_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "ScorpionMan",
        to = "ScorpionMan_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Serpent",
        to = "Serpent_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "SharkKid",
        to = "SharkKid_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "SkyDragon",
        to = "SkyDragon_Grass",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "StuffedShark",
        to = "StuffedShark_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Suzaku",
        to = "Suzaku_Water",
        category = "adaptation",
        minLevel = 40,
        stone = "adaptation",
        enabled = true
    }, {
        from = "SweetsSheep",
        to = "SweetsSheep_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "SwordCutlassfish",
        to = "SwordCutlassfish_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "TentacleTurtle",
        to = "TentacleTurtle_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "ThunderBird",
        to = "ThunderBird_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "ThunderDog",
        to = "ThunderDog_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Umihebi",
        to = "Umihebi_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "VolcanicMonster",
        to = "VolcanicMonster_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "VolcanoDragon",
        to = "VolcanoDragon_Ice",
        category = "adaptation",
        minLevel = 40,
        stone = "adaptation",
        enabled = true
    }, {
        from = "WeaselDragon",
        to = "WeaselDragon_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Werewolf",
        to = "Werewolf_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "WhiteDeer",
        to = "WhiteDeer_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "WhiteMoth",
        to = "WhiteMoth_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "WhiteTiger",
        to = "WhiteTiger_Ground",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, {
        from = "WindChimes",
        to = "WindChimes_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "WingGolem",
        to = "WingGolem_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, {
        from = "Yeti",
        to = "Yeti_Grass",
        category = "adaptation",
        minLevel = 45,
        stone = "adaptation",
        enabled = true
    } -- Wumpo -> Wumpo Botan
    }
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
