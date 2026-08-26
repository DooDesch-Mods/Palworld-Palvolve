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
local I18n = require("i18n")

local Costs = {}

-- Display name of a cost entry, resolved at the moment a message is built and
-- never stored: the resolved list is cached, and the game's text system is not
-- answering yet while the world loads, so a name baked in at resolve time could
-- be a permanent fallback. An explicit label from a per-pair `materials` entry
-- wins; otherwise the game's own localized item name, with the configured
-- English name as the last resort for the mod's own stones.
function Costs.labelOf(entry)
    if not entry then return "?" end
    if entry.label then return entry.label end
    local base, resolved = I18n.itemName(entry.id, entry.fallbackLabel)
    -- The element is only appended to the generic fallback name. Every
    -- per-element stone is registered with its element already in the name, so
    -- decorating a resolved name would repeat it.
    if entry.element and not resolved then
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
    local ok, err = pcall(function()
        local pc = playerCtx and playerCtx.pc
        if pc and pc:IsValid() then
            inv = pc:GetPalPlayerState():GetInventoryData()
        end
    end)
    if not ok then
        Log("[ERROR] inventory lookup failed for the requesting player: " .. tostring(err))
        return nil
    end
    if inv and inv:IsValid() then return inv end
    Log("[ERROR] inventory lookup returned no valid inventory for the requesting player")
    return nil
end

function Costs.countItem(playerCtx, staticItemId)
    local inv = inventoryDataFor(playerCtx)
    if not inv then
        Log(string.format("[ERROR] count not attempted for %s: inventory unavailable",
            tostring(staticItemId)))
        return 0
    end
    local ok, n = pcall(function()
        return inv:CountItemNum(FName(staticItemId))
    end)
    if not ok then
        Log(string.format("[ERROR] count failed for %s: %s",
            tostring(staticItemId), tostring(n)))
        return 0
    end
    if type(n) ~= "number" then
        Log(string.format("[ERROR] count failed for %s: engine returned %s",
            tostring(staticItemId), type(n)))
        return 0
    end
    return n
end

-- Consumes `need` items; success is determined from the count difference
-- (RequestConsumeInventoryItem is the only BP-exposed consume path).
local function tryConsumeItems(playerCtx, staticItemId, need)
    need = tonumber(need)
    if not need or need < 1 or need % 1 ~= 0 then
        Log(string.format("[ERROR] consume not attempted for %s: invalid count %s",
            tostring(staticItemId), tostring(need)))
        return false, 0
    end
    local inv = inventoryDataFor(playerCtx)
    if not inv then
        Log(string.format("[ERROR] consume not attempted for %s x%d: inventory unavailable",
            tostring(staticItemId), need))
        return false, 0
    end
    local okBefore, before = pcall(function()
        local id = FName(staticItemId)
        return inv:CountItemNum(id)
    end)
    if not okBefore or type(before) ~= "number" then
        Log(string.format("[ERROR] pre-consume count failed for %s x%d: %s",
            tostring(staticItemId), need, tostring(before)))
        return false, 0
    end
    if before < need then
        Log(string.format("[INFO] consume skipped for %s x%d: only %d available",
            tostring(staticItemId), need, before))
        return false, 0
    end
    local cdo = StaticFindObject("/Script/Pal.Default__PalIncidentBase")
    if not (cdo and cdo:IsValid()) then
        Log(string.format("[ERROR] consume not attempted for %s x%d: PalIncidentBase unavailable",
            tostring(staticItemId), need))
        return false, 0
    end
    local okConsume, consumeErr = pcall(function()
        cdo:RequestConsumeInventoryItem(inv, FName(staticItemId), need)
    end)
    if not okConsume then
        Log(string.format("[ERROR] consume call failed for %s x%d: %s",
            tostring(staticItemId), need, tostring(consumeErr)))
        return false, 0
    end
    local okAfter, after = pcall(function()
        return inv:CountItemNum(FName(staticItemId))
    end)
    if not okAfter or type(after) ~= "number" then
        Log(string.format("[ERROR] post-consume count failed for %s x%d: %s; inventory state is unknown",
            tostring(staticItemId), need, tostring(after)))
        return false, nil
    end
    local taken = before - after
    if taken ~= need then
        Log(string.format("[ERROR] consume verification failed for %s x%d: count changed from %d to %d",
            tostring(staticItemId), need, before, after))
        return false, math.min(need, math.max(0, taken))
    end
    Log(string.format("[INFO] consumed %s x%d for the requesting player",
        tostring(staticItemId), need))
    return true, need
end

-- Deletes `count` items from the player's inventory for real. The in-game
-- discard only DROPS items to the ground, where they persist in the save -
-- this is the only true removal path exposed to Lua.
function Costs.removeAll(playerCtx, staticItemId, count)
    local ok = tryConsumeItems(playerCtx, staticItemId, count)
    return ok
end

local function giveItems(playerCtx, staticItemId, count)
    local inv = inventoryDataFor(playerCtx)
    if not inv then
        Log(string.format("[ERROR] give not attempted for %s x%s: inventory unavailable",
            tostring(staticItemId), tostring(count)))
        return false
    end
    local ok, res = pcall(function()
        return inv:AddItem_ServerInternal(FName(staticItemId), count, false, 0.0, true)
    end)
    if not ok then
        Log(string.format("[ERROR] give call failed for %s x%s: %s",
            tostring(staticItemId), tostring(count), tostring(res)))
        return false
    end
    if res ~= 0 then
        Log(string.format("[ERROR] give failed for %s x%s: engine result %s",
            tostring(staticItemId), tostring(count), tostring(res)))
        return false
    end
    Log(string.format("[INFO] gave %s x%s to the requesting player",
        tostring(staticItemId), tostring(count)))
    return true
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

-- The first key is the pair table itself. Two authored variants may share the
-- same from/to ids while carrying different material overrides, so a textual
-- species key would let whichever variant resolves first price both of them.
local resolveCache = setmetatable({}, { __mode = "k" })

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
    resolveCache = setmetatable({}, { __mode = "k" })
end

-- Full price of a pair at a level. Returns costList, err.
-- costList entries: { id, count, label }
function Costs.resolve(pair, level, worldCtx)
    -- the level is part of the key: drop tables have level bands, so the
    -- same pair can price differently at different levels
    local levelKey = tonumber(level) or 0
    local pairCache = resolveCache[pair]
    if pairCache and pairCache[levelKey] then return pairCache[levelKey] end

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
                element = element, fallbackLabel = Config.stoneNames.adaptation,
            })
        else
            table.insert(list, {
                id = Config.stoneItemIds.evolution, count = Config.stoneCount,
                fallbackLabel = Config.stoneNames.evolution,
            })
        end
    end
    if Config.costs.enabled then
        -- adaptation prices from the TARGET form, evolutions from the BASE
        local matSource = (pair.stone == "adaptation") and pair.to or pair.from
        local mats = pair.materials or materialsFor(matSource, level, worldCtx)
        for _, m in ipairs(mats) do
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
    if not pairCache then
        pairCache = {}
        resolveCache[pair] = pairCache
    end
    pairCache[levelKey] = merged
    return merged
end

-- Gives a recorded cost back, used when a finished evolution is rolled back.
-- Separate from the transaction refund, which only ever undoes a consume that
-- has not been committed yet: by the time a rollback happens the transaction is
-- long closed, so the list travels in the snapshot instead.
-- Returns true when every entry landed.
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

-- Returns ok, missing[] where missing entries keep the naming fields so the
-- description can resolve the item name when the message is actually built
function Costs.check(playerCtx, costList)
    local missing = {}
    for _, c in ipairs(costList) do
        local have = Costs.countItem(playerCtx, c.id)
        if have < c.count then
            table.insert(missing, { id = c.id, label = c.label, element = c.element,
                                    fallbackLabel = c.fallbackLabel, count = c.count, have = have })
        end
    end
    return #missing == 0, missing
end

function Costs.describe(costList)
    local parts = {}
    for _, c in ipairs(costList) do
        table.insert(parts, I18n.msg("costEntry", c.count, Costs.labelOf(c)))
    end
    return table.concat(parts, ", ")
end

function Costs.describeMissing(missing)
    local parts = {}
    for _, m in ipairs(missing) do
        table.insert(parts, I18n.msg("costEntryMissing", m.count, Costs.labelOf(m), m.have))
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
        local consumedOk, taken = tryConsumeItems(playerCtx, c.id, c.count)
        if consumedOk then
            table.insert(consumed, c)
        else
            if type(taken) == "number" and taken > 0 then
                table.insert(consumed, { id = c.id, count = taken })
                Log(string.format("[WARN] partial consume recorded for refund: %s x%d",
                    tostring(c.id), taken))
            elseif taken == nil then
                Log(string.format("[ERROR] consume state is unknown for %s x%s; refund can only cover verified deductions",
                    tostring(c.id), tostring(c.count)))
            end
            local refunded = true
            for i = #consumed, 1, -1 do
                if not giveItems(playerCtx, consumed[i].id, consumed[i].count) then
                    refunded = false
                end
            end
            if refunded then
                Log(string.format("[INFO] partial cost consumption rolled back after %s x%s failed",
                    tostring(c.id), tostring(c.count)))
            else
                Log(string.format("[ERROR] partial cost refund failed after %s x%s could not be consumed; items may be missing",
                    tostring(c.id), tostring(c.count)))
            end
            return nil, c, refunded
        end
    end
    local txn = { done = false }
    function txn.commit()
        txn.done = true
        Log(string.format("[INFO] cost transaction committed with %d item entr%s",
            #consumed, #consumed == 1 and "y" or "ies"))
    end
    function txn.refund(reason)
        if txn.done then
            Log("[INFO] cost refund skipped because the transaction is already closed")
            return
        end
        txn.done = true
        local allOk = true
        for i = #consumed, 1, -1 do
            if not giveItems(playerCtx, consumed[i].id, consumed[i].count) then allOk = false end
        end
        if #consumed > 0 then
            if allOk then
                Log("[INFO] cost refunded (" .. tostring(reason) .. ")")
            else
                Log("[ERROR] cost refund PARTIALLY FAILED (" .. tostring(reason)
                    .. ") - items may be missing; please report")
            end
        end
    end
    return txn
end

return Costs
