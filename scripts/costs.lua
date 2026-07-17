-- Palvolve costs: resolves the full price of an evolution (stone + materials
-- derived from drop tables) and runs the multi-item consume/refund
-- transaction. Owns all inventory access.
--
-- Pricing rules:
--   evolution/funchain: evolution stone + materials from the BASE pal's drops
--   adaptation:         per-element adaptation stone + materials from the
--                       TARGET form's drops
-- Materials come from the runtime drop database when its out-param
-- marshaling works, otherwise from the baked drops_static.lua.
-- Per-pair `materials` in the config override the derivation entirely.

local Config = require("config")
local Elements = require("elements")

local Costs = {}

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
-- costList entries: { id, count, label }
function Costs.resolve(pair, level, worldCtx)
    -- the level is part of the key: drop tables have level bands, so the
    -- same pair can price differently at different levels
    local cacheKey = pair.from .. ">" .. pair.to .. ":" .. tostring(level or 0)
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
            table.insert(list, {
                id = stoneId, count = Config.stoneCount,
                label = element and string.format("%s (%s)", Config.stoneNames.adaptation, element)
                    or Config.stoneNames.adaptation,
            })
        else
            table.insert(list, {
                id = Config.stoneItemIds.evolution, count = Config.stoneCount,
                label = Config.stoneNames.evolution,
            })
        end
    end
    if Config.costs.enabled then
        -- adaptation prices from the TARGET form, evolutions from the BASE
        local matSource = (pair.stone == "adaptation") and pair.to or pair.from
        local mats = pair.materials or materialsFor(matSource, level, worldCtx)
        for _, m in ipairs(mats) do
            table.insert(list, { id = m.id, count = m.count, label = m.label or m.id })
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
            local entry = { id = c.id, count = c.count, label = c.label }
            byId[c.id] = entry
            table.insert(merged, entry)
        end
    end
    resolveCache[cacheKey] = merged
    return merged
end

-- Returns ok, missing[] where missing entries carry {label, count, have}
function Costs.check(playerCtx, costList)
    local missing = {}
    for _, c in ipairs(costList) do
        local have = Costs.countItem(playerCtx, c.id)
        if have < c.count then
            table.insert(missing, { label = c.label, count = c.count, have = have })
        end
    end
    return #missing == 0, missing
end

function Costs.describe(costList)
    local parts = {}
    for _, c in ipairs(costList) do
        table.insert(parts, string.format("%dx %s", c.count, c.label))
    end
    return table.concat(parts, ", ")
end

function Costs.describeMissing(missing)
    local parts = {}
    for _, m in ipairs(missing) do
        table.insert(parts, string.format("%dx %s (have %d)", m.count, m.label, m.have))
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
