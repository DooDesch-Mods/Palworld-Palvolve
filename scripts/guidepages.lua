-- Survival Guide pages for the configured evolution tree.
--
-- The game's Survival Guide is fed by DA_HelpGuideDataAsset, and PalSchema's
-- helpguide loader adds entries to it from JSON. That makes the guide the one
-- native screen a mod can extend without cooking a widget: correct fonts,
-- gamepad navigation and open/close sounds come for free.
--
-- Like the workbench stage in techlevel.lua this writes a PalSchema file, so a
-- change applies on the next start rather than immediately. That matches the
-- data it describes: config_user.lua is read once at startup too, so a tree the
-- player just downloaded is not live in this session either.
--
-- Rewriting on every launch also repairs the file after a reinstall replaced
-- the PalSchema folder with the shipped default.
--
-- FORK SHAPE: the content is expensive to produce - one localized species name
-- per source and per target, one drop-table resolve and one localized item name
-- per cost entry - and the fork's tree carries ~270 routes where upstream's
-- carries a fraction of that. Upstream builds the whole file inside a single
-- game-thread call; here the species are worked through in TIME-BUDGETED slices
-- (SLICE_BUDGET below), so the work is handed back to the game between species
-- instead of being taken in one block. The budget is checked BETWEEN species,
-- not inside one, so a single species always finishes what it started - a block
-- is never half-built - and one very expensive species can still overrun the
-- budget on its own. Nothing is visible this session anyway, so a build that
-- spreads over half a minute in the background costs the player exactly nothing.
--
-- The other half of upstream's shape is a SETTLING WAIT: the game's text tables
-- answer with raw ids for a while after world entry, and a slice that runs in
-- that window bakes "PinkCat" into the page for the whole session. Upstream
-- waited a flat 3s before building. Here the wait is measured instead of timed
-- (SETTLE_CAP below): the first species' name is resolved once per tick and the
-- job only starts once the tables answer with something other than the id they
-- were asked about.

local Config = require("config")
local Conditions = require("conditions")
local Costs = require("costs")
local I18n = require("i18n")

local GuidePages = {}

-- The vanilla guide has 47 entries. Splitting the tree across a few long pages
-- instead of one page per species keeps our share of that list small; a player
-- looking for a game topic should not have to scroll past 200 mod entries.
local MAX_PAGE_CHARS = 3000

-- A texture is part of every note. This one is the guide's own vanilla art, so
-- the pages need no packed asset and cannot point at something that is missing.
local TEXTURE = "/Game/Pal/Texture/HelpGuide/T_HelpGuide.T_HelpGuide"

-- Entry order in the list follows map key order, so the ids carry their own
-- sort. No platform-looking suffix (the guide filters ids like Help_2_PS5).
local ID_PREFIX = "Palvolve_"

-- Slice pacing. The budget is measured, not counted, because the per-species
-- price depends entirely on how fast the game's text tables answer: where a
-- lookup is cheap the whole tree lands in one or two slices, where it is not
-- the same code spreads out instead of freezing the frame. MAX_SLICES is the
-- bound every poll in this mod carries - ~2 minutes at this interval, far past
-- what the largest sane tree needs.
local POLL_MS = 500
local SLICE_BUDGET = 0.05
local MAX_SLICES = 240
-- How long the settling probe waits for the text tables before building anyway.
-- A species whose display name legitimately IS its id (an unlocalized modded
-- pal, a locale with no row for it) must not cost the guide its pages, so the
-- wait is a delay and never a condition.
local SETTLE_CAP = 30

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- <...>\Mods\Palvolve-Fork\Scripts\guidepages.lua
--   -> <...>\Mods\PalSchema\mods\Palvolve-Fork\helpguide\palvolve_guide.json
--
-- Same derivation as techlevel.lua's buildingFile (and evolution.lua's
-- STATE_FILE): the game's working directory is not the mod's, so this script's
-- own source path is the only reliable anchor, and the mod folder NAME is read
-- back off it rather than written out - the two halves install under the same
-- name, so a renamed install keeps finding its own data.
local function guideFile()
    local path = nil
    pcall(function()
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) ~= "@" then return end
        local scripts = src:sub(2):match("^(.*)[/\\]")           -- ...\Palvolve-Fork\Scripts
        local modRoot = scripts and scripts:match("^(.*)[/\\]")  -- ...\Palvolve-Fork
        local modsDir = modRoot and modRoot:match("^(.*)[/\\]")  -- ...\Mods
        local modName = modRoot and modRoot:match("([^/\\]+)$")  -- Palvolve-Fork
        if modsDir and modName and modName ~= "" then
            path = modsDir .. "\\PalSchema\\mods\\" .. modName
                .. "\\helpguide\\palvolve_guide.json"
        end
    end)
    return path
end

-- The data half ships this folder, so it normally exists; this covers a partial
-- install and the player who deleted it. There is no mkdir to call here - the
-- probe IS the test, because io.open in write mode fails when the directory is
-- missing - and the shell fallback is the same inert last-ditch config.lua uses
-- for the user folder: a Lua without a usable os.execute simply leaves it a
-- no-op and the re-probe decides. Warns once and then writes nothing; a guide
-- page is never worth a line of noise per launch, let alone a failed init.
local dirWarned = false
local function ensureDir(filePath)
    local dir = filePath:match("^(.*)[/\\]")
    if not dir then return false end
    local function probe()
        local f = io.open(dir .. "\\.palvolve", "w")
        if not f then return false end
        f:close()
        os.remove(dir .. "\\.palvolve")
        return true
    end
    if probe() then return true end
    pcall(os.execute, 'mkdir "' .. dir .. '" >nul 2>nul')
    if probe() then return true end
    if not dirWarned then
        dirWarned = true
        Log("guide pages: " .. dir .. " is not writable - pages unchanged")
    end
    return false
end

-- JSON string body. Species names come from the game's own text tables, so the
-- text can carry any UTF-8; only the structural characters and the control
-- range need escaping.
local function jsonEscape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    s = s:gsub("[%z\1-\31]", function(c)
        return string.format("\\u%04x", string.byte(c))
    end)
    return s
end

-- A real line break, never the two-character escape sequence. The whole body
-- runs through jsonEscape, which doubles a backslash - writing the escape here
-- put a visible backslash-n into the guide text instead of a line break.
-- jsonEscape turns this character into a proper JSON escape on its own.
local BR = "\n"

-- ---------------------------------------------------------------- page text

-- One "-> Target - Lv 30 - Night + (Muddy or Wet) - 1x Evolution Stone" line.
-- The condition half comes from Conditions.describe, which is what the palpedia
-- panel and the wheel's center text render too, so an either/or group reads
-- with the same joiner in all three places.
local function targetLine(displayName, pair, worldCtx)
    -- some species names carry a trailing space in the game's own text table
    local name = (displayName(pair.to) or ""):gsub("%s+$", "")
    if name == "" then name = tostring(pair.to) end
    local parts = { "  -> " .. name }

    -- floored before it reaches the catalog: guideLevelShort is "%d" in all 17
    -- locales, and a config-derived float would make I18n.msg fall over and
    -- print the bare key into the page. Flooring here also keeps the level the
    -- page quotes and the level the price resolves at the same number - and the
    -- same one the wheel's center text uses (evolution.lua floors it too)
    local level = math.floor(tonumber(pair.minLevel) or 0)
    if level > 0 then
        table.insert(parts, I18n.msg("guideLevelShort", level))
    end

    local cond = Conditions.describe(pair)
    if cond and cond ~= "" then table.insert(parts, cond) end

    -- Prices are level-banded, so the pair's own minimum is the honest level to
    -- quote here; it is the earliest point the player can pay it. A `free` pair
    -- resolves to an empty list and prints no cost at all.
    local okCost, costList = pcall(Costs.resolve, pair, level, worldCtx)
    if okCost and type(costList) == "table" and #costList > 0 then
        local okDesc, text = pcall(Costs.describe, costList)
        if okDesc and text and text ~= "" then table.insert(parts, text) end
    end

    return table.concat(parts, " - ")
end

-- Groups the enabled pairs by source species. Pure Lua over the loaded map and
-- nothing else, so it can run in the poll body; every native touch lives in
-- speciesBlock below.
local function groupPairs()
    local bySource, order = {}, {}
    for _, pair in ipairs(Config.map or {}) do
        if pair.enabled then
            if not bySource[pair.from] then
                bySource[pair.from] = {}
                table.insert(order, pair.from)
            end
            table.insert(bySource[pair.from], pair)
        end
    end
    return bySource, order
end

-- One species: its name, then one line per target. Native-heavy - every call in
-- here reaches the game's own tables, so it only ever runs from the game-thread
-- slice further down.
local function speciesBlock(job, id)
    local name = (job.displayName(id) or ""):gsub("%s+$", "")
    if name == "" then name = id end
    local lines = { name }
    for _, pair in ipairs(job.bySource[id]) do
        table.insert(lines, targetLine(job.displayName, pair, job.worldCtx))
    end
    return { name = name, id = id, text = table.concat(lines, BR) }
end

-- Splits the blocks into pages under the character budget. A species block is
-- never cut in half: a target list that continues on the next page reads as a
-- bug to anyone who does not know why it happened.
local function paginate(blocks)
    local pages, current, size = {}, {}, 0
    for _, block in ipairs(blocks) do
        if #current > 0 and (size + #block) > MAX_PAGE_CHARS then
            table.insert(pages, current)
            current, size = {}, 0
        end
        table.insert(current, block)
        size = size + #block
    end
    if #current > 0 then table.insert(pages, current) end
    return pages
end

-- ---------------------------------------------------------------- build job

-- Upstream's build(displayName, worldCtx) is split in three here - newJob,
-- stepJob, build - so the expensive middle can be paid across several ticks.
-- The job carries everything a slice needs; nothing else is module state, so an
-- abandoned run leaves no half-built page behind.
local function newJob(displayName, worldCtx)
    if type(displayName) ~= "function" then return nil, "no name resolver" end
    local bySource, order = groupPairs()
    if #order == 0 then return nil, "no enabled pairs" end
    return {
        displayName = displayName,
        worldCtx = worldCtx,
        bySource = bySource,
        order = order,
        i = 1,
        blocks = {},
    }
end

-- Works through the species list until the time budget is spent, always
-- finishing the species it started so a block is never half-built (and always
-- doing at least one, so progress is guaranteed even when a single species
-- costs more than the whole budget). Returns true when the last one is done.
-- Each species is pcall'd on its own: one name the text tables refuse must cost
-- that species its lines, not the guide.
local function stepJob(job, budget)
    local startedAt = os.clock()
    repeat
        local id = job.order[job.i]
        if not id then break end
        job.i = job.i + 1
        local ok, block = pcall(speciesBlock, job, id)
        if ok and type(block) == "table" then table.insert(job.blocks, block) end
    until (os.clock() - startedAt) >= budget
    return job.i > #job.order
end

-- Assembles the finished blocks into the whole file. Returns the JSON text, or
-- nil plus a reason.
function GuidePages.build(job)
    if not (job and #job.blocks > 0) then return nil, "no enabled pairs" end

    -- sorted by the name the player sees rather than by the internal id
    table.sort(job.blocks, function(a, b)
        if a.name == b.name then return a.id < b.id end
        return a.name < b.name
    end)
    local texts = {}
    for _, block in ipairs(job.blocks) do table.insert(texts, block.text) end
    local pages = paginate(texts)

    local entries = {}

    -- The title is what the list shows, and the game derives it from the first
    -- line of the description. Starting the body with a break keeps the title
    -- on its own line whichever way the loader joins the two fields.
    local function entry(id, title, body)
        table.insert(entries, string.format(
            '\t"%s": {\n\t\t"Texture": "%s",\n\t\t"Title": "%s",\n\t\t"Description": "%s"\n\t}',
            jsonEscape(id), TEXTURE, jsonEscape(title), jsonEscape(BR .. body)))
    end

    entry(ID_PREFIX .. "00_About",
        I18n.msg("guideAboutTitle"),
        I18n.msg("guideAboutBody"))

    for i, page in ipairs(pages) do
        entry(string.format("%s%02d_Tree", ID_PREFIX, i),
            I18n.msg("guideTreeTitle", i, #pages),
            I18n.msg("guideTreeIntro") .. BR .. BR .. table.concat(page, BR .. BR))
    end

    return "{\n" .. table.concat(entries, ",\n") .. "\n}\n"
end

-- ---------------------------------------------------------------- file write

-- Writes only when the content changed, so a normal launch touches no disk.
-- Never truncates the live file: an interrupted write would leave PalSchema
-- with a guide file it cannot parse, and the next start could not repair it.
function GuidePages.write(text)
    local path = guideFile()
    if not path then
        Log("guide pages: could not resolve the PalSchema folder - pages unchanged")
        return false
    end
    if not ensureDir(path) then return false end

    local existing = nil
    local f = io.open(path, "rb")
    if f then
        existing = f:read("*a")
        f:close()
    end
    if existing == text then return true end

    local tmp = path .. ".new"
    local out = io.open(tmp, "wb")
    if not out then
        Log("guide pages: cannot write next to the PalSchema guide file - pages unchanged")
        return false
    end
    local wrote = out:write(text)
    local closed = out:close()
    if not (wrote and closed) then
        os.remove(tmp)
        Log("guide pages: write failed - pages unchanged")
        return false
    end

    local check = io.open(tmp, "rb")
    local verify = check and check:read("*a") or nil
    if check then check:close() end
    if verify ~= text then
        os.remove(tmp)
        Log("guide pages: written file did not verify - pages unchanged")
        return false
    end

    local backup = path .. ".bak"
    os.remove(backup)
    if existing and not os.rename(path, backup) then
        os.remove(tmp)
        Log("guide pages: could not set the old file aside - pages unchanged")
        return false
    end
    if not os.rename(tmp, path) then
        if existing then os.rename(backup, path) end
        os.remove(tmp)
        Log("guide pages: could not swap the guide file in - pages unchanged")
        return false
    end
    os.remove(backup)
    return true
end

-- ---------------------------------------------------------------- entry point

local nameResolver = nil
local worldRef = nil
local started = false
local finished = false
local job = nil
local slices = 0
-- settling probe state: latched true the moment the text tables answer with a
-- real name (or the cap runs out), never re-armed for the session
local settled = false
local probeSince = nil

-- One slice of work, always on the game thread. Every step is guarded and
-- everything it needs sits in `job`, so a slice that returns early simply costs
-- one tick: the next one picks the same job back up.
local function runSlice()
    if finished then return end

    -- the world context is re-checked per slice rather than trusted from world
    -- entry: a build that spans a world switch would otherwise hand a freed
    -- actor to the drop lookup
    local alive = false
    pcall(function() alive = worldRef and worldRef:IsValid() end)
    if not alive then
        local ctx = nil
        pcall(function() ctx = FindFirstOf("PalPlayerCharacter") end)
        pcall(function() alive = ctx and ctx:IsValid() end)
        if not alive then return end -- world not up yet: retry next slice
        worldRef = ctx
    end

    if not job then
        local newOne, reason = newJob(nameResolver, worldRef)
        if not newOne then
            finished = true
            Log("guide pages: " .. tostring(reason))
            return
        end
        job = newOne
    end
    job.worldCtx = worldRef

    -- Settling gate. Building the job is pure Lua, so it happens above either
    -- way; what waits is the first SLICE. The probe asks the resolver for the
    -- first species' name and only lets the work start once the answer is not
    -- the id it asked about - the state the tables are in for a moment after
    -- world entry, and the reason upstream slept 3s here. The cap is the
    -- backstop for a name that never resolves: the pages are still worth having
    -- with a raw id or two in them, and one line says which case this was.
    if not settled then
        if not probeSince then probeSince = os.clock() end
        local first = job.order[1]
        local probe = nil
        pcall(function() probe = job.displayName(first) end)
        probe = type(probe) == "string" and probe:gsub("%s+$", "") or ""
        if probe ~= "" and probe ~= first then
            settled = true
        elseif (os.clock() - probeSince) < SETTLE_CAP then
            return -- not settled yet: the same probe runs again next slice
        else
            settled = true
            -- %g, not %d: the cap is a number someone will edit one day
            Log(string.format(
                "guide pages: species names still unresolved after %gs - building anyway",
                SETTLE_CAP))
        end
    end

    if not stepJob(job, SLICE_BUDGET) then return end

    -- last slice: the guide is written once per session either way
    finished = true
    local okBuild, text, reason = pcall(GuidePages.build, job)
    job = nil
    if not okBuild then
        Log("guide pages: " .. tostring(text))
        return
    end
    if not text then
        Log("guide pages: " .. tostring(reason))
        return
    end
    if GuidePages.write(text) then
        Log("guide pages: survival guide updated, visible after the next start")
    end
end

-- Called when the local player's character finishes entering a world. Species
-- names come from the game's own localization, which answers nothing until
-- then, and a guide full of raw ids would be worse than no guide at all.
--
-- Armed from the world-entry callback rather than from a timer started at load:
-- upstream learned that the hard way - whatever window a load-time timer had
-- expired while the player was still in the menu, and the guide then never
-- updated for the rest of the session.
function GuidePages.onEnterWorld(worldCtx)
    if started or not nameResolver then return end
    started = true
    worldRef = worldCtx

    LoopAsync(POLL_MS, function()
        -- pure Lua before anything reaches the game thread: once the guide is
        -- written (or the bound is spent) this loop stops instead of scheduling
        -- another callback per tick
        if finished then return true end
        slices = slices + 1
        if slices > MAX_SLICES then
            finished = true
            Log(string.format("guide pages: unfinished after %d slices - pages unchanged", MAX_SLICES))
            return true
        end
        ExecuteInGameThread(function()
            pcall(runSlice)
        end)
        return false
    end)
end

-- Cheap on purpose: main.lua calls this at load, where there is no world to
-- read names from yet. It only remembers the resolver; onEnterWorld starts the
-- work. A resolver that never arrived is said out loud once - without it the
-- module would simply stay silent forever, which reads exactly like a guide
-- that generated fine and happens to be empty.
function GuidePages.init(displayName)
    if type(displayName) ~= "function" then
        Log("guide pages: no name resolver handed in - pages unchanged")
        return
    end
    nameResolver = displayName
end

return GuidePages
