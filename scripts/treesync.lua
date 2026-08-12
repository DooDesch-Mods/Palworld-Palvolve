-- treesync.lua: the server's evolution tree, handed to every client that joins.
--
-- Why this exists: the host decides what an evolution does, but the client
-- draws it and, worse, the client picks an option by INDEX. Both sides reading
-- their own config meant a player with a different file saw a wrong tree and
-- could send an index that means something else on the host. Handing the file
-- to every player by hand was the only remedy, and it did not scale.
--
-- Measured before it was designed (docs/Palvolve/SERVER-COMPAT.md):
-- SendScreenLogToClient carries 65535 bytes in ONE message, intact, checksum
-- and tail verified, and twenty of 8 KB back to back at 50 ms cost nothing.
-- 131072 bytes kill the server process. So: one message, no chunking, and a
-- hard cap far below the fatal size.
--
-- The wire is text, not binary: the ids and conditions are already strings, a
-- text frame survives a log round trip, and at this size the saving from a
-- binary packing would buy nothing that the margin does not already give.
local Config = require("config")

local TreeSync = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- The prefix the client watches for. PVLV1 stays what it was, so an older
-- client ignores this and keeps working with its own file.
TreeSync.PREFIX = "PVLV2|tree|"

-- Refuses to send anything near the size that kills the process. 32 KB is half
-- of what was proven to arrive whole, and about three times what the largest
-- published tree needs.
local MAX_PAYLOAD = 32 * 1024

-- Field and record separators that cannot appear in an id, a category, a stone
-- name or a condition: those are all [A-Za-z0-9_:.-].
local FS, RS, CS = "|", "\n", ";"

--- FNV-1a over the exact payload. Not Config.treeHash: that one sorts before
--- hashing, so two trees whose pairs are in a different ORDER hash the same -
--- and the order is exactly what the option index depends on.
local function hashOf(s)
    -- Hex literals and a split multiply, the same shape Config.treeHash uses
    -- and for the same reason: a decimal constant past 2^31 can arrive as a
    -- float where numbers are doubles, and a float cannot be xored. The plain
    -- form works on this build and throws on another, and it would throw inside
    -- the pcall that wraps the send - a silent no-sync rather than an error.
    local PRIME = 0x01000193
    local h = 0x811C9DC5
    for i = 1, #s do
        h = h ~ s:byte(i)
        local lo = ((h & 0xFFFF) * PRIME) & 0xFFFFFFFF
        local hi = ((((h >> 16) & 0xFFFF) * PRIME) & 0xFFFF) << 16
        h = (lo + hi) & 0xFFFFFFFF
    end
    return string.format("%08x", h)
end

-- The words that repeat on every line get one character each; anything else
-- travels verbatim, so a config with a category we have never seen still
-- arrives intact rather than being silently rewritten.
local CAT_CODE = { evolution = "e", adaptation = "a", funchain = "f" }
local CAT_WORD = { e = "evolution", a = "adaptation", f = "funchain" }
local STONE_CODE = { evolution = "e", adaptation = "a" }
local STONE_WORD = { e = "evolution", a = "adaptation" }

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function b36(n)
    if n == 0 then return "0" end
    local out = {}
    while n > 0 do
        local d = n % 36
        out[#out + 1] = B36:sub(d + 1, d + 1)
        n = (n - d) / 36
    end
    return string.reverse(table.concat(out))
end

local function unb36(s36)
    local n = 0
    for i = 1, #s36 do
        local c = s36:sub(i, i)
        local d = B36:find(c, 1, true)
        if not d then return nil end
        n = n * 36 + (d - 1)
    end
    return n
end

-- Everything besides the pairs that decides what an evolution asks for. A tree
-- alone is not the server's rules: the same pair costs different materials
-- under a different cost model, and a client showing its own numbers is a
-- client telling the player something the host will not honour.
--
-- Scalars only, and named one by one rather than copied wholesale: this comes
-- off the wire, and a blanket merge would let a server set anything at all in
-- the client's config.
local GLOBALS = {
    { key = "requireStone", kind = "bool" },
    { key = "techLevelCap", kind = "number" },
    { key = "costs.enabled", kind = "bool" },
    { key = "costs.slots", kind = "number" },
    { key = "costs.minRate", kind = "number" },
    { key = "costs.countScale", kind = "number" },
    { key = "costs.maxCount", kind = "number" },
    { key = "stoneCount", kind = "number" },
    { key = "eggFilter.enabled", kind = "bool" },
    { key = "chatMessages", kind = "enum", values = { all = true, replies = true, off = true } },
}

local function readPath(root, path)
    local cur = root
    for part in path:gmatch("[^.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[part]
    end
    return cur
end

local function writePath(root, path, value)
    local parts = {}
    for part in path:gmatch("[^.]+") do parts[#parts + 1] = part end
    local cur = root
    for i = 1, #parts - 1 do
        if type(cur[parts[i]]) ~= "table" then cur[parts[i]] = {} end
        cur = cur[parts[i]]
    end
    cur[parts[#parts]] = value
end

local function encodeGlobals()
    local out = {}
    for _, g in ipairs(GLOBALS) do
        local v = readPath(Config, g.key)
        if v ~= nil then
            if g.kind == "bool" then
                out[#out + 1] = g.key .. "=" .. (v and "1" or "0")
            elseif g.kind == "enum" then
                if g.values[tostring(v)] then out[#out + 1] = g.key .. "=" .. tostring(v) end
            elseif type(tonumber(v)) == "number" then
                out[#out + 1] = g.key .. "=" .. tostring(tonumber(v))
            end
        end
    end
    return table.concat(out, ",")
end

-- The dictionary line joins the ids with a comma and the decoder splits it on
-- the same character, so an id that is empty or carries a comma or a line break
-- comes back as a different number of entries than went in - and every id after
-- it then resolves to the wrong species. Such an id matches no pal on the host
-- either, so dropping the pair costs nothing and keeps the two lists aligned.
local function idSafe(s)
    return type(s) == "string" and s ~= "" and not s:find("[,\r\n]")
end

--- Every enabled pair, in the order the host reads them, because the option
--- index a client sends is a position in this list.
---
--- The species ids carry the weight: 613 pairs name 279 distinct Pals, and
--- spelled out on every line they were two thirds of the frame. Listed once and
--- referenced by number, the largest published tree drops from 31 KB to about
--- 12 KB, which puts it back at a comfortable distance from the size that is
--- known to kill a server.
function TreeSync.encode(map)
    local dict, dictIndex = {}, {}
    local function idOf(name)
        local at = dictIndex[name]
        if at then return at end
        dict[#dict + 1] = name
        dictIndex[name] = #dict - 1
        return #dict - 1
    end

    local out = {}
    for _, p in ipairs(map or {}) do
        if p.enabled and idSafe(p.from) and idSafe(p.to) then
            local conds = ""
            if type(p.conditions) == "table" and #p.conditions > 0 then
                conds = table.concat(p.conditions, CS)
            end
            out[#out + 1] = table.concat({
                b36(idOf(p.from)), b36(idOf(p.to)),
                CAT_CODE[p.category or "evolution"] or (p.category or "evolution"),
                tostring(tonumber(p.minLevel) or 1),
                STONE_CODE[p.stone or "evolution"] or (p.stone or "evolution"),
                conds,
            }, FS)
        end
    end
    local body = encodeGlobals() .. RS .. table.concat(dict, ",") .. RS .. table.concat(out, RS)
    return body, hashOf(body), #out
end

--- Turns a received body back into pairs. Everything that does not look like a
--- pair is dropped rather than guessed at: this data comes off the wire, and a
--- half-understood record would be a wrong tree presented as the server's.
function TreeSync.decode(body)
    body = tostring(body or "")
    -- line 1: globals, line 2: the id dictionary, the rest: one pair per line
    local firstBreak = body:find(RS, 1, true)
    if not firstBreak then return {}, {} end
    local secondBreak = body:find(RS, firstBreak + 1, true)
    if not secondBreak then return {}, {} end

    local globals = {}
    local spec = {}
    for _, g in ipairs(GLOBALS) do spec[g.key] = g end
    for entry in body:sub(1, firstBreak - 1):gmatch("[^,]+") do
        local key, value = entry:match("^([%w.]+)=(.+)$")
        local g = key and spec[key]
        if g and g.kind == "bool" then
            globals[key] = (value == "1")
        elseif g and g.kind == "number" and tonumber(value) then
            globals[key] = tonumber(value)
        elseif g and g.kind == "enum" and g.values[value] then
            globals[key] = value
        end
    end

    local dict = {}
    for name in body:sub(firstBreak + 1, secondBreak - 1):gmatch("[^,]+") do
        dict[#dict + 1] = name
    end

    local pairsOut = {}
    for line in body:sub(secondBreak + 1):gmatch("[^" .. RS .. "]+") do
        local from, to, cat, lvl, stone, conds =
            line:match("^([^|]+)|([^|]+)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        local fi, ti = from and unb36(from), to and unb36(to)
        local fromId = fi and dict[fi + 1]
        local toId = ti and dict[ti + 1]
        if fromId and toId then
            local p = {
                from = fromId,
                to = toId,
                category = CAT_WORD[cat] or (cat ~= "" and cat) or "evolution",
                minLevel = tonumber(lvl) or 1,
                stone = STONE_WORD[stone] or (stone ~= "" and stone) or "evolution",
                enabled = true,
            }
            if conds and conds ~= "" then
                local list = {}
                for c in conds:gmatch("[^;]+") do list[#list + 1] = c end
                if #list > 0 then p.conditions = list end
            end
            pairsOut[#pairsOut + 1] = p
        end
    end
    return pairsOut, globals
end

-- ------------------------------------------------------------------- host

--- Sends the tree to one joined client. One message, size checked first: a
--- payload over the cap is a bug worth a line in the log, never a send.
function TreeSync.sendTo(playerCtx)
    if not playerCtx or playerCtx.isLocal then return false end
    if not (playerCtx.pc and playerCtx.pc:IsValid()) then return false end
    local body, hash, count = TreeSync.encode(Config.map)
    local frame = TreeSync.PREFIX .. hash .. "|" .. count .. "|" .. body
    if #frame > MAX_PAYLOAD then
        Log(string.format("tree sync NOT sent: %d pairs are %d bytes, over the %d byte cap",
            count, #frame, MAX_PAYLOAD))
        return false
    end
    local ok = pcall(function()
        playerCtx.pc:SendScreenLogToClient(frame,
            { R = 0.2, G = 1.0, B = 0.4, A = 1.0 }, 0.1, FName("PalvolveTree"))
    end)
    if ok then
        Log(string.format("tree sync sent: %d pairs, %d bytes, %s", count, #frame, hash))
    else
        Log("tree sync failed to send")
    end
    return ok
end

-- ----------------------------------------------------------------- client

-- What the client had before a server tree replaced it, so leaving the server
-- does not leave the player's own tree overwritten for the rest of the session.
local localMap = nil
local localGlobals = nil
local activeHash = nil

--- True while this client is drawing a tree that came from a server.
function TreeSync.isActive()
    return activeHash ~= nil
end

function TreeSync.activeHash()
    return activeHash
end

--- Drops what the tree feeds: both modules cache derived lists, and a swapped
--- map that leaves those standing shows the old tree with the new rules.
local function invalidateViews()
    -- The config's own derived tables first: the spelling map and the egg
    -- filter's parent lists are built once from the pair map, so leaving them
    -- standing means the old tree still answers those two questions.
    pcall(function()
        if Config.invalidateDerived then Config.invalidateDerived() end
    end)
    -- Prices are cached per pair and level, so a changed cost model that leaves
    -- them standing keeps quoting the old numbers.
    pcall(function()
        local okCosts, costs = pcall(require, "costs")
        if okCosts and costs and costs.clearCache then costs.clearCache() end
    end)
    pcall(function()
        local ok, view = pcall(require, "treeview")
        if ok and view and view.invalidate then view.invalidate() end
    end)
    pcall(function()
        local ok, html = pcall(require, "treehtml")
        if ok and html and html.invalidate then html.invalidate() end
    end)
    -- The Palpedia page keeps the last built page next to the Pal it was built
    -- for, and reuses it whenever those two still agree - so dropping the html
    -- module's cache alone leaves the Pal the player looked at last showing the
    -- old tree. Reached through package.loaded rather than require: this module
    -- also loads on a dedicated server, which must never pull in a UI module.
    pcall(function()
        local tree = package.loaded["paldextree"]
        if tree and tree.invalidate then tree.invalidate() end
    end)
end

--- Applies a received tree. Returns false when nothing usable came out of it,
--- in which case the client keeps its own file rather than showing an empty
--- tree that claims to be the server's.
function TreeSync.applyFrame(frame)
    local hash, count, body = frame:match("^" .. TreeSync.PREFIX:gsub("|", "%%|")
        .. "(%x+)|(%d+)|(.*)$")
    if not (hash and body) then return false end
    if activeHash == hash then return true end
    local received, globals = TreeSync.decode(body)
    -- An empty tree is a decision a host is allowed to make ("nothing evolves
    -- here"), and it only counts as damage when the frame says otherwise. The
    -- count travels with it precisely so the two can be told apart.
    if #received == 0 and tonumber(count) ~= 0 then
        Log("server tree arrived empty, keeping the local one")
        return false
    end
    if tonumber(count) and #received ~= tonumber(count) then
        Log(string.format("server tree incomplete: %d of %s pairs, keeping the local one",
            #received, count))
        return false
    end
    if localMap == nil then
        localMap = Config.map
        localGlobals = {}
        for _, g in ipairs(GLOBALS) do localGlobals[g.key] = readPath(Config, g.key) end
    end
    Config.map = received
    -- The rules the pairs are read under travel with them. Without these the
    -- client shows its own material costs and its own stone requirement for a
    -- tree the host prices differently, which reads as the mod contradicting
    -- itself the moment a player compares.
    local applied = 0
    for key, value in pairs(globals or {}) do
        writePath(Config, key, value)
        applied = applied + 1
    end
    -- Role holds the chat mode as its own field, because config requires role
    -- and cannot be required back. A setting that only lands in Config is a
    -- setting the chat gate never sees.
    pcall(function()
        local okRole, Role = pcall(require, "role")
        if okRole and Role then Role.chatMode = Config.chatMessages end
    end)
    activeHash = hash
    invalidateViews()
    Log(string.format("server tree active: %d pairs, %d settings, %s",
        #received, applied, hash))
    return true
end

--- Back to the player's own tree, for when this client leaves the server.
function TreeSync.restoreLocal()
    if localMap == nil then return end
    Config.map = localMap
    for key, value in pairs(localGlobals or {}) do
        if value ~= nil then writePath(Config, key, value) end
    end
    localMap, localGlobals, activeHash = nil, nil, nil
    pcall(function()
        local okRole, Role = pcall(require, "role")
        if okRole and Role then Role.chatMode = Config.chatMessages end
    end)
    invalidateViews()
    Log("back to the local tree")
end

return TreeSync
