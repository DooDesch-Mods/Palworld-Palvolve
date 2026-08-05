-- Palvolve in-game settings page: the DarnMenu consumer side.
--
-- THE SECOND MENU ONTO THE SAME SWITCHES. modoptions.lua publishes the fork's
-- 36 settings to the Mod Options Framework; this file publishes THE SAME ROWS
-- to DarnMenu's ESC -> Mod Options page. One row table (modoptions.lua's ROWS),
-- two renderers, and - the part that matters - ONE store: options_cache.lua.
-- Nothing here is a second source of truth for anything.
--
-- OPTIONAL by design, exactly like the MOF half. DarnMenu is a separate mod;
-- absent, stale or hostile it costs one log line and the mod behaves as it does
-- with config.lua alone. Every file operation in here is pcall'd and every
-- failure is a log line, never an error.
--
-- HOW DARNMENU WORKS (verified against DarnMenu_API.md, DarnMenu_TUTORIAL.md
-- and its own schemas.lua, DarnMenu 1.7.3 / caps rev 2):
--   * A consumer REGISTERS BY FILE. Two plain files in <UE4SS Mods>/shared/:
--       DarnMenu_schema_Palvolve.lua   -- `return { ...schema... }`
--       DarnMenu_schema_index.lua      -- `return { "Palvolve", ... }`
--     Both are re-read every time the menu opens, so a page registered at
--     startup appears without a restart and a page whose mod is gone is pruned
--     by DarnMenu's own repair pass. The index is SHARED PROPERTY - every
--     registered mod has a line in it - which is why the writer below would
--     rather refuse than rewrite one it cannot read (see registerDirect).
--   * There is NO PUSH. The player's Apply merges the CHANGED KEYS ONLY into
--     shared/Palvolve_user.lua and tells nobody; consumers poll that file.
--     That file is a PERSISTENT OVERLAY, not a snapshot: keys are merged in
--     forever and never removed, so what it holds is the UNION of every Apply
--     the player has ever made on that page - which is why the poll below
--     seeds from it rather than replaying it (see THE BOOT SEED).
--   * Every name DarnMenu touches on our behalf is a plain basename inside
--     shared/ (no slashes, no ".."), sandbox-enforced, and `target` must end
--     in "_user".
--   * ONE INVALID SCHEMA FIELD KILLS THE WHOLE PAGE, silently, with a line in
--     UE4SS.log nobody reads. So the generated schema is validated HERE against
--     DarnMenu's own rules before it is written (validateSchema below mirrors
--     schemas.lua's validSchema for the subset we emit) - the same philosophy
--     modoptions.lua applies to the MOF manifest, and for the same reason.
--
-- THE SINGLE-STORE RULE (locked). options_cache.lua remains THE canonical
-- store: written by modoptions.lua's writeCache, read by config.lua's third
-- layer at the next launch. Palvolve_user.lua is an EVENT SOURCE and nothing
-- more - our poll notices a KEY change, coerces it through THE SAME row rules
-- the MOF path uses, applies it to Config when it is live, and merges it into
-- options_cache.lua so the next launch sees it. config.lua never reads a
-- DarnMenu file. Two menus, one store, last Apply wins.
--
-- THE BOOT SEED (and why it applies nothing). Palvolve_user.lua accumulates:
-- DarnMenu merges the changed keys of every Apply into it and never removes
-- one, so a file written months ago still asserts every choice ever made on
-- that page. Replaying it at boot would therefore not be "reading the player's
-- settings" - it would be re-applying an old Apply OVER the canonical store,
-- reverting any NEWER Mod-Options Apply of an overlapping key at every single
-- launch, and defeating the documented escape hatch (delete options_cache.lua
-- to fall back to config_user.lua) by rebuilding half of it from the overlay.
-- So the FIRST successful read of a session SEEDS the baseline and applies
-- NOTHING, and every later poll diffs PER KEY against that baseline - only the
-- keys that actually moved are applied and mirrored.
--   THE ONE EXCEPTION: no options_cache.lua at all (fresh install, or the
--   player deleted it) and the overlay holds known keys. Then there is no
--   newer record for it to stomp, and a DarnMenu-only player would otherwise
--   lose every choice they have ever made at the first launch after a cache
--   delete. That case applies the overlay once, and the log says exactly that.
-- PRECEDENCE, in one line: config.lua < config_user.lua < options_cache.lua,
-- with both menus writing the cache and the newest Apply of a KEY winning it.
--
-- WHY THE BOOT SEED RIDES THE FIRST POLL AND NOT init(). In a session with
-- BOTH frameworks installed, the MOF callback lands inside a ~3.85s startup
-- window and may REBUILD the cache from the framework's own saved settings
-- (modoptions.lua's drift path). A boot read inside our init would run before
-- that and would ask "does the cache exist?" before the answer was settled.
-- The pump's drivers are all gameplay events - well past that window - so
-- letting the first poll do the boot read puts us after the rebuild.
--
-- POLL COST, HONESTLY. One io.open + one read of a file that is a few hundred
-- bytes, at most once every 2s, and ONLY when DarnMenu is installed. A file
-- that has not been written yet costs a failed io.open and nothing else; an
-- unchanged file costs one string compare and stops there - no parse, no Config
-- touch, no write. Only a file whose TEXT moved is parsed, and only the keys
-- whose VALUES moved cost anything after that. The 2s floor is
-- modoptions.lua's, shared: this poll is the pump's second consumer, NOT a new
-- loop (house rule: no new LoopAsync, no ExecuteWithDelay).
--
-- AUTHORITY. Client-side only and zero authority, like the MOF page. DarnMenu
-- disables itself headless; main.lua gates us behind the same not-dedicated
-- test regardless.

-- config.lua is deliberately NOT required here. Every Config read this file
-- needs goes through ModOptions.currentValue, so the "one place judges a row"
-- rule holds, and the module below owns no opinion about the config table.
local ModOptions = require("modoptions")

local DarnMenu = {}

local MOD_NAME = "Palvolve"

-- The registration name: it is the index entry, half the schema file's name and
-- (with " page") how a support log identifies us. Stable forever - changing it
-- orphans the old schema file and the player's page position.
-- NOTE the fork/original exclusion: only ONE of Palvolve and Palvolve-Fork is
-- ever enabled (house rule), so a single "Palvolve" page can never double up.
local SCHEMA_NAME = "Palvolve"
local TAB_TITLE = "Palvolve"
local TARGET = "Palvolve_user"          -- MUST end in _user (DarnMenu sandbox)
local USER_FILE = TARGET .. ".lua"
local SCHEMA_FILE = "DarnMenu_schema_" .. SCHEMA_NAME .. ".lua"
local INDEX_FILE = "DarnMenu_schema_index.lua"
local CAPS_FILE = "DarnMenu_caps.lua"

local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- --------------------------------------------------------------- shared dir
-- <UE4SS Mods>/shared/, derived from THIS file's own source path and never from
-- the game's working directory - the same law darntoasts.lua's package.path
-- splice and evolution.lua's STATE_FILE follow. Our scripts live at
-- <UE4SS Mods>/Palvolve-Fork/Scripts/, so shared/ is two levels up (verified
-- against the live install, where DarnMenu_caps.lua and the working example
-- consumers sit exactly there).
local SHARED = nil
do
    local ok, dir = pcall(function()
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) ~= "@" then return nil end
        return src:sub(2):gsub("[^/\\]+$", "") .. "../../shared/"
    end)
    if ok and type(dir) == "string" then SHARED = dir end
end

-- ------------------------------------------------------------------- state
local caps = nil          -- the capability marker, nil = DarnMenu absent
local available = false   -- set once, in init: gates the poll
local lastRaw = nil       -- last seen RAW TEXT of Palvolve_user.lua (fast path)
local lastValues = nil    -- last seen PARSED+COERCED snapshot of the known keys
local recoveryPending = false  -- init found page choices but no store: the
                               -- adopt-once APPLY is deferred to the first
                               -- poll (a store write inside init would race
                               -- the MOF callback's startup drift rebuild)
                          -- in that file. nil means "not read yet this
                          -- session", which is what makes the first read the
                          -- boot seed; every later poll diffs against it, so a
                          -- key only ever moves when its VALUE moved.
local pollFailed = false  -- one-shot, same law as modoptions' pumpFailed

-- ------------------------------------------------------------ curated keys
-- DarnMenu's keycapture set, copied from its main.lua CAPTURE_KEYS. UE4SS has
-- no any-key listener and keybinds cannot be unregistered, so DarnMenu pre-binds
-- a fixed battery once and only listens while a capture is armed: a key outside
-- this list simply CANNOT be captured, whatever UE4SS thinks of it.
--
-- It is NARROWER than both UE4SS's Key table and the Mod Options Framework's
-- allow-list (which modoptions.lua mirrors as FRAMEWORK_KEYBINDS): no F13-F24,
-- no arrows, no SPACE/RETURN/TAB/BACKSPACE, no lock keys, no modifier combos.
-- It is also a strict SUBSET of that list, which is the invariant that lets our
-- poll hand a captured name straight to modoptions' coerce() - every name
-- DarnMenu can ever store is one the MOF row rules already accept.
local DARN_CAPTURE = {}
do
    for index = 1, 12 do DARN_CAPTURE["F" .. tostring(index)] = true end
    for code = string.byte("A"), string.byte("Z") do
        DARN_CAPTURE[string.char(code)] = true
    end
    for _, name in ipairs({
        "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN",
        "EIGHT", "NINE", "NUM_ZERO", "NUM_ONE", "NUM_TWO", "NUM_THREE",
        "NUM_FOUR", "NUM_FIVE", "NUM_SIX", "NUM_SEVEN", "NUM_EIGHT",
        "NUM_NINE", "SUBTRACT", "ADD", "MULTIPLY", "DIVIDE", "DECIMAL",
        "INS", "DEL", "HOME", "END", "PAGE_UP", "PAGE_DOWN",
    }) do
        DARN_CAPTURE[name] = true
    end
end

-- ------------------------------------------------------------- dependencies
-- DarnMenu greys a control out while another BOOL option is false. That is
-- DarnMenu's vocabulary, not the framework's, which is why the relation lives
-- here instead of in modoptions.lua's ROWS: a field only one of the two
-- renderers understands does not belong in the row table both of them read.
-- Keys and parents are row keys; a parent that is missing or is not a bool at
-- emit time drops the dependency rather than the page (see buildSchema).
local DEPENDS = {
    ["autoEvolve.basePals"]               = "autoEvolve.enabled",
    ["autoEvolve.cooldownSeconds"]        = "autoEvolve.enabled",
    ["primedPals.chance"]                 = "primedPals.enabled",
    ["primedPals.hpThreshold"]            = "primedPals.enabled",
    ["primedPals.telegraphMs"]            = "primedPals.enabled",
    ["wildLevelLimit.mode"]               = "wildLevelLimit.enabled",
    ["wildLevelLimit.genderFaithful"]     = "wildLevelLimit.enabled",
    ["wildLevelLimit.npcOtomo"]           = "wildLevelLimit.enabled",
    ["wildLevelLimit.exemptAlphas"]       = "wildLevelLimit.enabled",
    ["wildLevelLimit.includeAdaptations"] = "wildLevelLimit.enabled",
    ["eggFilter.gateCrossAdaptations"]    = "eggFilter.enabled",
    ["evolveNotify.chatFallback"]         = "evolveNotify.enabled",
    ["evolveNotify.flavorLine"]           = "evolveNotify.enabled",
    ["evolveNotify.darnToasts"]           = "evolveNotify.enabled",
    ["evolveNotify.flavorLeadMs"]         = "evolveNotify.flavorLine",
    ["palpediaEvolutions.toggleKey"]      = "palpediaEvolutions.enabled",
    ["palpediaEvolutions.textScale"]      = "palpediaEvolutions.enabled",
}

-- ----------------------------------------------------------------- file io
-- Every one of these is pcall'd at its own level: the shared folder is written
-- by any number of mods and read by all of them, so "the file vanished between
-- the open and the read" is a normal Tuesday, not an exception.

-- Nothing we read out of shared/ is legitimately large: our own generated page
-- is ~12KB, the index and the caps marker are a few hundred bytes, and
-- Palvolve_user.lua is one line per key the player has ever changed. A file
-- past this cap is therefore not ours in any sense that matters - a log dump
-- that landed on the name, a corrupted write, or something deliberate - and
-- reading it would pull megabytes into the Lua state on a 2s poll. Size is
-- checked with a seek BEFORE the read, so an oversized file costs an open and
-- nothing else, and each path says so exactly once per session.
local MAX_READ = 256 * 1024
local oversizeLogged = {}

local function readFile(path)
    local text = nil
    pcall(function()
        local fh = io.open(path, "rb")
        if fh == nil then return end
        local size = fh:seek("end")
        if type(size) == "number" and size > MAX_READ then
            fh:close()
            if not oversizeLogged[path] then
                oversizeLogged[path] = true
                Log(string.format("[settings] %s is %d bytes - past the %d-byte"
                    .. " ceiling for a shared file, so it is ignored",
                    path, size, MAX_READ))
            end
            return
        end
        fh:seek("set")
        local raw = fh:read("*a")
        fh:close()
        if type(raw) == "string" then text = raw end
    end)
    return text
end

-- DarnMenu's own best-practices law (FOR_DEVS_BEST_PRACTICES 13): a truncating
-- open that is interrupted leaves an empty file, and an empty file in shared/
-- is somebody's lost settings. Write a temp, move the live file aside to .bak,
-- rename the temp into place. .bak is the exact name DarnMenu's reader falls
-- back to (writers.lua readState), so the generation we displace stays useful
-- to it. os.rename will not clobber on Windows, which is why the live file has
-- to move first.
--
-- preserveBak inverts exactly that one step, for the one case where it would
-- destroy the only good copy: when the file we are replacing is the UNREADABLE
-- one and the content we are writing was recovered FROM its .bak (see the index
-- read in registerDirect). Parking the broken primary at .bak would overwrite
-- the healthy generation their reader falls back to, so the broken primary is
-- discarded instead and the existing .bak is left exactly where it is.
local function writeAtomic(path, body, preserveBak)
    local done = false
    pcall(function()
        local tmp = path .. ".new"
        local out = io.open(tmp, "wb")
        if out == nil then return end
        local wrote = out:write(body)
        local closed = out:close()
        if not (wrote and closed) then
            pcall(os.remove, tmp)
            return
        end
        if preserveBak then
            pcall(os.remove, path)
        else
            pcall(os.remove, path .. ".bak")
            pcall(os.rename, path, path .. ".bak")
        end
        local okSwap, res = pcall(os.rename, tmp, path)
        if not (okSwap and res) then
            pcall(os.remove, tmp)
            return
        end
        done = true
    end)
    return done
end

-- EVERY executable file we read out of shared/ comes through here. shared/ is a
-- folder every installed mod - and the player - can write, so a file in it is
-- untrusted input by construction: it is loaded in TEXT MODE ONLY (no bytecode)
-- with an EMPTY environment, so it has no print, no io, no os, no require and
-- no setmetatable to reach for. It may hand us data and nothing else. Returns
-- the table, or nil and a phrase for the log; never raises.
local function loadTable(raw, name)
    if type(raw) ~= "string" then return nil, "could not be read" end
    local chunk = load(raw, "@" .. name, "t", {})
    if chunk == nil then return nil, "did not parse" end
    local ok, value = pcall(chunk)
    if not (ok and type(value) == "table") then return nil, "returned no table" end
    return value, nil
end

local function loadShared(name)
    local value = loadTable(readFile(SHARED .. name), name)
    return value
end

-- The capability marker DarnMenu writes at ITS startup. Missing = DarnMenu is
-- absent, or is a 1.0.x that predates the marker; we treat both as absent,
-- which is the conservative read - a 1.0.x would silently ignore half the
-- fields below and render a page we did not design. Present, we use two of its
-- flags (see buildSchema) rather than assuming a version.
local function probeCaps()
    return loadShared(CAPS_FILE)
end

-- ------------------------------------------------------------- serializing
-- The schema is registered as SOURCE TEXT (that is what ToastLib's helper takes
-- and what the file has to contain), so the table we build has to come back out
-- as Lua. Deterministic on purpose: a stable byte-for-byte rendering means a
-- re-registration at the same version is a no-op and a diff of the file shows
-- only what actually moved.
-- Field order inside a table: ranked keys first (lower first), then anything
-- unranked, alphabetically. ONE rank space serves all three table shapes
-- because no two of them share a field where the order would fight - the
-- fractional ranks are the option-row block slotted between `kind` and `help`.
local RANK = {
    -- schema root
    schemaVersion = 1, tab = 2, order = 3, target = 4, live = 5,
    note = 6, applyNote = 7, defaults = 8, sections = 9,
    -- section  /  enum value pair
    title = 1, options = 2, value = 1,
    -- option row
    path = 1, label = 2, kind = 3, min = 3.1, max = 3.2, integer = 3.3,
    step = 3.4, values = 3.5, help = 4.1, dependsOn = 4.2,
}

local function serialize(v, indent)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        -- %g family, NEVER %d: two of these rows are floats (hpThreshold,
        -- textScale) and %d raises on them. Whole numbers still print whole so
        -- the file reads like something a human wrote.
        if v % 1 == 0 and math.abs(v) < 2 ^ 53 then
            return string.format("%.0f", v)
        end
        return string.format("%.14g", v)
    end
    if t ~= "table" then return "nil" end

    local pad = indent .. "  "
    local parts = {}
    local n = #v
    for i = 1, n do parts[#parts + 1] = pad .. serialize(v[i], pad) end
    local keys = {}
    for k in pairs(v) do
        if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b)
        local ra, rb = RANK[a] or 99, RANK[b] or 99
        if ra ~= rb then return ra < rb end
        return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
        local name = tostring(k)
        local key = name:match("^[%a_][%w_]*$") and name
            or ("[" .. string.format("%q", name) .. "]")
        parts[#parts + 1] = pad .. key .. " = " .. serialize(v[k], pad)
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
end

-- djb2 over the rendered schema text, printed into the generated file's own
-- header as `-- fingerprint: <hex>`. THE VERSION IS NOT ENOUGH ON ITS OWN: this
-- page's CONTENT depends on runtime state, not just on the row table, so two
-- launches of the SAME build legitimately render different pages -
--   * caps flags decide whether a number row carries `step` and whether an enum
--     emits { value, label } pairs or bare values, and
--   * a keycapture row is DROPPED when the key the game is currently bound to
--     is outside DarnMenu's curated set.
-- Gating the rewrite on DARN_SCHEMA_VERSION alone therefore leaves a stale page
-- on disk forever whenever the change did not come with a version bump - which
-- is every one of those, plus any row edit that forgot the bump. Deterministic
-- serialization (see RANK) is what makes this stable enough to compare: same
-- page, same bytes, same hash, and a relaunch that changed nothing writes
-- nothing. Pure Lua, one pass over ~12KB, once at startup.
local function fingerprint(text)
    local h = 5381
    for i = 1, #text do
        -- % 2^32 every step: h stays under 2^37 before the modulo, which is
        -- exact in a 64-bit integer AND in a double, so the hash is the same
        -- number whichever Lua build the game ships
        h = (h * 33 + text:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

-- ------------------------------------------------------------- self-validate
-- DarnMenu's validSchema (schemas.lua), mirrored for the subset we emit. Its
-- rejection is INVISIBLE to the player - the page just is not there - so every
-- rule it enforces is enforced here first, where the failure has a name and a
-- log line. Deliberately paranoid: this runs once, at startup.
local OPTION_KINDS = {
    bool = true, enum = true, number = true, text = true,
    keycapture = true, keychord = true,
}

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function scalarValue(value)
    local t = type(value)
    return t == "string" or t == "boolean" or finiteNumber(value)
end

-- a contiguous 1..n array with no holes, which is what DarnMenu's arrayValues
-- demands of sections, options and enum values alike
local function isArray(value)
    if type(value) ~= "table" then return false end
    if getmetatable(value) ~= nil then return false end
    local count, max = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
        if key > max then max = key end
    end
    return count == max
end

local function validateOption(opt, at, paths)
    if type(opt) ~= "table" or getmetatable(opt) ~= nil then
        return at .. " must be a plain table"
    end
    if opt.divider == true then return nil end
    if opt.subtitle ~= nil then
        if type(opt.subtitle) ~= "string" or opt.subtitle == "" then
            return at .. ".subtitle must be a non-empty string"
        end
        return nil
    end
    if type(opt.path) ~= "string" or opt.path == "" then
        return at .. ".path must be a non-empty string"
    end
    if paths[opt.path] then return at .. ".path duplicates " .. opt.path end
    if not OPTION_KINDS[opt.kind] then
        return at .. ".kind is unsupported: " .. tostring(opt.kind)
    end
    for _, field in ipairs({ "label", "help", "note" }) do
        if opt[field] ~= nil and type(opt[field]) ~= "string" then
            return at .. "." .. field .. " must be a string"
        end
    end
    if opt.dependsOn ~= nil
        and (type(opt.dependsOn) ~= "string" or opt.dependsOn == "") then
        return at .. ".dependsOn must be a non-empty string"
    end
    if opt.live ~= nil and type(opt.live) ~= "boolean" then
        return at .. ".live must be a boolean"
    end
    if opt.kind == "enum" then
        if not isArray(opt.values) or #opt.values < 1 then
            return at .. ".values must be a non-empty list"
        end
        for i, entry in ipairs(opt.values) do
            if type(entry) == "table" then
                if entry.value == nil or not scalarValue(entry.value) then
                    return at .. ".values[" .. i .. "].value is required"
                end
                if entry.label ~= nil and type(entry.label) ~= "string" then
                    return at .. ".values[" .. i .. "].label must be a string"
                end
            elseif not scalarValue(entry) then
                return at .. ".values[" .. i .. "] must be a scalar"
            end
        end
    elseif opt.kind == "number" then
        for _, field in ipairs({ "min", "max", "step" }) do
            if opt[field] ~= nil and not finiteNumber(opt[field]) then
                return at .. "." .. field .. " must be a finite number"
            end
        end
        if opt.min ~= nil and opt.max ~= nil and opt.min > opt.max then
            return at .. ".min must not exceed .max"
        end
        if opt.step ~= nil and opt.step <= 0 then
            return at .. ".step must be greater than zero"
        end
        if opt.integer ~= nil and type(opt.integer) ~= "boolean" then
            return at .. ".integer must be a boolean"
        end
    end
    paths[opt.path] = opt
    return nil
end

-- the defaults pass, which is where a mistake in OUR mapping would land: a
-- default outside its own row's bounds, or an enum default that is not one of
-- the choices we emitted
local function validateDefault(opt, value, at)
    if opt.kind == "bool" then
        if type(value) ~= "boolean" then return at .. " must be a boolean" end
    elseif opt.kind == "enum" then
        if not scalarValue(value) then return at .. " must be a scalar" end
        local hit = false
        for _, entry in ipairs(opt.values) do
            local v = (type(entry) == "table") and entry.value or entry
            if v == value then hit = true end
        end
        if not hit then return at .. " is not present in the enum values" end
    elseif opt.kind == "number" then
        if not finiteNumber(value) then return at .. " must be a finite number" end
        if opt.integer == true and value % 1 ~= 0 then
            return at .. " must be a whole number"
        end
        if opt.min ~= nil and value < opt.min then
            return at .. " is below the option minimum"
        end
        if opt.max ~= nil and value > opt.max then
            return at .. " is above the option maximum"
        end
    elseif opt.kind == "keycapture" then
        if type(value) ~= "string" then
            return at .. " must be a key-name string"
        end
    elseif opt.kind == "text" then
        if type(value) ~= "string" then return at .. " must be a string" end
    end
    return nil
end

local function validateSchema(schema)
    if type(schema) ~= "table" or getmetatable(schema) ~= nil then
        return "schema must be a plain table"
    end
    if type(schema.tab) ~= "string" or schema.tab == "" then
        return "schema.tab must be a non-empty string"
    end
    if type(schema.target) ~= "string" or schema.target == "" then
        return "schema.target must be a non-empty string"
    end
    -- the sandbox, twice, exactly as schemas.lua applies it at load: a bare
    -- name AND a _user suffix, because SHARED .. target .. ".lua" is a raw
    -- concatenation and "../../evil_user" would satisfy the suffix rule alone
    if schema.target:match("^[%w_%-%.]+$") == nil
        or schema.target:find("..", 1, true) ~= nil
        or schema.target:match("_user$") == nil then
        return "schema.target must be a plain name ending in _user"
    end
    for _, field in ipairs({ "note", "applyNote" }) do
        if schema[field] ~= nil and type(schema[field]) ~= "string" then
            return "schema." .. field .. " must be a string"
        end
    end
    if schema.live ~= nil and type(schema.live) ~= "boolean" then
        return "schema.live must be a boolean"
    end
    if schema.order ~= nil and not finiteNumber(schema.order) then
        return "schema.order must be a finite number"
    end
    if schema.schemaVersion ~= nil
        and (not finiteNumber(schema.schemaVersion)
            or schema.schemaVersion < 0 or schema.schemaVersion % 1 ~= 0) then
        return "schema.schemaVersion must be a non-negative whole number"
    end
    if schema.defaults ~= nil
        and (type(schema.defaults) ~= "table"
            or getmetatable(schema.defaults) ~= nil) then
        return "schema.defaults must be a plain table"
    end
    if not isArray(schema.sections) then
        return "schema.sections must be a contiguous list"
    end

    local paths = {}
    for si, section in ipairs(schema.sections) do
        local at = "schema.sections[" .. si .. "]"
        if type(section) ~= "table" or getmetatable(section) ~= nil then
            return at .. " must be a plain table"
        end
        if section.title ~= nil and type(section.title) ~= "string" then
            return at .. ".title must be a string"
        end
        if not isArray(section.options) then
            return at .. ".options must be a contiguous list"
        end
        for oi, opt in ipairs(section.options) do
            local why = validateOption(opt, at .. ".options[" .. oi .. "]", paths)
            if why then return why end
        end
    end

    -- dependsOn resolves to an emitted BOOL option, or DarnMenu throws the
    -- whole page away
    for path, opt in pairs(paths) do
        if opt.dependsOn ~= nil then
            local target = paths[opt.dependsOn]
            if target == nil then
                return path .. ".dependsOn references an unknown option"
            end
            if target.kind ~= "bool" then
                return path .. ".dependsOn must reference a bool option"
            end
        end
    end

    for path, value in pairs(schema.defaults or {}) do
        local opt = paths[path]
        if opt == nil then
            return "schema.defaults." .. tostring(path) .. " names no option"
        end
        local why = validateDefault(opt, value, "schema.defaults." .. path)
        if why then return why end
    end
    return nil
end

-- ------------------------------------------------------------ schema build
-- ONE row table, two renderers. modoptions.lua's ROWS is the source of truth;
-- nothing below invents a row, a label, a bound or a default.
--
-- The mapping:
--   section  -> a DarnMenu SECTION (its header is a collapsible button, which
--               is exactly what our section markers mean; the alternative -
--               subtitle rows inside one giant section - would give 36 controls
--               one unbroken scroll and no way to fold a group away)
--   boolean  -> bool
--   integer  -> number, integer = true, min/max, step when the build has the
--               stepper capability
--   number   -> number, min/max, step (same gate)
--   enum     -> enum, the same choices; { value, label } pairs when the build
--               understands them, bare values otherwise (a rev-1 DarnMenu would
--               render a pair table as "table: 0x...")
--   keybind  -> keycapture, ONLY when both the shipped default and the value
--               the game is actually using are inside DarnMenu's curated set
--
-- `default` is the SHIPPED config.lua default for every row, never the running
-- value - the same rule the MOF schema follows, because DarnMenu's Restore
-- Defaults must hand back the released behaviour. Note the asymmetry this
-- creates and accepts: DarnMenu has no initial_values, so a player who set a
-- row in config_user.lua sees the SHIPPED value on the page until they save
-- once. Their file still decides the game (config.lua's merge is untouched);
-- only the page's idea of "unchanged" differs.
--
-- `live` is per row, from the row's own mode: a live row is read at its use
-- site and lands within one poll (~2s), a restart row was consumed once at arm
-- time and reaches the game through the cache at the next launch. DarnMenu
-- turns those into the green/amber dots and computes the Apply message from
-- them, so a wrong flag is a lie told to the player - which is why they are
-- derived, not typed.
local function optionFor(row, flags, dropped)
    local live = (row.mode == "live")
    if row.type == "boolean" then
        return { path = row.key, label = row.label, kind = "bool",
                 help = row.desc, live = live }
    elseif row.type == "integer" or row.type == "number" then
        local opt = { path = row.key, label = row.label, kind = "number",
                      min = row.minimum, max = row.maximum,
                      help = row.desc, live = live }
        if row.type == "integer" then opt.integer = true end
        -- the stepper's -/+ buttons are a rev-2 feature; an older build ignores
        -- `step` harmlessly, but declaring only what the build has is the
        -- documented pattern and keeps the page honest
        if flags.stepper and row.step then opt.step = row.step end
        return opt
    elseif row.type == "enum" then
        local values = {}
        for i, choice in ipairs(row.choices) do
            if flags.enumLabels then
                values[i] = { value = choice.value, label = choice.label }
            else
                values[i] = choice.value
            end
        end
        return { path = row.key, label = row.label, kind = "enum",
                 values = values, help = row.desc, live = live }
    elseif row.type == "keybind" then
        -- BOTH ends have to be capturable. The default, because it is what the
        -- page shows and what Restore Defaults stages - a key DarnMenu can
        -- never produce has no business being offered. And the CURRENT value,
        -- because a control showing "F2" while the game is bound to a key this
        -- widget cannot capture is a control the player can only ever use to
        -- LOSE their binding: there is no route back to it through this menu.
        -- Omitting the row leaves their key alone and says so in the log.
        local current = ModOptions.currentValue(row.key)
        local currentOK = (type(current) ~= "string") or DARN_CAPTURE[current]
        if DARN_CAPTURE[row.default] and currentOK then
            return { path = row.key, label = row.label, kind = "keycapture",
                     help = row.desc, live = live }
        end
        dropped[#dropped + 1] = string.format("%s (%s)", row.label,
            tostring(DARN_CAPTURE[row.default] and current or row.default))
        return nil
    end
    return nil
end

local function buildSchema()
    local sections, section, defaults, dropped = {}, nil, {}, {}
    local emitted = {}
    local flags = caps or {}
    for _, row in ipairs(ModOptions.rows()) do
        if row.type == "section" then
            section = { title = row.label, options = {} }
            sections[#sections + 1] = section
        elseif section ~= nil then
            local opt = optionFor(row, flags, dropped)
            if opt ~= nil then
                section.options[#section.options + 1] = opt
                defaults[row.key] = row.default
                emitted[row.key] = opt
            end
        end
    end

    -- dependsOn LAST, so it can only ever name a row that survived the pass
    -- above. A parent that was dropped (or is somehow not a bool) costs its
    -- children their grey-out, never the page: one bad field here would take
    -- all 36 controls down with it.
    for key, parent in pairs(DEPENDS) do
        local opt, target = emitted[key], emitted[parent]
        if opt ~= nil and target ~= nil and target.kind == "bool" then
            opt.dependsOn = parent
        end
    end

    -- drop an empty section rather than draw a header over nothing
    local kept = {}
    for _, sec in ipairs(sections) do
        if #sec.options > 0 then kept[#kept + 1] = sec end
    end

    return {
        schemaVersion = ModOptions.DARN_SCHEMA_VERSION,
        tab = TAB_TITLE,
        target = TARGET,
        live = false,   -- page default; every option overrides it explicitly
        note = "Green dot = applies while you play (a second or two after"
            .. " Apply). Amber = armed at startup, so it takes effect at your"
            .. " next launch. 'Host only.' rows are decided by the host.",
        applyNote = "Saved. Live rows land in a moment; the rest at your next"
            .. " launch.",
        defaults = defaults,
        sections = kept,
    }, dropped
end

-- The registered artefact is TEXT, so the last thing validated is the text: we
-- render it, load it back, and validate what came OUT. That proves the
-- serializer and the schema in one pass - a mistake in either is caught here
-- rather than as a page that silently is not there.
local function renderSchema()
    local schema, dropped = buildSchema()
    -- the fingerprint covers the PAYLOAD, never the header that carries it: a
    -- hash of the whole file could not be compared against a file that already
    -- contains it
    local payload = serialize(schema, "")
    local fp = fingerprint(payload)
    local body = "-- Palvolve settings page for DarnMenu. GENERATED at startup by\n"
        .. "-- darnmenu.lua from the same row table the Mod Options page uses;\n"
        .. "-- hand edits are overwritten whenever the version below rises OR\n"
        .. "-- the fingerprint stops matching what this build renders. Your\n"
        .. "-- choices live in " .. USER_FILE .. ", never in here.\n"
        .. "-- fingerprint: " .. fp .. "\n"
        .. "return " .. payload .. "\n"

    local chunk = load(body, "@" .. SCHEMA_FILE, "t", {})
    if chunk == nil then
        return nil, nil, nil, "the generated schema did not parse"
    end
    local okRun, roundTrip = pcall(chunk)
    if not (okRun and type(roundTrip) == "table") then
        return nil, nil, nil, "the generated schema did not return a table"
    end
    local why = validateSchema(roundTrip)
    if why then return nil, nil, nil, why end
    return body, fp, dropped, nil
end

-- ------------------------------------------------------------- registration
-- ONE ROUTE: we write the two files ourselves, atomically. ToastLib carries a
-- registerMenuSchema helper that would do it, and this file used to prefer it
-- when it happened to be loaded - but its gate is VERSION-ONLY, so it cannot
-- honour the content fingerprint above and would leave a stale page on disk in
-- exactly the cases the fingerprint exists to catch (and its index merge is
-- skipped entirely when the version gate hits, which is the other half of the
-- MAJOR below). Two writers with two different gates on the same two files was
-- never worth the branch; there is now one writer and one gate.
--
-- Returns a STATUS, not a boolean, because the two files fail independently and
-- the log has to be able to say which one landed:
--   "ok"               both files are in the state we want
--   "schema-failed"    the page file could not be written; nothing else tried
--   "index-unreadable" the page file is in place, but the index (and its .bak)
--                      could not be parsed - so we refused to rewrite it
--   "index-failed"     the page file is in place, the index write did not land
local function registerDirect(body, fp)
    local schemaPath = SHARED .. SCHEMA_FILE
    -- The gate, on the file's own text. A file at a NEWER version is never
    -- touched (a future build of this mod owns it, and clobbering it down to
    -- our rows would be a lie about what is installed); at OUR version the
    -- fingerprint decides, so a page whose content moved without the version
    -- moving is rewritten and a relaunch that changed nothing is free. No
    -- fingerprint at our own version means a file from a build that predates
    -- this gate: rewrite it, which is what puts the fingerprint there.
    local existing = readFile(schemaPath)
    local rewrite = true
    if existing ~= nil then
        local have = tonumber(existing:match("schemaVersion%s*=%s*(%d+)"))
        if have ~= nil and have > ModOptions.DARN_SCHEMA_VERSION then
            rewrite = false
        elseif have == ModOptions.DARN_SCHEMA_VERSION then
            rewrite = (existing:match("fingerprint:%s*(%x+)") ~= fp)
        end
    end
    if rewrite and not writeAtomic(schemaPath, body) then return "schema-failed" end

    -- The index is checked EVERY launch even when the schema file was current:
    -- it is a shared file that DarnMenu's own repair pass rewrites, and losing
    -- our line there costs the page just as surely as losing the schema.
    --
    -- IT IS ALSO NOT OURS. Every registered mod has a line in that file and
    -- nobody re-adds theirs on our behalf (ToastLib's own writer returns before
    -- its index merge whenever its version gate hits), so a read that collapsed
    -- "corrupt" into "missing" and wrote back a fresh list would silently
    -- unregister every OTHER page on the machine. Hence the three-state read
    -- below, which is writers.lua's readState in miniature:
    --   (a) the primary parses            -> merge into it
    --   (b) primary missing or unparseable -> the .bak, which is the exact file
    --       THEIR reader falls back to; a merged rewrite from it also restores
    --       the primary, so the recovery is worth taking
    --   (c) text on disk, neither parses  -> REFUSE. One precise line, the page
    --       file stays written, and the page appears as soon as the index is
    --       healthy again. Preserving somebody else's registrations beats
    --       publishing ours (writers.lua's own law: never overwrite a malformed
    --       config).
    local indexPath = SHARED .. INDEX_FILE
    local primaryRaw = readFile(indexPath)
    local bakRaw = nil
    local base, fromBak = nil, false
    if primaryRaw ~= nil then base = loadTable(primaryRaw, INDEX_FILE) end
    if base == nil then
        bakRaw = readFile(indexPath .. ".bak")
        if bakRaw ~= nil then
            base = loadTable(bakRaw, INDEX_FILE .. ".bak")
            fromBak = (base ~= nil)
        end
    end
    if base == nil then
        if primaryRaw ~= nil or bakRaw ~= nil then return "index-unreadable" end
        base = {}      -- genuinely absent: we are the first registrant here
    end

    -- SORTED NUMERIC KEYS, never ipairs - mirroring schemas.lua's own walk, and
    -- for its reason: one hole in a hand-edited index would end an ipairs walk
    -- early and drop every entry after it, which is the same wipe by a quieter
    -- route. Existing names are copied byte-faithfully (repairing THEIR entries
    -- is DarnMenu's job, not ours) and deduped CASE-INSENSITIVELY, because that
    -- is how DarnMenu dedupes: a "palvolve" already in the list is us, and
    -- appending "Palvolve" beside it would leave one of the two dead forever.
    local entries = {}
    for key, name in next, base do
        if type(key) == "number" and key >= 1 and key % 1 == 0 then
            entries[#entries + 1] = { key = key, name = name }
        end
    end
    table.sort(entries, function(a, b) return a.key < b.key end)

    local names, seen, present, skipped = {}, {}, false, 0
    local mine = SCHEMA_NAME:lower()
    for _, entry in ipairs(entries) do
        local name = entry.name
        if type(name) ~= "string" then
            skipped = skipped + 1   -- cannot be rendered back out; DarnMenu's
                                    -- repair pass drops these too
        else
            local lower = name:lower()
            if not seen[lower] then
                seen[lower] = true
                names[#names + 1] = name
                if lower == mine then present = true end
            end
        end
    end

    -- Already listed and the primary was readable: nothing to write. (Recovered
    -- from the .bak, we DO write, even when our name is already in it - that
    -- rewrite is what puts a healthy primary back.)
    if present and not fromBak then return "ok" end
    if not present then names[#names + 1] = SCHEMA_NAME end
    if skipped > 0 then
        Log(string.format("[settings] %d entry/entries in %s were not names and"
            .. " could not be carried over", skipped, INDEX_FILE))
    end

    local parts = {
        "-- DarnMenu schema index (maintained by registering mods; safe to delete --",
        "-- every registered mod rebuilds its entry on the next launch)",
        "return {",
    }
    for _, name in ipairs(names) do
        parts[#parts + 1] = string.format("  %q,", name)
    end
    parts[#parts + 1] = "}"
    -- fromBak -> preserveBak: the primary we are replacing is the broken one,
    -- so it must NOT be parked over the healthy .bak we just read this from
    if not writeAtomic(indexPath, table.concat(parts, "\n") .. "\n", fromBak) then
        return "index-failed"
    end
    return "ok"
end

-- ------------------------------------------------------------------- poll
-- The event source, read and reconciled. Runs off modoptions.lua's 2s pump, so
-- there is no loop, no timer and no frame watcher anywhere in this file.

-- The known keys of an untrusted table, each through THE SAME coerce the MOF
-- path uses - which clamps to OUR row bounds. DarnMenu rejects out-of-range
-- input at the keyboard rather than clamping it, but this file can be
-- hand-edited afterwards and a clamp is the only answer that keeps a session
-- sane. rawget: loadTable's sandbox cannot build a metatable, and belt is
-- cheap. Coercing BEFORE the diff is what makes the diff trustworthy - two
-- spellings of the same clamped value are one value here, so a re-Apply of an
-- unchanged row costs nothing.
local function snapshotOf(user)
    local values, n = {}, 0
    for _, row in ipairs(ModOptions.valueRows()) do
        local stored = rawget(user, row.key)
        if stored ~= nil then
            local value = ModOptions.coerceValue(row, stored)
            if value ~= nil then
                values[row.key] = value
                n = n + 1
            end
        end
    end
    return values, n
end

local function reconcile()
    local raw = readFile(SHARED .. USER_FILE)
    if raw == nil then return end          -- never Applied: nothing exists yet
    -- recoveryPending (set at init: file had keys, no store existed) must not
    -- be starved by the fast path - the file is usually UNCHANGED since the
    -- init seed, and recovery is the one case where unchanged still acts
    if raw == lastRaw and not recoveryPending then return end
    lastRaw = raw                          -- baseline moves even if nothing
                                           -- below matches, so a file full of
                                           -- keys we do not own is read once

    -- Sandbox-loaded like everything else out of shared/ (see loadTable): the
    -- file is `return { ... }` and needs no globals at all, so a hostile copy
    -- gets none. Whatever comes back is then treated as untrusted data.
    local user, why = loadTable(raw, USER_FILE)
    if user == nil then
        Log("[settings] " .. USER_FILE .. " " .. tostring(why)
            .. " - ignored this pass")
        return
    end

    local values, n = snapshotOf(user)
    local changes, count, recovery = {}, 0, false

    if recoveryPending then
        -- deferred from init (fix-verify round 2): the file held the player's
        -- page choices and no store existed. The APPLY had to wait for the
        -- first poll - a store write inside init would race the MOF
        -- callback's ~3.85s drift rebuild - but the baseline was already
        -- seeded at init, so a pre-poll Apply still lands as part of this.
        recoveryPending = false
        lastValues = values
        changes, count, recovery = values, n, true
    elseif lastValues == nil then
        -- FIRST READ OF THE SESSION - the boot seed. See the header: this file
        -- is an accumulated overlay, so replaying it would re-assert every
        -- Apply the player ever made on that page over a store that may hold
        -- something newer for the same key. We take it as the baseline and
        -- apply NOTHING...
        lastValues = values
        if n == 0 then return end
        if ModOptions.cacheExists() then
            Log(string.format("[settings] %d saved values read from the"
                .. " settings page and taken as this session's baseline"
                .. " - not re-applied (the options cache is the live record)",
                n))
            return
        end
        -- ...with the ONE exception: there is no options cache at all, so
        -- there is nothing newer to stomp and a DarnMenu-only player would
        -- otherwise lose every choice on that page. Adopt it, once, out loud.
        recovery = true
        changes, count = values, n
    else
        -- PER KEY, against the previous parsed snapshot. The text compare above
        -- is only the fast path; a file that grew a key we do not own, or was
        -- rewritten with the same values, moves nothing here. A key that
        -- VANISHED from the file is not reverted - the overlay asserting
        -- nothing about a key is not the same as asserting a default, and we
        -- have no value to revert to that the store does not already hold.
        -- KNOWN RESIDUAL of delta-only (both menus): a key already AT the
        -- target value in this store cannot be re-asserted from either menu
        -- (no change event exists) - toggle away and back to force one. The
        -- price of killing the mutual-revert bug; the right trade.
        for key, value in pairs(values) do
            if lastValues[key] ~= value then
                changes[key] = value
                count = count + 1
            end
        end
        lastValues = values
        if count == 0 then return end
    end

    -- MIRROR FIRST, ANNOUNCE FROM THE RESULT - modoptions' onApply law, for the
    -- same reason: a notice promising "next launch" is only true if the file
    -- that carries it there actually landed. writeCache merges these keys OVER
    -- the current store rather than replacing it, so the other menu's values
    -- survive (that merge lives in modoptions.lua now - one code path, both
    -- menus).
    local wrote = ModOptions.writeCache(changes)
    -- NOTE the shared restartAnnounced latch inside applyValues: it is ONE set
    -- per session across both menus, so a restart row already announced by the
    -- Mod Options page is not announced a second time here. Accepted - the
    -- alternative is telling the player twice about one pending change.
    local applied, pending = ModOptions.applyValues(changes, wrote)
    if recovery then
        Log(string.format("[settings] no options cache found - the %d values"
            .. " saved on the settings page were adopted for this launch",
            count))
    end
    Log(string.format(
        "[settings] %d live values applied from the settings page", applied))
    if pending then
        Log("[settings] " .. table.concat(pending, ", ")
            .. ": takes effect at the next launch")
    end
end

function DarnMenu.poll()
    if not available then return end
    local ok, err = pcall(reconcile)
    -- one-shot, same law as the pump's own latch: a persistent throw would
    -- otherwise print every 2s for the rest of the session
    if not ok and not pollFailed then
        pollFailed = true
        Log("[settings] reading the settings page's file failed: "
            .. tostring(err))
    end
end

-- ------------------------------------------------------------------- init
function DarnMenu.init()
    if SHARED == nil then
        Log("[settings] cannot locate the shared folder - settings page off")
        return
    end
    caps = probeCaps()
    if caps == nil then
        Log("[settings] DarnMenu not installed - settings page off"
            .. " (config.lua, config_user.lua and the Mod Options menu are"
            .. " unaffected)")
        return
    end
    available = true

    local body, fp, dropped, why = renderSchema()
    if body == nil then
        -- We still poll. The page we would have written is not the page on
        -- disk: an older, valid one may already be registered from a previous
        -- launch, and the player's saved choices in Palvolve_user.lua are real
        -- either way. Refusing to read them would punish them for our bug.
        Log("[settings] page NOT registered - " .. tostring(why))
    else
        -- The two files fail independently, so the line says which one landed.
        -- "stays as it was" is only ever true of a file we did not write.
        local status = registerDirect(body, fp)
        if status == "ok" then
            Log(string.format("[settings] settings page registered (schema v%d,"
                .. " fingerprint %s, DarnMenu %s)",
                ModOptions.DARN_SCHEMA_VERSION, fp,
                tostring(caps.version or "unknown")))
        elseif status == "schema-failed" then
            Log("[settings] could not write " .. SCHEMA_FILE .. " in " .. SHARED
                .. " - any page already registered there stays as it was")
        elseif status == "index-unreadable" then
            Log("[settings] " .. SCHEMA_FILE .. " IS written, but " .. INDEX_FILE
                .. " does not parse and neither does its .bak - it was left"
                .. " untouched rather than rewritten without the other mods"
                .. " listed in it. Deleting that one file lets pages"
                .. " re-register, though some mods only re-add their entry"
                .. " when their own schema next changes.")
        else
            Log("[settings] " .. SCHEMA_FILE .. " IS written, but the entry in "
                .. INDEX_FILE .. " could not be: DarnMenu may still show the"
                .. " page from its .bak fallback; the write retries next launch")
        end
        for _, name in ipairs(dropped) do
            Log("[settings] '" .. name .. "' omitted from the settings page:"
                .. " not a key DarnMenu can capture")
        end
    end

    -- BOOT SEED, read-only, HERE at init (fix-verify round 2): seeding on the
    -- first poll left a window where the player's very first pre-poll Apply
    -- was swallowed as boot state. Recording the baseline NOW closes it for
    -- every session where the file is readable at init - anything the first
    -- poll then sees differing from THIS baseline is a real post-boot Apply.
    -- Only the recovery APPLY stays deferred to the first poll (see
    -- recoveryPending above). A file that exists but will not read this
    -- instant stays unseeded and takes the reconcile fallback (seed without
    -- apply) - the old, far narrower window, accepted and documented there.
    do
        local raw = readFile(SHARED .. USER_FILE)
        if raw ~= nil then
            local user = loadTable(raw, USER_FILE)
            if user ~= nil then
                local values, n = snapshotOf(user)
                lastRaw, lastValues = raw, values
                if n > 0 and not ModOptions.cacheExists() then
                    recoveryPending = true
                elseif n > 0 then
                    -- the seed receipt: read, held as baseline, applied not
                    Log(string.format("[settings] %d saved values read from"
                        .. " the settings page and taken as this session's"
                        .. " baseline - not re-applied (the options cache is"
                        .. " the live record)", n))
                end
            end
        end
    end

    -- The poll rides modoptions.lua's existing 2s pump - no new loop.
    ModOptions.setAuxPoll(DarnMenu.poll)
end

return DarnMenu
