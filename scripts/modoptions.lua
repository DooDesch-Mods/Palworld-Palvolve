-- Palvolve in-game options: the Mod Options Framework (MOF) consumer side.
--
-- OPTIONAL integration by design. The framework is a separate mod; when it is
-- absent, stale or malformed this module registers nothing, says so in one
-- line, and the mod behaves exactly as it does with config.lua alone. No path
-- in this file may ever be able to break startup or a running session - every
-- risky step is pcall'd and every failure is a log line, never an error.
--
-- Three laws the framework's API document states and this file obeys:
--   * register_when_ready delivers its callback EXACTLY ONCE, inside a finite
--     ~3.85s startup window. Never wrap it in a retry loop of our own - the
--     SDK already owns the retry ladder and the session-race recovery.
--   * There are no push callbacks. Values are PULLED, and a change is
--     announced only by a generation counter, which we read from events we
--     ALREADY own (ModOptions.pump). The API forbids adding a LoopAsync/timer/
--     frame watcher just to watch settings; the house rules forbid a new
--     LoopAsync anyway. pump therefore has FIVE independent drivers - three
--     pollers plus two player actions - because a poller can be switched off
--     by a row in this very menu; see the comment on ModOptions.pump.
--   * Schema rejection is INVISIBLE - the SDK still hands us a settings table
--     when the framework threw the manifest away. So everything checkable is
--     checked HERE before registering (validateSchema below), and the
--     `constraints` feature is not used at all: one constraint failure at
--     load resets EVERY value in the framework's file back to defaults.
--
-- WHY THE CACHE FILE. The callback lands long after this mod's synchronous
-- startup has finished, but the options that ARM hooks (auto-evolve, the wild
-- filter, the Palpedia tab...) have to be right at init time. So an APPLIED
-- value - and only ever a deliberately applied one, never a value we merely
-- handed the framework as a seed - is mirrored into options_cache.lua beside
-- config_user.lua, and config.lua reads it as its top layer on the next launch:
--   config.lua defaults  <-  config_user.lua  <-  in-game options (top)
-- That, and nothing else, is what "Next launch." on a row means.
--
-- AUTHORITY. Options are LOCAL, per-client and carry zero authority: the
-- framework's file is a UI file, never multiplayer truth. Host-only rows say
-- so in their description - on a connected client they change that client's
-- copy of Config and the host keeps deciding the world.

local Config = require("config")

local ModOptions = {}

local MOD_NAME = "Palvolve"
local SCHEMA_ID = "Palvolve-Fork"     -- stable forever: it names the framework's
                                      -- settings file (<id>.ini)
local SCHEMA_VERSION = 1100           -- integer, tracks Config.modVersion 1.10.0.
                                      -- PURELY INFORMATIONAL: the framework
                                      -- writes it into a comment line at the top
                                      -- of <id>.ini and never reads or compares
                                      -- it on load, so bumping it migrates
                                      -- nothing - it only labels the file for a
                                      -- human reading a support log
local DARN_SCHEMA_VERSION = 1         -- the SECOND menu's schema version, used
                                      -- by darnmenu.lua. Declared HERE, beside
                                      -- its twin, because the two menus render
                                      -- the same ROWS table below.
                                      -- Unlike SCHEMA_VERSION this one is
                                      -- LOAD-BEARING, but it now does ONE job:
                                      -- it is the "do not clobber a NEWER
                                      -- generation" guard on the shared file
                                      -- (a future build's page is left alone).
                                      -- Content changes at the SAME version are
                                      -- caught by the content fingerprint
                                      -- darnmenu.lua writes into the generated
                                      -- file, so a row edit that forgets the
                                      -- bump no longer strands a stale page -
                                      -- which it used to, because the gate was
                                      -- the version alone and this page's
                                      -- content also moves with runtime state
                                      -- (caps flags, dropped keycapture rows)
local CACHE_FILE = "options_cache.lua"
local PUMP_INTERVAL_S = 2.0           -- floor between two generation reads

local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- The SDK is a plain file we ship (PalModOptionsClient.lua + pmo_json.lua).
-- A missing or broken copy is not fatal: Options stays nil and every entry
-- point below turns into a no-op.
local Options = nil
do
    local okSdk, sdk = pcall(require, "PalModOptionsClient")
    if okSdk and type(sdk) == "table"
        and type(sdk.register_when_ready) == "function" then
        Options = sdk
    else
        Log("[options] client SDK unavailable ("
            .. tostring(sdk) .. ") - in-game menu disabled")
    end
end

-- ------------------------------------------------------------------- rows
-- The row `key` IS the dotted path into Config: that identity is the whole
-- key -> config mapping, so there is no second table to keep in step and no
-- way for a key to point at the wrong setting. `mode` is ours, never emitted:
--   "live"    - the value is read at its use site, so it lands immediately
--   "restart" - the value was consumed once at arm time; it reaches the game
--               through the cache file at the next launch
-- Every `default` below is the SHIPPED config.lua default (verified against
-- it), NOT the running value: the framework's "Restore Defaults" must give
-- the player the released behaviour, and initial_values (built further down)
-- is what mirrors their current file into a first-time menu.
local ROWS = {
    { key = "section.evolution", type = "section", label = "Evolution" },
    {
        key = "autoEvolve.enabled", type = "boolean", default = true,
        mode = "restart", label = "Auto-Evolve",
        desc = "Next launch. Only free pairs; costed ones never auto-fire.",
    },
    {
        key = "autoEvolve.basePals", type = "boolean", default = true,
        mode = "restart", label = "Base Workers Auto-Evolve",
        desc = "Next launch. Host only. Workers transform where they stand.",
    },
    {
        key = "autoEvolve.cooldownSeconds", type = "integer", default = 30,
        minimum = 0, maximum = 600, step = 5,
        mode = "live", label = "Auto-Evolve Cooldown (s)",
        desc = "Per pal. The default outlasts the longest sequence.",
    },
    {
        key = "withdrawCancels", type = "boolean", default = true,
        mode = "live", label = "Withdraw Cancels Evolution",
        desc = "Refunds the stone and materials. Not on a co-op client.",
    },
    {
        key = "unlockCatchTech", type = "boolean", default = true,
        mode = "live", label = "Unlock Catch Techs",
        desc = "Evolving counts as a capture: saddle and Pal gear unlock.",
    },
    {
        key = "evolveProtection.enabled", type = "boolean", default = true,
        mode = "live", label = "Transformation Protection",
        desc = "The pal cannot be killed mid-sequence and ends at full HP.",
    },
    {
        key = "confirmKey", type = "keybind", default = "F2",
        mode = "restart", label = "Confirm Key",
        desc = "Next launch. First press announces, second confirms.",
    },

    { key = "section.wild", type = "section", label = "Wild World" },
    {
        key = "primedPals.enabled", type = "boolean", default = true,
        mode = "restart", label = "Primed Pals",
        desc = "Next launch. Host only. Hurt one in a fight and it evolves.",
    },
    {
        key = "primedPals.chance", type = "integer", default = 10,
        minimum = 0, maximum = 100, step = 1,
        mode = "live", label = "Primed Chance (%)",
        desc = "Host only. The roll is fixed per pal and survives a reload.",
    },
    {
        key = "primedPals.hpThreshold", type = "number", default = 0.35,
        minimum = 0.05, maximum = 1.0, step = 0.05,
        mode = "live", label = "Primed HP Threshold",
        desc = "Host only. HP fraction a primed wild pal evolves below.",
    },
    {
        key = "primedPals.telegraphMs", type = "integer", default = 1800,
        minimum = 400, maximum = 10000, step = 100,
        mode = "live", label = "Primed Telegraph (ms)",
        desc = "Host only. Sphere it in this window for the UN-evolved form.",
    },
    {
        key = "wildLevelLimit.enabled", type = "boolean", default = true,
        mode = "restart", label = "Wild Level Limit",
        desc = "Next launch. Host only. Fixed at spawn, before you see it.",
    },
    {
        key = "wildLevelLimit.mode", type = "enum", default = "devolve",
        choices = {
            { value = "devolve",    label = "Devolve to the allowed stage" },
            { value = "levelFloor", label = "Raise the level instead" },
        },
        mode = "restart", label = "Wild Limit Mode",
        desc = "Next launch. Host only. How the limit above is applied.",
    },
    {
        key = "wildLevelLimit.genderFaithful", type = "boolean", default = true,
        mode = "restart", label = "Gender-Faithful Spawns",
        desc = "Next launch. Host only. One-gender lines spawn that gender.",
    },
    {
        key = "wildLevelLimit.npcOtomo", type = "boolean", default = true,
        mode = "restart", label = "Apply to NPC Pals",
        desc = "Next launch. Host only. Guards and merchants; not story NPCs.",
    },
    {
        key = "wildLevelLimit.exemptAlphas", type = "boolean", default = true,
        mode = "restart", label = "Exempt Alphas",
        desc = "Next launch. Host only. Field bosses keep the game's roll.",
    },
    {
        key = "wildLevelLimit.includeAdaptations", type = "boolean",
        default = true, mode = "restart", label = "Include Adaptations",
        desc = "Next launch. Host only. Adaptations count as evolutions here.",
    },

    { key = "section.eggs", type = "section", label = "Eggs" },
    {
        key = "eggFilter.enabled", type = "boolean", default = true,
        mode = "restart", label = "Egg Filter",
        desc = "Next launch. Host only. Eggs only ever hatch base forms.",
    },
    {
        key = "eggFilter.gateCrossAdaptations", type = "boolean", default = true,
        mode = "restart", label = "Gate Cross-Species Adaptations",
        desc = "Next launch. Host only. Same-species variants stay exempt.",
    },

    { key = "section.prompts", type = "section", label = "Prompts" },
    {
        key = "evolveNotify.enabled", type = "boolean", default = true,
        mode = "live", label = "Evolution Prompts",
        desc = "Your own pals only; wild and primed ones stay silent.",
    },
    {
        key = "evolveNotify.chatFallback", type = "boolean", default = true,
        mode = "live", label = "Chat Line Backup",
        desc = "A private line, because a mod cannot see the notice land.",
    },
    {
        key = "evolveNotify.flavorLine", type = "boolean", default = true,
        mode = "live", label = "Pre-Evolution Beat",
        desc = "The anime beat: \"What's this? <name> is evolving?\"",
    },
    {
        key = "evolveNotify.flavorLeadMs", type = "integer", default = 1500,
        minimum = 0, maximum = 5000, step = 100,
        mode = "live", label = "Beat Lead Time (ms)",
        desc = "0 keeps the line but removes the pause.",
    },
    {
        -- Inert without the DarnToasts mod installed, which is why it ships
        -- on. Style, position and the MUTES live on that mod's own Toasts page
        -- - this row only decides whether we hand it the line. Muting us THERE
        -- (per-mod toggle, mods list, or the master "Toasts enabled" switch) is
        -- full silence on the HUD by our own policy: the chat line stays, which
        -- is why the desc names it (see channelMuted in darntoasts.lua).
        key = "evolveNotify.darnToasts", type = "boolean", default = true,
        mode = "live", label = "DarnToasts Delivery",
        desc = "Toasts via DarnToasts, else vanilla; muted there = chat only.",
    },

    { key = "section.presentation", type = "section", label = "Presentation" },
    {
        key = "finale.style", type = "enum", default = "layered",
        choices = {
            { value = "layered", label = "Layered (recipe-driven)" },
            { value = "legacy",  label = "Legacy burst rosette" },
        },
        mode = "live", label = "Grand Finale Style",
        desc = "The effect stack at the reveal.",
    },
    {
        key = "digimon.elementColors", type = "boolean", default = true,
        mode = "live", label = "Element Colors",
        desc = "Old form's element on dissolve, new form's at reveal.",
    },

    { key = "section.menus", type = "section", label = "Menus" },
    {
        key = "palpediaEvolutions.enabled", type = "boolean", default = true,
        mode = "restart", label = "Palpedia Evolutions Tab",
        desc = "Next launch. Beside Stats and Habitat; each target's needs.",
    },
    {
        key = "palpediaEvolutions.toggleKey", type = "keybind", default = "V",
        mode = "restart", label = "Palpedia Tab Key",
        desc = "Next launch. Acts only while the Palpedia is open.",
    },
    {
        key = "palpediaEvolutions.textScale", type = "number", default = 0.8,
        minimum = 0.4, maximum = 1.5, step = 0.05,
        mode = "live", label = "Palpedia Text Scale",
        desc = "1 is the game's own size. The tab label never scales.",
    },
    {
        key = "statusEvolutions.enabled", type = "boolean", default = false,
        mode = "restart", label = "Status Page Evolutions",
        desc = "Next launch. Superseded by the Palpedia tab above.",
    },

    { key = "section.costs", type = "section", label = "Costs & Naming" },
    {
        -- RESTART, even though the flag itself is only read at price time:
        -- Costs.resolve memoizes each price list into resolveCache and reads
        -- Config.requireStone INSIDE that cached computation, so a live flip
        -- would keep serving prices built under the old answer - and the
        -- auto-evolve free-set derives from resolve too, so a stale list also
        -- decides what may auto-fire.
        key = "requireStone", type = "boolean", default = true,
        mode = "restart", label = "Require Evolution Stones",
        desc = "Next launch. Evolutions charge their stone cost.",
    },
    {
        -- restart for the same reason as requireStone: read inside
        -- Costs.resolve's memoized body, and nothing clears resolveCache
        -- mid-session - a live flip would serve stale price lists.
        key = "costs.enabled", type = "boolean", default = false,
        mode = "restart", label = "Material Costs",
        desc = "Next launch. Adds drop-table material bills.",
    },
    {
        key = "stoneNames.primedNaming", type = "boolean", default = true,
        mode = "restart", label = "Primed Stone Naming",
        desc = "Next launch. Stones become Unprimed / Primed Evolution Stone.",
    },

    { key = "section.advanced", type = "section", label = "Advanced" },
    {
        key = "worksuitRefresh", type = "boolean", default = true,
        mode = "live", label = "Work Suitability Refresh",
        desc = "Native companion switches work to the new species at the swap.",
    },
    {
        key = "techLevelCap", type = "integer", default = 10,
        minimum = 1, maximum = 100, step = 1,
        mode = "restart", label = "Workbench Unlock Level",
        desc = "Next launch. The stage shown catches up one launch later.",
    },
    {
        -- LIVE, but only half of what it drives is: the extra log detail is
        -- read at its use sites, while probes.lua, the census module and the
        -- per-tick telemetry loops are decided once at init (main.lua) and
        -- cannot be started mid-session. The description says so.
        key = "devMode", type = "boolean", default = false,
        mode = "live", label = "Developer Logging",
        desc = "Extra log detail immediately; diagnostic modules next launch.",
    },
}

-- The row INDEX (every non-section row, in declaration order and by key) plus
-- the initial_values seed we handed the framework. Declared here so every
-- closure below closes over the same upvalue - SEED in particular is read again
-- in the init callback, where it is the yardstick for "the player has never
-- applied anything".
local VALUE_ROWS = {}
local ROW_BY_KEY = {}
local SEED = {}
local registered = false
local generation = 0
local lastPumpAt = 0
local restartAnnounced = {}
local applyFailed = false
local pumpFailed = false   -- one-shot for the sync path, see ModOptions.pump
local cacheRefusedLogged = false  -- one-shot for writeCache's truncation guard

-- Built at LOAD, not by buildSchema: writeCache, applyValues and darnmenu.lua's
-- mirror all walk this index, and none of them may depend on whether the MOF
-- SDK loaded or whether register_when_ready was ever reached. buildSchema still
-- decides what to EMIT to the framework - a keybind row it drops is missing
-- from the manifest but still indexed here, which changes nothing for the MOF
-- paths (the framework never sends a key it was never told about, so every one
-- of them skips the row on a nil) and lets the OTHER menu render it if its own
-- allow-list is happy with the name.
local function indexRows()
    VALUE_ROWS, ROW_BY_KEY = {}, {}
    for _, row in ipairs(ROWS) do
        if row.type ~= "section" then
            VALUE_ROWS[#VALUE_ROWS + 1] = row
            ROW_BY_KEY[row.key] = row
        end
    end
end
indexRows()

-- --------------------------------------------------------------- utilities

-- The framework's OWN keybind allow-list, copied verbatim from the SDK's
-- file-local `valid_keybinds` (PalModOptionsClient.lua ~44-63, itself a copy of
-- main.lua's `keybind_by_name` ~44-72). It is NOT exported, so it has to live
-- here - and it MUST TRACK the framework's table: a name the framework does not
-- know is rejected by valid_keybind_name() and takes the WHOLE schema down
-- invisibly. UE4SS's own Key table is a strict SUPERSET of this list
-- (LEFT_ALT, LEFT_SHIFT, SEMI_COLON, GRAVE_ACCENT, the mouse buttons, OEM_*
-- ...), which is exactly the trap: those names index Key just fine and would
-- sail past a Key-only check.
local FRAMEWORK_KEYBINDS = {}
do
    for index = 1, 24 do
        FRAMEWORK_KEYBINDS["F" .. tostring(index)] = true
    end
    for code = string.byte("A"), string.byte("Z") do
        FRAMEWORK_KEYBINDS[string.char(code)] = true
    end
    for _, name in ipairs({
        "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN",
        "EIGHT", "NINE", "NUM_ZERO", "NUM_ONE", "NUM_TWO", "NUM_THREE",
        "NUM_FOUR", "NUM_FIVE", "NUM_SIX", "NUM_SEVEN", "NUM_EIGHT",
        "NUM_NINE", "BACKSPACE", "TAB", "RETURN", "PAUSE", "CAPS_LOCK",
        "SPACE", "PAGE_UP", "PAGE_DOWN", "END", "HOME", "LEFT_ARROW",
        "UP_ARROW", "RIGHT_ARROW", "DOWN_ARROW", "PRINT_SCREEN", "INS",
        "DEL", "MULTIPLY", "ADD", "SUBTRACT", "DECIMAL", "DIVIDE",
        "NUM_LOCK", "SCROLL_LOCK",
    }) do
        FRAMEWORK_KEYBINDS[name] = true
    end
end

-- Both halves of the framework's valid_keybind_name(), in its order: the name
-- must be in the allow-list above FIRST, and only then does the running UE4SS
-- build have to know it. Every keybind default and every keybind VALUE goes
-- through here - row defaults (buildSchema drops a failing row), coerce (values
-- on their way into Config) and, through coerce/strict, the initial_values
-- seed, so a name the framework would reject can never reach the manifest by
-- any route. All three clauses of the framework's valid_keybind_name are
-- mirrored - allow-list, Key IS A TABLE, and a numeric code - because a Key
-- that is present but not a table would pass a laxer check here and be
-- rejected invisibly there. Indexing Key stays pcall'd for the build that
-- lacks the global entirely.
local function keyIsLive(name)
    if type(name) ~= "string" or name == "" then return false end
    if not FRAMEWORK_KEYBINDS[name] then return false end
    local okT, isTable = pcall(function() return type(Key) == "table" end)
    if not (okT and isTable) then return false end
    local ok, code = pcall(function() return Key[name] end)
    return ok and type(code) == "number"
end

-- Dotted key -> (owning table, final key). Answers nil unless every parent
-- table AND the leaf already exist: the menu may only overwrite settings
-- config.lua actually declares, never invent a key or a subtable.
local function slotOf(path)
    local t, last = Config, nil
    for part in path:gmatch("[^.]+") do
        if last ~= nil then
            t = t[last]
            if type(t) ~= "table" then return nil end
        end
        last = part
    end
    if last == nil or t[last] == nil then return nil end
    return t, last
end

-- Coerce + CLAMP, for values on their way into Config. Out-of-range numbers
-- are pulled to the edge rather than dropped: the framework already refuses
-- to store one, so this only ever matters for a hand-edited file.
local function coerce(row, value)
    local t = row.type
    if t == "boolean" then
        if type(value) == "boolean" then return value end
        return nil
    elseif t == "integer" or t == "number" then
        local n = tonumber(value)
        if n == nil or n ~= n or n == math.huge or n == -math.huge then
            return nil
        end
        if t == "integer" then n = math.floor(n + 0.5) end
        if row.minimum and n < row.minimum then n = row.minimum end
        if row.maximum and n > row.maximum then n = row.maximum end
        return n
    elseif t == "enum" then
        if type(value) ~= "string" then return nil end
        for _, choice in ipairs(row.choices) do
            if choice.value == value then return value end
        end
        return nil
    elseif t == "keybind" then
        return keyIsLive(value) and value or nil
    end
    return nil
end

-- Coerce with NO clamping, exactly as the SDK's normalize_value judges a
-- value: range AND step grid. Used to prove initial_values before emitting -
-- a single value the framework rejects there kills the whole schema silently.
local function strict(row, value)
    local v = coerce(row, value)
    if v == nil then return nil end
    if row.type ~= "integer" and row.type ~= "number" then return v end
    -- against the RAW number, not the clamped one: clamping is what we are
    -- checking for here
    local raw = tonumber(value)
    if raw == nil then return nil end
    if row.type == "integer" and math.abs(raw - v) > 1e-7 then return nil end
    if row.minimum and raw < row.minimum - 1e-7 then return nil end
    if row.maximum and raw > row.maximum + 1e-7 then return nil end
    if row.step and row.step > 0 then
        local ticks = (v - (row.minimum or 0)) / row.step
        if math.abs(ticks - math.floor(ticks + 0.5)) > 1e-6 then return nil end
    end
    return v
end

-- Pull a number onto the row's step grid (and back inside the range), so a
-- config_user value between two ticks can still seed the menu.
local function snap(row, n)
    local step = row.step
    if not step or step <= 0 then return n end
    local origin = row.minimum or 0
    n = origin + math.floor((n - origin) / step + 0.5) * step
    if row.maximum and n > row.maximum then n = n - step end
    if row.minimum and n < row.minimum then n = row.minimum end
    if row.type == "integer" then n = math.floor(n + 0.5) end
    return n
end

-- ------------------------------------------------------------- cache file
-- The third config layer, written on every successful apply and read by
-- config.lua at the next launch. Executable Lua on purpose: config.lua
-- already owns a loadfile route for config_user.lua and reuses it here, and
-- the file is ours alone - nothing else reads or ships it.

-- The store, as a plain table of known keys. Whitelisted to known rows and read
-- with rawget, so a corrupt or hostile cache's metatable cannot run code on the
-- way out, and the whole thing is pcall'd: a missing store is an empty table,
-- never an error. Values come back RAW - writeCache coerces them on the way in.
-- second return: did the store actually PARSE as a table this read? "empty
-- because absent" and "empty because unreadable right now" must stay
-- distinguishable - see the truncation guard in writeCache.
local function readCacheValues()
    local out, readable = {}, false
    pcall(function()
        local dir = Config.userDir
        if type(dir) ~= "string" or dir == "" then return end
        local chunk = loadfile(dir .. "\\" .. CACHE_FILE)
        if chunk == nil then return end
        local okRun, stored = pcall(chunk)
        if not (okRun and type(stored) == "table") then return end
        readable = true
        for _, row in ipairs(VALUE_ROWS) do
            local v = rawget(stored, row.key)
            if v ~= nil then out[row.key] = v end
        end
    end)
    return out, readable
end

-- Does the file EXIST at all - not "does it parse", not "is it non-empty".
-- darnmenu.lua's boot seed has exactly one question to ask of this store ("is
-- there a record of deliberate applies here, or did the player delete it?") and
-- only the file's presence answers it. Read-only and pcall'd.
local function cacheExists()
    local found = false
    pcall(function()
        local dir = Config.userDir
        if type(dir) ~= "string" or dir == "" then return end
        local fh = io.open(dir .. "\\" .. CACHE_FILE, "rb")
        if fh ~= nil then
            fh:close()
            found = true
        end
    end)
    return found
end

-- THE STORE'S ONLY WRITER, and it MERGES: `changes` is the set of keys that
-- actually moved, laid over whatever the file already holds, and everything
-- else in it is carried through untouched. Both menus go through this one path,
-- which is the whole point - each of them only ever knows about its OWN Apply,
-- so a writer that replaced the file would silently revert every key the other
-- menu had put in it (and, on the MOF side, re-assert 36 stale values on every
-- Apply of one). Read -> overlay -> write, in that order, every time.
local function writeCache(changes)
    local dir = Config.userDir
    if type(dir) ~= "string" or dir == "" then return false end
    local path = dir .. "\\" .. CACHE_FILE
    local tmp = path .. ".new"

    -- truncation guard (fix-verify round 2): under DELTA writes, a store that
    -- EXISTS but would not read this instant must never be replaced by just
    -- the changed keys - that would silently drop every other key the two
    -- menus have accumulated. Refuse this write; the next Apply retries. A
    -- permanently corrupt store is the already-documented state (config.lua
    -- cannot read it either): delete the file to reset.
    local values, readable = readCacheValues()
    if not readable and cacheExists() then
        if not cacheRefusedLogged then
            cacheRefusedLogged = true
            Log("[options] the options cache exists but did not read - Apply"
                .. " NOT mirrored this time (retries on the next Apply; delete "
                .. CACHE_FILE .. " to reset a corrupt store)")
        end
        return false
    end
    if type(changes) == "table" then
        for key, value in pairs(changes) do values[key] = value end
    end

    local parts = {
        "-- Palvolve in-game options cache. WRITTEN BY THE MOD at every Apply",
        "-- in either in-game menu, and read by config.lua as its TOP layer:",
        "--   config.lua defaults <- config_user.lua <- this file.",
        "-- Hand edits are pointless (the next Apply overwrites them); delete",
        "-- the file to fall back to config_user.lua.",
        "return {",
    }
    local n = 0
    for _, row in ipairs(VALUE_ROWS) do
        local v = coerce(row, values[row.key])
        if v ~= nil then
            local literal
            if type(v) == "boolean" then
                literal = tostring(v)
            elseif type(v) == "number" then
                -- %g, never %d: two of these rows are floats (hpThreshold,
                -- textScale) and %d raises on them. 14 digits keeps
                -- every integer row exact and a step-grid float within an ulp
                -- of itself - and the file stays readable, which matters
                -- because players are told they may delete it
                literal = string.format("%.14g", v)
            else
                literal = string.format("%q", v)
            end
            n = n + 1
            parts[#parts + 1] = string.format("    [%q] = %s,", row.key, literal)
        end
    end
    parts[#parts + 1] = "}"
    local body = table.concat(parts, "\n") .. "\n"

    local ok = false
    pcall(function()
        -- No mkdir here, deliberately: this runs on the GAME THREAD (every pump
        -- site enters through ExecuteInGameThread) and os.execute spawns
        -- cmd.exe synchronously, which would hitch the frame. `dir` is the same
        -- folder config_user.lua lives in and config.lua's user-file lookup
        -- already created it at load; if io.open still fails we log once and
        -- give up - only the mirror is missing, the mod itself is unaffected.
        local out = io.open(tmp, "wb")
        if out == nil then return end
        local wrote = out:write(body)
        local closed = out:close()
        ok = (wrote and closed) and true or false
    end)
    if not ok then
        pcall(os.remove, tmp)
        Log("[options] could not write the options cache at " .. path)
        return false
    end

    -- Never swap in a file config.lua cannot load: it is executed at the very
    -- top of the next launch, so a truncated write would take the whole mod
    -- with it. Prove it parses and returns a table before it replaces
    -- anything - same law techlevel.lua's data-half swap follows.
    local verified = false
    pcall(function()
        local chunk = loadfile(tmp)
        if chunk == nil then return end
        local okRun, result = pcall(chunk)
        verified = okRun and type(result) == "table"
    end)
    if not verified then
        pcall(os.remove, tmp)
        Log("[options] options cache did not verify - previous file kept")
        return false
    end

    -- os.rename will not clobber on Windows, so the old file goes first -
    -- which means a failed swap leaves NO cache at all (not the previous one:
    -- it is already gone). The restart rows then fall back to config_user on
    -- the next launch, and the write returns false so nothing promises
    -- otherwise; one more Apply restores the mirror.
    pcall(os.remove, path)
    local okSwap, res = pcall(os.rename, tmp, path)
    if not (okSwap and res) then
        pcall(os.remove, tmp)
        Log("[options] could not swap the options cache into place")
        return false
    end
    if Config.devMode then
        Log(string.format("[options] cache written (%d values) -> %s", n, path))
    end
    return true
end

-- ----------------------------------------------------------------- apply
-- values -> live Config. LIVE ROWS ONLY, on EVERY path including init: a
-- restart row was consumed once at arm time, so writing it now would leave the
-- session half-applied (the hook armed one way, Config claiming the other) -
-- exactly the state the whole restart/live split exists to prevent. Restart
-- values reach Config through config.lua's cache layer at load time and nowhere
-- else. The restart rows that DISAGREE with the running Config come back as
-- `pending` instead, for one notice.
--
-- `announce` false means "apply, but say nothing about the restart rows and
-- leave the announced-set untouched" - init uses it when the cache write that
-- WOULD carry those rows into the next launch did not happen, because a notice
-- promising a next launch would then be a lie, and marking them announced would
-- silence the honest notice at the player's next Apply.
local function applyValues(values, announce)
    if type(values) ~= "table" then return 0, nil end
    local applied, pending = 0, nil
    for _, row in ipairs(VALUE_ROWS) do
        local raw = values[row.key]
        if raw ~= nil then
            local v = coerce(row, raw)
            local t, last = nil, nil
            if v ~= nil then t, last = slotOf(row.key) end
            if t ~= nil then
                if row.mode == "live" then
                    t[last] = v
                    applied = applied + 1
                elseif announce then
                    if t[last] ~= v then
                        -- one notice per key: a later Apply that touches
                        -- something else must not re-announce a restart row
                        -- that is still pending.
                        -- CROSS-MENU by design (one set per session, both
                        -- menus): a row changed on the settings page and then
                        -- again in the Mod Options menu is announced once, not
                        -- twice. Accepted - the second notice would repeat a
                        -- promise the player is already holding.
                        if not restartAnnounced[row.key] then
                            restartAnnounced[row.key] = true
                            pending = pending or {}
                            pending[#pending + 1] = row.label
                        end
                    else
                        restartAnnounced[row.key] = nil -- nothing pending now
                    end
                end
            end
        end
    end
    return applied, pending
end

-- ---------------------------------------------------------------- schema

-- Rejection is invisible, so every rule the framework and the SDK enforce is
-- re-checked here and a failure means we do NOT register: the mod keeps
-- working, only the menu is missing, and the log says exactly which row did
-- it. Deliberately paranoid - this runs once, at startup.
local function validateSchema(schema)
    if type(schema.id) ~= "string" or #schema.id < 1 or #schema.id > 64
        or schema.id:match("^[A-Za-z0-9_.-]+$") == nil then
        return "id must be 1-64 chars of A-Z a-z 0-9 _ . -"
    end
    if math.type(schema.version) ~= "integer" then
        return "version must be an integer"
    end
    if schema.apply_mode ~= "event" then
        return "apply_mode must be \"event\""
    end
    local rows = schema.options
    if type(rows) ~= "table" or #rows < 1 then return "no option rows" end
    if #rows > 128 then
        return string.format("%d rows exceeds the 128-row limit", #rows)
    end
    local seen = {}
    for i, row in ipairs(rows) do
        local at = string.format("row %d (%s)", i, tostring(row.key))
        if type(row.key) ~= "string" or #row.key < 1 or #row.key > 64
            or row.key:match("^[A-Za-z0-9_.-]+$") == nil then
            return at .. ": illegal key"
        end
        if seen[row.key] then return at .. ": duplicate key" end
        seen[row.key] = true
        if type(row.label) ~= "string" or row.label == "" then
            return at .. ": missing label"
        end
        if row.type ~= "section" then
            if row.default == nil then return at .. ": no default" end
            if row.type == "boolean" then
                if type(row.default) ~= "boolean" then
                    return at .. ": default is not a boolean"
                end
            elseif row.type == "integer" or row.type == "number" then
                if type(row.minimum) ~= "number"
                    or type(row.maximum) ~= "number" then
                    return at .. ": missing minimum/maximum"
                end
                if row.minimum > row.maximum then
                    return at .. ": minimum above maximum"
                end
                if type(row.step) ~= "number" or row.step <= 0 then
                    return at .. ": step must be greater than zero"
                end
                if type(row.default) ~= "number" then
                    return at .. ": default is not a number"
                end
                -- an integer row's default must be WHOLE independently of the
                -- step grid: normalize_number tests integrality first and
                -- answers nil before it ever looks at minimum/step, so 2.5 on a
                -- step-0.5 integer row is still an invalid default
                if row.type == "integer" and math.abs(row.default
                    - math.floor(row.default + 0.5)) > 1e-7 then
                    return at .. ": integer default is not a whole number"
                end
                if row.default < row.minimum or row.default > row.maximum then
                    return at .. ": default outside minimum/maximum"
                end
                local ticks = (row.default - row.minimum) / row.step
                if math.abs(ticks - math.floor(ticks + 0.5)) > 1e-6 then
                    return at .. ": default is off the step grid"
                end
            elseif row.type == "enum" then
                if type(row.choices) ~= "table" or #row.choices < 1 then
                    return at .. ": no choices"
                end
                if #row.choices > 64 then
                    return at .. ": more than 64 choices"
                end
                local hit, values = false, {}
                for _, choice in ipairs(row.choices) do
                    if type(choice.value) ~= "string" then
                        return at .. ": choice value is not a string"
                    end
                    -- normalize_option's own bounds on a choice value
                    if choice.value == "" or #choice.value > 128 then
                        return at .. ": choice value is empty or over 128 chars"
                    end
                    if values[choice.value] then
                        return at .. ": duplicate choice value"
                    end
                    values[choice.value] = true
                    if choice.value == row.default then hit = true end
                end
                if not hit then
                    return at .. ": default is not one of the choices"
                end
            elseif row.type == "keybind" then
                if not keyIsLive(row.default) then
                    return at .. ": default key is missing from the Key table"
                end
            else
                return at .. ": unsupported row type " .. tostring(row.type)
            end
        end
    end
    for key, value in pairs(schema.initial_values or {}) do
        local row = ROW_BY_KEY[key]
        if row == nil then
            return "initial_values names an unknown or section key: "
                .. tostring(key)
        end
        if strict(row, value) == nil then
            return "initial_values." .. key .. " is invalid for its row"
        end
    end
    return nil
end

-- Emits the framework's view of a row and NOTHING else: `mode` and `desc` are
-- ours, and an unrecognised field in a manifest is exactly the kind of thing
-- a validator throws a whole schema away over.
local function emitRow(row)
    local out = {
        key = row.key,
        type = row.type,
        label = row.label,
    }
    if row.desc then out.description = row.desc end
    if row.type == "section" then return out end
    out.default = row.default
    if row.minimum then out.minimum = row.minimum end
    if row.maximum then out.maximum = row.maximum end
    if row.step then out.step = row.step end
    if row.choices then
        out.choices = {}
        for i, choice in ipairs(row.choices) do
            out.choices[i] = { value = choice.value, label = choice.label }
        end
    end
    return out
end

local function buildSchema()
    SEED = {}
    -- the index is built at load (indexRows) and is NOT rebuilt here: it
    -- describes the rows, this loop describes the MANIFEST
    local options, emitted = {}, {}
    for _, row in ipairs(ROWS) do
        -- Conditional keybind rows: a name the framework's allow-list does not
        -- carry, or that the running UE4SS build does not know, would reject
        -- the entire schema - and a silently empty menu is far worse than one
        -- missing row.
        if row.type == "keybind" and not keyIsLive(row.default) then
            Log("[options] '" .. row.label .. "' omitted: "
                .. tostring(row.default) .. " is not a key the options"
                .. " framework accepts")
        else
            options[#options + 1] = emitRow(row)
            emitted[row.key] = true
        end
    end

    -- initial_values: the player's CURRENT merged config, so a first-time menu
    -- mirrors their file instead of the shipped defaults. Only used when the
    -- framework has no settings file yet; each value is snapped to its grid
    -- and then proven with the SDK's own rules, and anything that still does
    -- not fit is simply left out (the row falls back to its default). coerce()
    -- gates keybinds on the framework's allow-list too, so a config_user
    -- toggleKey like "LEFT_ALT" - a perfectly real UE4SS key - drops out HERE
    -- and can never poison the seed.
    local seed, seeded = {}, 0
    for _, row in ipairs(VALUE_ROWS) do
        local t, last = slotOf(row.key)
        if t ~= nil then
            local v = coerce(row, t[last])
            if v == nil and row.type == "keybind" and emitted[row.key]
                and type(t[last]) == "string" and t[last] ~= row.default then
                -- worth a line: the player set this key themselves and the
                -- menu is about to show the default instead
                Log("[options] '" .. row.label .. "' keeps its default in the"
                    .. " menu: " .. tostring(t[last]) .. " is not a key the"
                    .. " options framework accepts")
            end
            -- snap only when the value does NOT already fit: snapping a value
            -- that was already on the grid just adds float noise to the file
            if v ~= nil and strict(row, v) == nil
                and (row.type == "integer" or row.type == "number") then
                v = snap(row, v)
            end
            if v ~= nil and strict(row, v) ~= nil then
                seed[row.key] = v
                seeded = seeded + 1
            end
        end
    end
    -- the yardstick the init callback measures the framework's delivered values
    -- against; kept whether or not it is emitted (an empty seed simply means
    -- every row's "untouched" value is its default)
    SEED = seed

    local schema = {
        id = SCHEMA_ID,
        -- INERT while apply_mode is "event": the framework only dereferences
        -- mod_folder to restart a mod, i.e. under apply_mode = "restart_mod".
        -- If anyone ever flips that, this string has to become the REAL
        -- deployed folder name - which is not "Palvolve-Fork" on a Workshop
        -- install, where Steam names the folder with a numeric id.
        mod_folder = "Palvolve-Fork",
        title = "Palvolve",
        description = "Evolve your Pals into related forms. 'Next launch.'"
            .. " rows need a restart; 'Host only.' rows are decided by the"
            .. " host.",
        version = SCHEMA_VERSION,
        apply_mode = "event",   -- SCHEMA level, never per row: we read the
                                -- generation from pollers we already own
        options = options,
    }
    -- an EMPTY table would json-encode as [] and read as a malformed map
    if seeded > 0 then schema.initial_values = seed end

    local why = validateSchema(schema)
    if why then return nil, why end
    return schema
end

-- ------------------------------------------------------------------ pump

-- The last set of values the FRAMEWORK delivered, coerced. sync() hands us the
-- whole stored settings table at every Apply, not the keys the player touched,
-- so without this there is no way to tell an edit from the 35 rows that came
-- along for the ride - and re-asserting all of them would revert whatever the
-- OTHER menu had changed since. nil until the registration callback seeds it.
local lastDelivered = nil

-- The known rows of a delivered table, coerced, so two spellings of one value
-- compare equal. Also the shape lastDelivered is kept in.
local function deliveredSnapshot(values)
    local out = {}
    if type(values) ~= "table" then return out end
    for _, row in ipairs(VALUE_ROWS) do
        local v = coerce(row, values[row.key])
        if v ~= nil then out[row.key] = v end
    end
    return out
end

-- What actually MOVED since the last delivery. Numbers get the same 1e-6
-- tolerance the init drift pass uses - every row's step is >= 0.05, so it
-- absorbs the framework's string round-trip and nothing else.
local function deliveredDelta(incoming)
    local changes, n = {}, 0
    for key, value in pairs(incoming) do
        local was = lastDelivered and lastDelivered[key]
        local same
        if type(value) == "number" and type(was) == "number" then
            same = math.abs(value - was) <= 1e-6
        else
            same = (was == value)
        end
        if not same then
            changes[key] = value
            n = n + 1
        end
    end
    return changes, n
end

-- The framework's Apply. THE deliberate act.
--
-- DELTA, NOT THE WHOLE SET. The framework's stored settings are its own
-- complete copy of all 36 rows; applying them wholesale would re-assert every
-- key at every Apply, so a row the player changed on the DarnMenu settings page
-- ten seconds ago - and did not touch here - would be silently reverted by an
-- Apply of something unrelated. Only the keys that differ from the last
-- delivery are written and applied, and they are MERGED over the store rather
-- than replacing it (writeCache), which is the same shape darnmenu.lua's poll
-- uses because it is now the same code.
--
-- The whole body is pcall'd because sync() treats a throwing apply callback as
-- "not applied": it returns the PREVIOUS generation, so the next pump sees the
-- same change again and re-runs the same failure every 2s forever. Swallowing
-- it lets the generation advance; the failure is logged once and the session
-- carries on with whatever landed before the throw.
local function onApply(values)
    local ok, err = pcall(function()
        local incoming = deliveredSnapshot(values)
        local changes, n = deliveredDelta(incoming)
        -- the snapshot moves whatever happens below: a write that fails must
        -- not turn the next Apply into a replay of this one
        lastDelivered = incoming
        if n == 0 then
            Log("[options] Apply: nothing changed since the last one")
            return
        end
        -- write FIRST, announce from the result (fix-verify catch): a
        -- hardcoded announce promised "next launch" even when the mirror
        -- failed to land, and the one-shot latch then swallowed the honest
        -- notice on the retry that actually worked. writeCache reads no
        -- Config state and applyValues compares against Config, so the
        -- swap is order-safe.
        local wrote = writeCache(changes)
        local applied, pending = applyValues(changes, wrote)
        Log(string.format(
            "[options] %d live values applied from the menu", applied))
        if pending then
            Log("[options] " .. table.concat(pending, ", ")
                .. ": takes effect at the next launch")
        end
    end)
    if not ok and not applyFailed then
        applyFailed = true    -- one-shot: the same throw would otherwise repeat
                              -- at every Apply for the rest of the session
        Log("[options] applying the menu values failed: " .. tostring(err))
    end
end

-- generation() is one shared-variable read; sync() additionally decodes the
-- whole value blob on EVERY call, including the no-change path. So the cheap
-- read gates the documented one - same contract, no per-tick JSON.
local function pumpBody()
    local gen = Options.generation()
    if gen == generation then return end
    generation = select(1, Options.sync(generation, onApply))
end

-- darnmenu.lua's file poll, INJECTED rather than required. darnmenu requires
-- THIS file for the rows and the value plumbing, so a require in the other
-- direction would close a cycle; a setter keeps the dependency one-way and
-- keeps the pump free for the (majority) session that has neither framework
-- installed - nil means "no second menu", which is exactly what the fast path
-- below tests. One-way and last-writer-wins by construction: darnmenu.init is
-- the only caller and it runs once.
local auxPoll = nil
local auxFailed = false   -- one-shot for the aux path, same law as pumpFailed

function ModOptions.setAuxPoll(fn)
    if type(fn) == "function" then auxPoll = fn end
end

-- Called from FIVE independent drivers, because any one of them can be switched
-- off - three of them by rows in this very menu:
--   * evolution.lua's auto-evolve poller  (only armed while autoEvolve.enabled)
--   * evolution.lua's primed-pal poller   (authority only, primedPals.enabled)
--   * evolution.lua's base-camp poller    (authority only, autoEvolve.basePals)
--   * evolution.lua's confirm-key handler (always armed off a dedicated server)
--   * radialmenu.lua's wheel-open hook    (always armed off a dedicated server)
-- The last two are the recovery path: a player who turns auto-evolve AND primed
-- pals off, or any connected client, would otherwise have no driver at all and
-- Apply would never take effect with no way back in-game.
-- Pure Lua: no game-thread entry, no UObject touch, nothing to IsValid-guard,
-- and the interval floor makes extra drivers free.
--
-- TWO CONSUMERS SHARE THE THROTTLE. The MOF sync still needs `registered`, but
-- the DarnMenu poll does not - so the registration test moved INSIDE the
-- interval gate. Leaving it on the outside would have made the second menu's
-- Apply depend on the FIRST menu's framework being installed, which is exactly
-- the coupling both integrations exist to avoid. With neither present the whole
-- function is one boolean and one nil compare.
function ModOptions.pump()
    if not registered and auxPoll == nil then return end
    local now = os.clock()
    if (now - lastPumpAt) < PUMP_INTERVAL_S then return end
    lastPumpAt = now
    if registered then
        local ok, err = pcall(pumpBody)
        -- one-shot, same reasoning as onApply's latch (fix-verify catch): a
        -- persistent throw here would otherwise print every interval for the
        -- rest of the session. The pump keeps running; only the line is
        -- silenced.
        if not ok and not pumpFailed then
            pumpFailed = true
            Log("[options] sync failed: " .. tostring(err))
        end
    end
    -- Independent of the MOF half in BOTH directions: a throwing sync must not
    -- cost the settings-page poll its tick, and a throwing poll must not cost
    -- the sync its own. Two pcalls, two latches.
    if auxPoll ~= nil then
        local okAux, errAux = pcall(auxPoll)
        if not okAux and not auxFailed then
            auxFailed = true
            Log("[options] settings-page poll failed: " .. tostring(errAux))
        end
    end
end

-- One shared-variable read, for gameplay keybinds that share a key with a
-- keybind row: while the framework is capturing a rebind the press is its.
function ModOptions.captureActive()
    if Options == nil or type(Options.capture_active) ~= "function" then
        return false
    end
    local ok, active = pcall(Options.capture_active)
    return ok and active == true
end

-- ------------------------------------------------------------------ init

function ModOptions.init()
    if Options == nil then return end
    local schema, why = buildSchema()
    if schema == nil then
        Log("[options] NOT registered - " .. tostring(why))
        return
    end
    local rows = #schema.options
    -- register_when_ready owns the whole readiness ladder and answers exactly
    -- once. Nothing below may retry it, and nothing may block on it: this
    -- returns immediately and the callback lands after startup has finished.
    -- The callback body needs no pcall of its own - the SDK's deliver() already
    -- wraps it (PalModOptionsClient.lua ~390), so a throw in here costs the
    -- cache write and the log lines and stops there. `registered` is set on the
    -- FIRST line for exactly that reason: the pump keeps working regardless.
    Options.register_when_ready(schema, function(settings, registrationError)
        if settings == nil then
            Log("[options] framework unavailable ("
                .. tostring(registrationError)
                .. ") - config.lua and config_user.lua decide everything")
            return
        end
        registered = true
        generation = Options.generation()

        -- The yardstick every later Apply is measured against (see onApply):
        -- this delivery IS the framework's current state, so nothing in it is
        -- a change yet. Seeded before anything below can throw.
        lastDelivered = deliveredSnapshot(settings)

        -- THE CACHE IS A RECORD OF DELIBERATE APPLIES, NOTHING ELSE. On a first
        -- launch with the framework installed and no <id>.ini yet, `settings`
        -- is just defaults + the seed WE handed it - and the seed has already
        -- been snapped and clamped. Writing that would pin the rewritten values
        -- above config_user.lua forever, for all 36 keys, without the player
        -- ever opening the menu. So: measure every delivered value against what
        -- "no player choice yet" looks like (our seed for the row, else the
        -- row's shipped default) and only write when something differs, which
        -- means the player HAS applied before and the mirror went missing
        -- (deleted cache, a failed write, a hand edit).
        local drifted = 0
        for _, row in ipairs(VALUE_ROWS) do
            local got = coerce(row, settings[row.key])
            if got ~= nil then
                local seeded = SEED[row.key]
                local shipped = coerce(row, row.default)
                local untouched
                if type(got) == "number" then
                    -- every row's step is >= 0.05, so 1e-6 only ever absorbs
                    -- the framework's string round-trip, never a real change
                    untouched = (seeded ~= nil
                            and math.abs(got - seeded) <= 1e-6)
                        or (type(shipped) == "number"
                            and math.abs(got - shipped) <= 1e-6)
                else
                    untouched = (got == seeded) or (got == shipped)
                end
                if not untouched then drifted = drifted + 1 end
            end
        end
        -- Residual, accepted knowingly: a config_user edit made AFTER the
        -- framework wrote its file leaves the stored value matching neither the
        -- new seed nor the default, and reads as drift. The mirror it then
        -- writes is the menu's own state, which is what the player sees and
        -- what the next Apply would store anyway.
        local restored = false
        if drifted > 0 then
            -- the FULL delivered set, deliberately, and through the same
            -- merge-style writeCache both menus use: this is the one path whose
            -- job IS to re-assert everything the framework holds, so the merge
            -- is a no-op over the keys it names and preserves anything else the
            -- store happens to carry
            restored = writeCache(settings)
            if restored then
                Log(string.format("[options] options cache rebuilt from the"
                    .. " menu's saved settings (%d values differ from this"
                    .. " config)", drifted))
            end
        end

        -- LIVE rows only, exactly like the Apply path (see applyValues): a
        -- restart row written here would contradict a hook that armed minutes
        -- ago. The restart rows that disagree are only ANNOUNCED when the
        -- rebuild above actually landed - that file is the one thing that makes
        -- "at the next launch" true, so without it there is nothing to promise.
        local applied, pending = applyValues(settings, restored)

        Log(string.format(
            "[options] in-game menu registered (schema v%d, %d rows); %d live"
            .. " values applied", SCHEMA_VERSION, rows, applied))
        if pending then
            Log("[options] " .. table.concat(pending, ", ")
                .. ": the menu already holds these, they apply at the next"
                .. " launch")
        end
    end)
end

-- ------------------------------------------------------ second-menu exports
-- darnmenu.lua renders THE SAME ROWS through a different framework (DarnMenu's
-- settings page), so it takes the rows AND the value plumbing from here rather
-- than keeping a second copy that could drift out of step. Everything below is
-- an alias for something already defined above - no second implementation of
-- anything - and the dependency runs ONE WAY: this file never requires
-- darnmenu, which is why the poll arrives through setAuxPoll instead.
--
-- The single-store rule lives here too: options_cache.lua is the ONE canonical
-- store, writeCache is its ONLY writer, and both menus go through it. config.lua
-- reads it at the next launch and reads NOTHING either framework owns.
ModOptions.DARN_SCHEMA_VERSION = DARN_SCHEMA_VERSION

-- The row table itself, sections included, in declaration order. Read-only by
-- convention: a caller renders it, never edits it.
function ModOptions.rows() return ROWS end

-- The value rows (sections dropped) and the key -> row lookup, both from the
-- load-time index, so they are populated whether or not the MOF SDK exists.
function ModOptions.valueRows() return VALUE_ROWS end
function ModOptions.rowFor(key) return ROW_BY_KEY[key] end

-- coerce + clamp: THE one place a value is judged against its row. A menu that
-- rejects out-of-range input at the keyboard (DarnMenu does) still has to come
-- through here, because its file can be hand-edited afterwards.
ModOptions.coerceValue = coerce

-- The value a row currently carries in the live Config; nil when config.lua
-- does not declare the key. The slot walk itself stays private.
function ModOptions.currentValue(key)
    local t, last = slotOf(key)
    if t == nil then return nil end
    return t[last]
end

-- values -> live Config, plus the restart rows to announce. Shared with the MOF
-- path deliberately: restartAnnounced is ONE set per session, so a row already
-- announced by one menu is not announced a second time by the other.
ModOptions.applyValues = applyValues

-- The canonical store's ONE writer, and it takes CHANGES: the keys that moved,
-- merged over whatever the file already holds. A caller never has to read the
-- store first and never has to hand back keys it does not own - that merge is
-- inside, so both menus get it and neither can truncate the file.
ModOptions.writeCache = writeCache

-- The store as a table of known keys (raw values), for a caller that wants to
-- look rather than write.
ModOptions.readCache = readCacheValues

-- Presence only, for darnmenu.lua's boot seed: "the player has a store" and
-- "the store is empty" are different answers and only this one distinguishes
-- them.
ModOptions.cacheExists = cacheExists

return ModOptions
