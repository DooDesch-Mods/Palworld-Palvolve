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
-- Rewriting on every launch also repairs the file after a Workshop update
-- replaced the PalSchema folder with the shipped default.

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

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- <...>/Mods/Palvolve/scripts/guidepages.lua -> <...>/Mods/PalSchema/mods/Palvolve/helpguide/...
local function guideFile()
    local path = nil
    pcall(function()
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) ~= "@" then return end
        local scripts = src:sub(2):match("^(.*)[/\\]")           -- .../Palvolve/scripts
        local modRoot = scripts and scripts:match("^(.*)[/\\]")  -- .../Palvolve
        local modsDir = modRoot and modRoot:match("^(.*)[/\\]")  -- .../Mods
        if modsDir then
            path = modsDir .. "\\PalSchema\\mods\\Palvolve\\helpguide\\palvolve_guide.json"
        end
    end)
    return path
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

-- One "-> Target - Lv 30 - Night - 1x Evolution Stone" line.
local function targetLine(displayName, pair, worldCtx)
    -- some species names carry a trailing space in the game's own text table
    local name = (displayName(pair.to) or ""):gsub("%s+$", "")
    local parts = { "  -> " .. name }

    local level = tonumber(pair.minLevel) or 0
    if level > 0 then
        table.insert(parts, I18n.msg("guideLevelShort", level))
    end

    local cond = Conditions.describe(pair)
    if cond and cond ~= "" then table.insert(parts, cond) end

    -- Prices are level-banded, so the pair's own minimum is the honest level to
    -- quote here; it is the earliest point the player can pay it.
    local okCost, costList = pcall(Costs.resolve, pair, level, worldCtx)
    if okCost and type(costList) == "table" and #costList > 0 then
        local okDesc, text = pcall(Costs.describe, costList)
        if okDesc and text and text ~= "" then table.insert(parts, text) end
    end

    return table.concat(parts, " - ")
end

-- Groups the enabled pairs by source species, sorted by the name the player
-- sees rather than by the internal id.
local function speciesBlocks(displayName, worldCtx)
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

    local names = {}
    for _, id in ipairs(order) do names[id] = displayName(id) end
    table.sort(order, function(a, b)
        if names[a] == names[b] then return a < b end
        return names[a] < names[b]
    end)

    local blocks = {}
    for _, id in ipairs(order) do
        local lines = { names[id] }
        for _, pair in ipairs(bySource[id]) do
            table.insert(lines, targetLine(displayName, pair, worldCtx))
        end
        table.insert(blocks, table.concat(lines, BR))
    end
    return blocks
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

-- Builds the whole file. Returns the JSON text, or nil plus a reason.
function GuidePages.build(displayName, worldCtx)
    if type(displayName) ~= "function" then return nil, "no name resolver" end

    local blocks = speciesBlocks(displayName, worldCtx)
    if #blocks == 0 then return nil, "no enabled pairs" end
    local pages = paginate(blocks)

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
local generated = false

-- Called when the local player's character finishes entering a world. Species
-- names come from the game's own localization, which answers nothing until
-- then, and a guide full of raw ids would be worse than no guide at all.
--
-- This used to be a timer, which was the wrong shape: whatever window it had
-- expired while the player was still in the menu, and the guide then never
-- updated for the rest of the session.
function GuidePages.onEnterWorld(worldCtx)
    if generated or not nameResolver then return end
    generated = true

    -- One short delay, not a poll: the character is up, but the text tables
    -- answer a moment later, and a name lookup that misses gets cached as the
    -- raw id for the session.
    local ran = false
    LoopAsync(3000, function()
        if ran then return true end
        ran = true
        ExecuteInGameThread(function()
            -- A server's tree is on loan for as long as this client is on that
            -- server; the guide is a FILE in the player's own PalSchema folder.
            -- Written from a borrowed tree it would still describe that server's
            -- pairs the next time the player starts their own game. Re-armed
            -- rather than skipped, so the next world of their own writes it.
            local okSync, sync = pcall(require, "treesync")
            if okSync and sync and sync.isActive and sync.isActive() then
                generated = false
                Log("guide pages: a server's tree is active, leaving the local guide alone")
                return
            end
            local ctx = worldCtx
            if not (ctx and ctx:IsValid()) then
                pcall(function() ctx = FindFirstOf("PalPlayerCharacter") end)
            end
            local okBuild, text, reason = pcall(GuidePages.build, nameResolver, ctx)
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
        end)
        return true
    end)
end

function GuidePages.init(displayName)
    nameResolver = displayName
end

return GuidePages
