-- Palvolve display names for Pals: the game's own localized name, cached, with
-- the fallbacks for species the game has no text for.

local Config = require("config")
local FusionRules = require("fusionrules")
local GameLoop = require("gameloop")
local I18n = require("i18n")

local EvoNames = {}

local MOD_NAME = "Palvolve"
local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- Localized pal display name via the game's own text system (returns the
-- raw character id when the lookup fails). GetLocalizedText has a plain
-- return value, which works from Lua - unlike out-params in this build.
-- Used for radial labels AND every player-facing message, so the chat
-- reasons show "Pengullet Lux", never "Penguin_Electric".
local displayNameCache = {}
--- Is there a world to ask. The text system answers through the local player
--- character, and in the main menu there is none - every name then costs a
--- reflection round trip, fails, is not cached, and is asked again on the next
--- pass. Hundreds of those per menu screen are the cost, and the log fills with
--- FAIL lines that say nothing.
-- The text system needs two objects, and both are the same for a whole world:
-- the local character and the master data utility. Looking them up per name is
-- what made a name cost milliseconds, because FindFirstOf walks the object
-- list every time and a single tree page asks for two dozen names. Held here
-- and revalidated, so a page pays for one lookup instead of two per Pal.
EvoNames.cachedNameCtx = nil
EvoNames.cachedNameMdt = nil
local function nameLookupPair()
    if not (EvoNames.cachedNameCtx and EvoNames.cachedNameCtx:IsValid()) then
        EvoNames.cachedNameCtx = FindFirstOf("PalPlayerCharacter")
    end
    if not (EvoNames.cachedNameCtx and EvoNames.cachedNameCtx:IsValid()) then return nil, nil end
    if not (EvoNames.cachedNameMdt and EvoNames.cachedNameMdt:IsValid()) then
        EvoNames.cachedNameMdt = StaticFindObject("/Script/Pal.Default__PalMasterDataTablesUtility")
    end
    if not (EvoNames.cachedNameMdt and EvoNames.cachedNameMdt:IsValid()) then return nil, nil end
    return EvoNames.cachedNameMdt, EvoNames.cachedNameCtx
end
local function worldIsUp()
    if EvoNames.cachedNameCtx and EvoNames.cachedNameCtx:IsValid() then return true end
    local pc = FindFirstOf("PalPlayerCharacter")
    if pc and pc:IsValid() then
        EvoNames.cachedNameCtx = pc
        return true
    end
    return false
end
local function palDisplayName(id)
    local cached = displayNameCache[id]
    if cached then return cached end
    if not worldIsUp() then return id end
    -- Alphas carry a BOSS_ prefix that the text table does not know: it keys
    -- one entry per species, exactly like the Palpedia. Asking for the prefixed
    -- key returns the key itself ("PAL_NAME_BOSS_CubeTurtle_Neutral"), so the
    -- prefix is stripped for the lookup while the cache stays keyed by the
    -- original id.
    local lookupId = id:gsub("^BOSS_", "")
    local name = nil
    local function ask()
        pcall(function()
            local mdt, ctx = nameLookupPair()
            if not (mdt and ctx) then return end
            -- EPalLocalizeTextCategory::PalMonsterName = 4
            local txt = mdt:GetLocalizedText(ctx, 4, FName("PAL_NAME_" .. lookupId))
            if txt then
                local s = txt:ToString()
                -- An unknown key comes back as the key. Treating that as a name
                -- would also cache it, so the raw key would stick for the session.
                if s and s ~= "" and s:sub(1, 9) ~= "PAL_NAME_" then name = s end
            end
        end)
    end
    ask()
    if not name then
        -- The two objects the lookup rides on are held between calls, and a
        -- held character does not survive its player leaving: on a server that
        -- turned every name into its raw id from the first disconnect onwards.
        -- IsValid still answers yes for an object that is on its way out, so
        -- the only reliable signal is the lookup itself failing.
        EvoNames.cachedNameCtx, EvoNames.cachedNameMdt = nil, nil
        ask()
    end
    -- Gym leaders, predators, raid and quest Pals carry ids like GYM_ElecPanda
    -- or Quest_Farmer03_PinkCat that have no name row of their own; they are
    -- named as the species they are a variant of.
    if not name then
        local base = FusionRules.baseSpecies(id)
        if base and base ~= lookupId then
            lookupId = base
            ask()
        end
    end
    -- Five species have no PAL_NAME_ row at all, so no amount of retrying
    -- produces a name and the raw CharacterID was what the wheel showed. Their
    -- names are baked per language from the same source the website uses.
    if not name then name = I18n.palName(id) or I18n.palName(lookupId) end
    if Config.devMode then
        Log(string.format("[radial] name lookup %s -> %s", id, name or "FAIL"))
    end
    -- only successful lookups are cached so an early call (no world yet)
    -- retries later; the cache resets with the Lua state on restart
    if name then displayNameCache[id] = name end
    return name or id
end
-- Warms the submenu labels while the MAIN wheel is still open: the localized
-- name lookups cost ~30 ms each on first use, so doing them here means the
-- Evolve click later builds its options from the cache without delay.
-- The loop is bounded per species and ends after one pass over the list.
local warmedNames = {}
local function prewarmNames(id)
    if warmedNames[id] then return end
    -- Nothing to warm without a world: the names would all miss, and missing
    -- names are not remembered, so the pass would be pure cost.
    if not worldIsUp() then return end
    warmedNames[id] = true
    local pairList = Config.findPairs(id)
    if #pairList == 0 then return end
    local i = 0
    GameLoop.start(100, function()
        i = i + 1
        local pair = pairList[i]
        if not pair then return true end
        local ok, err = pcall(palDisplayName, pair.to)
        if not ok then Log("[WARN] [radial] name prewarm for " .. tostring(pair.to) .. " failed: " .. tostring(err)) end
        return false
    end, "name prewarm")
end

EvoNames.displayNameCache = displayNameCache
EvoNames.nameLookupPair = nameLookupPair
EvoNames.worldIsUp = worldIsUp
EvoNames.palDisplayName = palDisplayName
EvoNames.warmedNames = warmedNames
EvoNames.prewarmNames = prewarmNames

return EvoNames
