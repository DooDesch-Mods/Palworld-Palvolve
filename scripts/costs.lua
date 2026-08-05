-- Palvolve costs: resolves the full price of an evolution (stone + materials
-- derived from drop tables) and runs the multi-item consume/refund
-- transaction. Owns all inventory access.
--
-- Pricing rules:
--   evolution/funchain: evolution stone + materials from the BASE pal's drops
--   adaptation:         per-element adaptation stone + materials from the
--                       TARGET form's drops
-- DERIVED materials come from the runtime drop database when its out-param
-- marshaling works, otherwise from the baked drops_static.lua - and the
-- Config.costs.enabled switch gates that derivation, nothing else.
-- A per-pair `materials` list in the config is not one of the derivation's
-- outputs, it REPLACES it: like `free = true` it is part of the pair's own
-- design, so it charges whether the switch is on or off. A tree that prices
-- one specific evolution in a named item still prices it with materials off.

local Config = require("config")
local Elements = require("elements")
local I18n = require("i18n")

local Costs = {}

-- Display name of a cost entry, resolved at the moment a message is BUILT and
-- never stored: the resolved price list is cached for the session, and the
-- game's text system is not answering yet while the world loads - so a name
-- baked in at resolve time is a permanent fallback for the rest of the session.
--
-- An explicit label wins (a per-pair `materials` entry names its own item, and
-- a stone name the fork's config pins deliberately overrides the data half -
-- see stoneLabels below); otherwise the game's own localized item name, with
-- the configured English name as the last resort.
--
-- The element suffix is appended to those two GENERIC names only. Every
-- per-element stone is REGISTERED with its element already in the name
-- ("Primed Evolution Stone (Fire)"), so decorating a registered name would
-- repeat it; the configured stone name is one string for all ten elements and
-- carries none. Per-pair material labels never carry an element, so they are
-- returned verbatim either way.
function Costs.labelOf(entry)
    if not entry then return "?" end
    local base, registered
    if entry.label then
        base, registered = entry.label, false
    else
        base, registered = I18n.itemName(entry.id, entry.fallbackLabel)
    end
    if entry.element and not registered then
        return string.format("%s (%s)", base, I18n.element(entry.element))
    end
    return base
end

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- ---------------------------------------------------------------- inventory

-- All inventory access is scoped to a playerCtx (role.lua): on a host with
-- connected clients FindFirstOf would hit an arbitrary controller, so the
-- requesting player's controller must be threaded through explicitly.
local function inventoryDataFor(playerCtx)
    local inv = nil
    pcall(function()
        local pc = playerCtx and playerCtx.pc
        if pc and pc:IsValid() then
            inv = pc:GetPalPlayerState():GetInventoryData()
        end
    end)
    if inv and inv:IsValid() then return inv end
    return nil
end

function Costs.countItem(playerCtx, staticItemId)
    local n = 0
    pcall(function()
        local inv = inventoryDataFor(playerCtx)
        if inv then n = inv:CountItemNum(FName(staticItemId)) end
    end)
    return n
end

-- Consumes `need` items; success is determined from the count difference
-- (RequestConsumeInventoryItem is the only BP-exposed consume path).
local function tryConsumeItems(playerCtx, staticItemId, need)
    local ok = false
    pcall(function()
        local inv = inventoryDataFor(playerCtx)
        if not inv then return end
        local id = FName(staticItemId)
        local before = inv:CountItemNum(id)
        if before < need then return end
        local cdo = StaticFindObject("/Script/Pal.Default__PalIncidentBase")
        if cdo and cdo:IsValid() then
            cdo:RequestConsumeInventoryItem(inv, id, need)
        end
        local after = inv:CountItemNum(id)
        ok = (before - after) == need
    end)
    return ok
end

-- Deletes `count` items from the player's inventory for real. The in-game
-- discard only DROPS items to the ground, where they persist in the save -
-- this is the only true removal path exposed to Lua.
function Costs.removeAll(playerCtx, staticItemId, count)
    return tryConsumeItems(playerCtx, staticItemId, count)
end

local function giveItems(playerCtx, staticItemId, count)
    local res = -1
    pcall(function()
        local inv = inventoryDataFor(playerCtx)
        if inv then
            res = inv:AddItem_ServerInternal(FName(staticItemId), count, false, 0.0, true)
        end
    end)
    return res == 0
end

-- ---------------------------------------------------------------- drop data

local staticDrops = nil
local function staticDropRow(charId, level)
    if staticDrops == nil then
        local ok, t = pcall(require, "drops_static")
        staticDrops = (ok and type(t) == "table") and t or {}
    end
    local bands = staticDrops[charId]
    if not bands then return nil end
    -- bands are sorted ascending; pick the highest band the level reaches
    local chosen = bands[1]
    for _, band in ipairs(bands) do
        if level >= band.level then chosen = band end
    end
    return chosen and chosen.drops or nil
end

-- Runtime drop lookup. The out-struct marshaling is checked on the
-- first real use (never during savegame load - the call itself can crash
-- natively while the world is still restoring): the first runtime result is
-- compared against the baked table and a mismatch pins the fallback.
local runtimeBroken = false
local runtimeVerified = false
local function runtimeDropRow(charId, level, worldCtx)
    if runtimeBroken then return nil end
    local drops = nil
    pcall(function()
        local util = StaticFindObject("/Script/Pal.Default__PalUtility")
        if not (util and util:IsValid() and worldCtx and worldCtx:IsValid()) then return end
        local db = util:GetDatabaseCharacterParameter(worldCtx)
        if not (db and db:IsValid()) then return end
        local out = {}
        local found = db:GetDropItemData(FName(charId), level, out)
        if not found then return end
        local list = {}
        for i = 1, 10 do
            local id = out["ItemId" .. i]
            local idStr = nil
            pcall(function()
                if type(id) == "string" then idStr = id
                elseif id and id.ToString then idStr = id:ToString() end
            end)
            if idStr and idStr ~= "" and idStr ~= "None" then
                table.insert(list, {
                    id = idStr,
                    rate = tonumber(out["Rate" .. i]) or 0,
                    min = tonumber(out["min" .. i]) or tonumber(out["Min" .. i]) or 0,
                    max = tonumber(out["Max" .. i]) or 0,
                })
            end
        end
        if #list > 0 then drops = list end
    end)
    if drops and not runtimeVerified then
        -- one-time sanity check against the baked data; mismatched first
        -- item = marshaling produced garbage -> trust the baked table
        local st = staticDropRow(charId, level)
        if st and st[1] and drops[1].id ~= st[1].id then
            runtimeBroken = true
            Log(string.format("Runtime drop lookup mismatch (%s vs %s) - using baked table",
                drops[1].id, st[1].id))
            return nil
        end
        runtimeVerified = true
        if Config.devMode then Log("[probe-dropdata] runtime drop lookup OK (" .. drops[1].id .. ")") end
    end
    return drops
end

local function dropRow(charId, level, worldCtx)
    return runtimeDropRow(charId, level, worldCtx) or staticDropRow(charId, level)
end

-- ---------------------------------------------------------------- resolution

-- Which of the two naming fields a stone entry carries. Returns label, fallback.
--
-- The fork's stone names are a PRESET, and the primed preset's strings are
-- exactly what the data half registers as the item names - so on the default
-- preset the game's own localized name IS the configured name, only translated
-- (and already carrying its element), and the configured string only has to
-- serve as the fallback for the window before the text system answers. Any
-- OTHER name - the classic preset (primedNaming = false), or a config_user
-- rename - is a deliberate override OF that data half and has to win over it,
-- so it travels as an explicit label. labelOf decorates with the element in
-- both cases; only a name that came back from the registry is left alone.
local function stoneLabels(kind)
    local named = Config.stoneNames.userNamed
    local override = (Config.stoneNames.primedNaming == false)
        or (named ~= nil and named[kind] == true)
    if override then return Config.stoneNames[kind], nil end
    return nil, Config.stoneNames[kind]
end

local resolveCache = {}

local function materialsFor(charId, level, worldCtx)
    local c = Config.costs
    local drops = dropRow(charId, level, worldCtx)
    if not drops then
        local fb = c.fallbackMaterials and c.fallbackMaterials[charId]
        if fb then return fb end
        Log(string.format("No drop data for %s - evolution costs only the stone", charId))
        return {}
    end
    local mats = {}
    for _, d in ipairs(drops) do
        if #mats >= c.slots then break end
        if (d.rate or 0) >= c.minRate then
            local avg = ((d.min or 0) + (d.max or 0)) / 2
            local count = math.max(1, math.min(c.maxCount, math.ceil(avg * c.countScale)))
            table.insert(mats, { id = d.id, count = count })
        end
    end
    return mats
end

-- Drops all cached price lists - needed when the cost configuration is
-- toggled at runtime (devMode free-evolution switch).
function Costs.clearCache()
    resolveCache = {}
end

-- Full price of a pair at a level. Returns costList, err.
-- costList entries: { id, count, label?, fallbackLabel?, element? } - naming
-- METADATA only, never a finished display name (labelOf builds that per message)
function Costs.resolve(pair, level, worldCtx)
    -- per-pair override: a pair marked `free = true` costs nothing at all
    -- (no stone, no materials) regardless of the global cost switches -
    -- this is how a tree mixes level-only evolutions with costed ones.
    -- Fresh table each call, never cached: a free variant must never
    -- alias a costed same-target sibling through the cache below.
    if pair.free then return {} end
    -- the level is part of the key: drop tables have level bands, so the
    -- same pair can price differently at different levels. The stone kind
    -- and the per-pair materials override are part of it too: same-target
    -- either/or VARIANTS may price differently (e.g. one carries
    -- materials = {}), and a from>to:level key alone would hand one
    -- variant's cached list to the other - hiding a free variant from the
    -- auto-evolve gates, or pricing a costed one as free. That materials
    -- segment is load-bearing in BOTH switch states, since an explicit list
    -- charges on its own: with the derivation off, two same-target variants
    -- that differ ONLY in carrying one would otherwise key identically.
    local cacheKey = pair.from .. ">" .. pair.to
        .. ":" .. tostring(pair.stone)
        .. (pair.materials and (":" .. tostring(pair.materials)) or "")
        .. ":" .. tostring(level or 0)
    if resolveCache[cacheKey] then return resolveCache[cacheKey] end

    local list = {}
    if Config.requireStone then
        if pair.stone == "adaptation" then
            local element = Elements.adaptationElement(pair, worldCtx)
            local stoneId = element and Config.stoneItemIds.adaptation[element] or nil
            if not stoneId then
                -- unresolvable element: accept the legacy generic stone
                stoneId = Config.stoneItemIds.adaptationFallback
                element = nil
            end
            -- No name is baked here: the naming FIELDS travel, labelOf turns
            -- them into a line when a message is built. The element rides along
            -- so labelOf can decorate a generic name with it - displayed the way
            -- the ITEM is named ("Grass" not "Leaf", "Electric" not
            -- "Electricity"), falling back to the raw internal name if i18n has
            -- no entry for it.
            local stoneLabel, stoneFallback = stoneLabels("adaptation")
            table.insert(list, {
                id = stoneId, count = Config.stoneCount,
                element = element,
                label = stoneLabel, fallbackLabel = stoneFallback,
            })
        else
            local stoneLabel, stoneFallback = stoneLabels("evolution")
            table.insert(list, {
                id = Config.stoneItemIds.evolution, count = Config.stoneCount,
                label = stoneLabel, fallbackLabel = stoneFallback,
            })
        end
    end
    -- An explicit per-pair list is the pair's OWN price, deliberately authored
    -- alongside its `free`/`stone` fields, and charges regardless of the global
    -- material switch - which gates only the DERIVED drop-table bill below.
    -- (So a pair listing a named item stays costed with materials off, and an
    -- empty `materials = {}` stays the pair's way of buying out of the bill.)
    local mats = nil
    if pair.materials then
        mats = pair.materials
    elseif Config.costs.enabled then
        -- adaptation prices from the TARGET form, evolutions from the BASE
        local matSource = (pair.stone == "adaptation") and pair.to or pair.from
        mats = materialsFor(matSource, level, worldCtx)
    end
    if mats then
        for _, m in ipairs(mats) do
            -- a per-pair `materials` entry may name its own item; without one
            -- the id alone travels and labelOf localizes it, falling back to
            -- the raw id when the text system has nothing for it
            table.insert(list, { id = m.id, count = m.count, label = m.label })
        end
    end
    -- coalesce duplicate item ids (a drop row can repeat an item across
    -- slots; check() counts per entry and would otherwise pass on a total
    -- the inventory cannot actually cover)
    local byId, merged = {}, {}
    for _, c in ipairs(list) do
        if byId[c.id] then
            byId[c.id].count = byId[c.id].count + c.count
        else
            local entry = { id = c.id, count = c.count, label = c.label,
                            element = c.element, fallbackLabel = c.fallbackLabel }
            byId[c.id] = entry
            table.insert(merged, entry)
        end
    end
    resolveCache[cacheKey] = merged
    return merged
end

-- Hands a RECORDED cost back, for a finished evolution that is rolled back.
-- Distinct from the transaction refund below, which only ever undoes a consume
-- that has not been committed yet: by the time a rollback happens the
-- transaction is long closed, so the list travels in the snapshot instead and
-- arrives here as bare { id, count } rows (no labels - see describe).
-- Returns true only when every entry landed.
function Costs.refund(playerCtx, list)
    if type(list) ~= "table" then return true end
    local allOk = true
    for _, c in ipairs(list) do
        if c.id and c.count and c.count > 0 then
            if not giveItems(playerCtx, c.id, c.count) then allOk = false end
        end
    end
    return allOk
end

-- Returns ok, missing[] where the missing entries keep the naming FIELDS (not a
-- name) plus count/have, so the description resolves the item name at the moment
-- the message is actually built - see labelOf.
function Costs.check(playerCtx, costList)
    local missing = {}
    for _, c in ipairs(costList) do
        local have = Costs.countItem(playerCtx, c.id)
        if have < c.count then
            table.insert(missing, { id = c.id, label = c.label, element = c.element,
                                    fallbackLabel = c.fallbackLabel,
                                    count = c.count, have = have })
        end
    end
    return #missing == 0, missing
end

-- A config_user count can arrive non-integral (2.5), and %d - which every
-- costEntry/costEntryMissing template uses - RAISES on a float in Lua 5.4
-- ("number has no integer representation"). Floor at format time so the raise
-- can never happen, whatever a translated template does with the argument.
local function wholeCount(n)
    return math.floor(tonumber(n) or 0)
end

-- Every entry goes through labelOf, which also covers a RECORDED list (a
-- rollback snapshot's cost) stripped to id+count: with no naming fields left it
-- localizes off the id and prints the raw id when even that fails - a far
-- better line than the "nil" a bare %s would have printed.
function Costs.describe(costList)
    local parts = {}
    for _, c in ipairs(costList) do
        table.insert(parts, I18n.msg("costEntry", wholeCount(c.count), Costs.labelOf(c)))
    end
    return table.concat(parts, ", ")
end

function Costs.describeMissing(missing)
    local parts = {}
    for _, m in ipairs(missing) do
        table.insert(parts, I18n.msg("costEntryMissing",
            wholeCount(m.count), Costs.labelOf(m), wholeCount(m.have)))
    end
    return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------- transaction

-- Consumes the cost list item by item, each checked via the count
-- difference; a partial failure
-- refunds everything already taken (reverse order) and yields nil.
-- txn:refund(reason) is idempotent; txn:commit() makes it a no-op.
function Costs.beginTransaction(playerCtx, costList)
    local consumed = {}
    for _, c in ipairs(costList) do
        if tryConsumeItems(playerCtx, c.id, c.count) then
            table.insert(consumed, c)
        else
            for i = #consumed, 1, -1 do
                giveItems(playerCtx, consumed[i].id, consumed[i].count)
            end
            return nil, c
        end
    end
    local txn = { done = false }
    function txn.commit()
        txn.done = true
    end
    function txn.refund(reason)
        if txn.done then return end
        txn.done = true
        local allOk = true
        for i = #consumed, 1, -1 do
            if not giveItems(playerCtx, consumed[i].id, consumed[i].count) then allOk = false end
        end
        if #consumed > 0 then
            if allOk then
                Log("Cost refunded (" .. reason .. ")")
            else
                Log("Cost refund PARTIALLY FAILED (" .. reason .. ") - please report")
            end
        end
    end
    return txn
end

return Costs
