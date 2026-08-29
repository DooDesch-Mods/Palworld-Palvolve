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

-- The v2 frame remains byte-compatible for older clients. The v3 frame is the
-- authoritative 1.9 tree and carries the fields that affect pair selection and
-- pricing but could not be represented by v2.
TreeSync.PREFIX_V2 = "PVLV2|tree|"
TreeSync.PREFIX_V3 = "PVLV3|tree|"
TreeSync.PREFIX = TreeSync.PREFIX_V3

-- Refuses to send anything near the size that kills the process. 32 KB is half
-- of what was proven to arrive whole, and about three times what the largest
-- published tree needs.
local MAX_PAYLOAD = 32 * 1024
TreeSync.MAX_PAYLOAD = MAX_PAYLOAD

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
    -- form works on this build and throws on another, which makes the frame fail
    -- before it can be issued.
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
local CAT_CODE = { evolution = "e", adaptation = "a", funchain = "f", prestige = "p" }
local CAT_WORD = { e = "evolution", a = "adaptation", f = "funchain", p = "prestige" }
local STONE_CODE = { evolution = "e", adaptation = "a", prestige = "p" }
local STONE_WORD = { e = "evolution", a = "adaptation", p = "prestige" }

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
    { key = "autoEvolve", kind = "bool", since = 3 },

    -- Both decide WHICH prestige connections exist at all, and host and client
    -- derive that list separately from the same rule. A client left on its own
    -- values would draw targets the host refuses, so these travel with the tree.
    { key = "prestigeMinEvolutions", kind = "number", since = 3 },
    { key = "prestigeMinLevel", kind = "number", since = 3 },
    -- Same reason, one step earlier: these two decide whether the list exists
    -- at all. A client left on its own values would derive its 174 connections
    -- against a host that has prestige switched off, and put a wheel entry in
    -- front of the player for a request the host then refuses.
    { key = "prestigeEnabled", kind = "bool", since = 3 },
    { key = "prestigeAutoLink", kind = "bool", since = 3 },
    -- The price of a prestige, for the same reason stoneCount travels: a client
    -- that quotes a different number than the host charges is the one thing a
    -- cost display must never do.
    { key = "prestigeStoneCount", kind = "number", since = 3 },

    -- How the transformation looks, so a server decides what its players see
    -- rather than each of them running their own cut. These are read per
    -- evolution (finale.lua finaleCfg/timings, fx.lua digimonCfg,
    -- evolution.lua performEvolution), so a value that arrives with the tree
    -- applies from the next evolution without anything being reloaded.
    --
    -- What deliberately does NOT travel: the confirm key and its timings,
    -- because a server has no business over someone's keyboard; the effect
    -- budget, because it exists for the machine the frames are drawn on; the
    -- close button; and the diagnostics.
    { key = "digimon.spinUpMs", kind = "number" },
    { key = "digimon.shrinkMs", kind = "number" },
    { key = "digimon.growMs", kind = "number" },
    { key = "digimon.finaleHoldMs", kind = "number" },
    { key = "digimon.peakDegPerSec", kind = "number" },
    { key = "digimon.elementColors", kind = "bool" },
    { key = "finale.style", kind = "enum", values = { layered = true, legacy = true } },
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

local function encodeGlobals(version)
    local out = {}
    for _, g in ipairs(GLOBALS) do
        local v = (not g.since or version >= g.since) and readPath(Config, g.key) or nil
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
-- V3 pair tail: |<auto:0/1>|<materials>. Material item ids share the species
-- dictionary and travel as <base36-index>:<decimal-count> joined by semicolons.
-- "-" preserves an absent override; "0" preserves an explicitly empty one.
local function materialsWire(pair, idOf)
    if pair.materials == nil then return "-" end
    if type(pair.materials) ~= "table" then
        return nil, "materials is not a table"
    end
    if #pair.materials == 0 then return "0" end

    local out = {}
    for _, material in ipairs(pair.materials) do
        local count = type(material) == "table" and tonumber(material.count) or nil
        local itemId = type(material) == "table" and material.id or nil
        if not idSafe(itemId) or not count or count < 1 or count % 1 ~= 0 then
            return nil, "materials contains an invalid item or count"
        end
        out[#out + 1] = b36(idOf(itemId)) .. ":" .. tostring(count)
    end
    return table.concat(out, CS)
end

--- Encodes one protocol version. V2 is a projection: prestige pairs and the v3
--- pair fields are deliberately absent so an older client cannot mistake a
--- prestige path for an ordinary evolution.
function TreeSync.encode(map, version)
    version = tonumber(version) or 3
    if version ~= 2 and version ~= 3 then return nil, nil, nil, "unknown tree version" end
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
        local legacySafe = version ~= 2 or p.category ~= "prestige"
        if p.enabled and legacySafe and idSafe(p.from) and idSafe(p.to) then
            local conds = ""
            if type(p.conditions) == "table" and #p.conditions > 0 then
                conds = table.concat(p.conditions, CS)
            end
            local fields = {
                b36(idOf(p.from)), b36(idOf(p.to)),
                CAT_CODE[p.category or "evolution"] or (p.category or "evolution"),
                tostring(tonumber(p.minLevel) or 1),
                STONE_CODE[p.stone or "evolution"] or (p.stone or "evolution"),
                conds,
            }
            if version == 3 then
                local materials, materialErr = materialsWire(p, idOf)
                if not materials then
                    return nil, nil, nil, string.format("%s>%s: %s",
                        tostring(p.from), tostring(p.to), materialErr)
                end
                fields[#fields + 1] = p.autoEvolve == true and "1" or "0"
                fields[#fields + 1] = materials
            end
            out[#out + 1] = table.concat(fields, FS)
        end
    end
    local body = encodeGlobals(version) .. RS .. table.concat(dict, ",") .. RS .. table.concat(out, RS)
    return body, hashOf(body), #out
end

--- Turns a received body back into pairs. Everything that does not look like a
--- pair is dropped rather than guessed at: this data comes off the wire, and a
--- half-understood record would be a wrong tree presented as the server's.
function TreeSync.decode(body, version)
    version = tonumber(version) or 3
    if version ~= 2 and version ~= 3 then return {}, {} end
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
        local from, to, cat, lvl, stone, conds, auto, materials
        if version == 3 then
            from, to, cat, lvl, stone, conds, auto, materials =
                line:match("^([^|]+)|([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        else
            from, to, cat, lvl, stone, conds =
                line:match("^([^|]+)|([^|]+)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        end
        local fi, ti = from and unb36(from), to and unb36(to)
        local fromId = fi and dict[fi + 1]
        local toId = ti and dict[ti + 1]
        local valid = fromId ~= nil and toId ~= nil
        if version == 3 and auto ~= "0" and auto ~= "1" then valid = false end
        if valid then
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
            if version == 3 then
                p.autoEvolve = auto == "1"
                if materials == "0" then
                    p.materials = {}
                elseif materials ~= "-" then
                    local list = {}
                    if not materials or materials == "" then
                        valid = false
                    else
                        for entry in materials:gmatch("[^;]+") do
                            local itemAt, countText = entry:match("^([0-9a-z]+):(%d+)$")
                            local itemIndex = itemAt and unb36(itemAt) or nil
                            local itemId = itemIndex and dict[itemIndex + 1] or nil
                            local count = tonumber(countText)
                            if not itemId or not count or count < 1 or count % 1 ~= 0 then
                                valid = false
                                break
                            end
                            list[#list + 1] = { id = itemId, count = count }
                        end
                    end
                    if valid then p.materials = list end
                end
            end
            if valid then pairsOut[#pairsOut + 1] = p end
        end
    end
    return pairsOut, globals
end

-- ------------------------------------------------------------------- host

local function sendVersion(playerCtx, version, prefix)
    local encoded, body, hash, count, encodeErr = pcall(TreeSync.encode, Config.map, version)
    if not encoded then
        Log(string.format("[ERROR] v%d tree sync encoding failed: %s", version, tostring(body)))
        return false
    end
    if not body then
        Log(string.format("[ERROR] v%d tree sync NOT issued: %s", version, tostring(encodeErr)))
        return false
    end
    local frame = prefix .. hash .. "|" .. count .. "|" .. body
    if #frame > MAX_PAYLOAD then
        Log(string.format("[ERROR] v%d tree sync NOT issued: %d pairs are %d bytes, over the %d byte cap",
            version, count, #frame, MAX_PAYLOAD))
        return false
    end
    local issued, issueErr = pcall(function()
        playerCtx.pc:SendScreenLogToClient(frame,
            { R = 0.2, G = 1.0, B = 0.4, A = 1.0 }, 0.1, FName("PalvolveTree"))
    end)
    if issued then
        Log(string.format("[INFO] v%d tree sync call issued: %d pairs, %d bytes, %s; delivery awaits the client",
            version, count, #frame, hash))
    else
        Log(string.format("[ERROR] v%d tree sync call failed: %s",
            version, tostring(issueErr)))
    end
    return issued
end

--- Issues both complete frames to one joined client. Each frame is checked on
--- its own because either one crossing the safety cap is enough to refuse that
--- call; the frames are never chunked or joined near the measured fatal size.
--- The engine exposes no delivery acknowledgement, so true means both calls
--- were issued without throwing, not that the client received either frame.
function TreeSync.sendTo(playerCtx)
    if not playerCtx then
        Log("[ERROR] tree sync not issued: no player context")
        return false
    end
    if playerCtx.isLocal then
        Log("[INFO] tree sync not issued to the local player: no network delivery is needed")
        return false
    end
    local okValid, pcValid = pcall(function()
        return playerCtx.pc ~= nil and playerCtx.pc:IsValid()
    end)
    if not okValid then
        Log("[ERROR] tree sync not issued: remote player validation failed: " .. tostring(pcValid))
        return false
    end
    if not pcValid then
        Log("[ERROR] tree sync not issued: remote player controller is invalid")
        return false
    end
    local legacyOk = sendVersion(playerCtx, 2, TreeSync.PREFIX_V2)
    local v3Ok = sendVersion(playerCtx, 3, TreeSync.PREFIX_V3)
    return legacyOk and v3Ok
end

-- ----------------------------------------------------------------- client

-- What the client had before a server tree replaced it, so leaving the server
-- does not leave the player's own tree overwritten for the rest of the session.
local localMap = nil
local localGlobals = nil
local activeHash = nil
local activeVersion = nil
local activeGeneration = nil
local connectionGeneration = 0
local lastFrameAt = nil

--- True while this client is drawing a tree that came from a server.
function TreeSync.isActive()
    return localMap ~= nil
end

function TreeSync.activeHash()
    return activeHash
end

function TreeSync.activeProtocol()
    return activeVersion
end

function TreeSync.hasV3ForGeneration(gen)
    return activeVersion == 3 and activeGeneration == (tonumber(gen) or -1)
end

--- Starts a new connection generation. A greet can beat the local world-entry
--- hook, so a frame received immediately before this call is carried forward;
--- an older borrowed tree loses its protocol preference and cannot suppress a
--- v2 frame from the next server.
function TreeSync.beginGeneration(gen)
    gen = math.floor(tonumber(gen) or 0)
    if gen == connectionGeneration then return end
    local carryEarly = lastFrameAt ~= nil
        and activeGeneration == connectionGeneration
        and (os.clock() - lastFrameAt) <= 2
    connectionGeneration = gen
    if carryEarly then
        activeGeneration = gen
    else
        activeHash = nil
        activeVersion = nil
        activeGeneration = nil
    end
end

--- Drops what the tree feeds: both modules cache derived lists, and a swapped
--- map that leaves those standing shows the old tree with the new rules.
local function invalidateViews()
    -- The config's own derived tables first: the spelling map and the egg
    -- filter's parent lists are built once from the pair map, so leaving them
    -- standing means the old tree still answers those two questions.
    local allOk = true
    local function invalidate(label, callback)
        local ok, err = pcall(callback)
        if not ok then
            allOk = false
            Log(string.format("[ERROR] server tree %s cache invalidation failed: %s",
                label, tostring(err)))
        else
            Log(string.format("[INFO] server tree %s cache invalidated", label))
        end
    end
    invalidate("config-derived", function()
        if not Config.invalidateDerived then error("invalidator unavailable") end
        Config.invalidateDerived()
    end)
    -- Prices are cached per pair and level, so a changed cost model that leaves
    -- them standing keeps quoting the old numbers.
    invalidate("cost", function()
        local costs = require("costs")
        if not (costs and costs.clearCache) then error("invalidator unavailable") end
        costs.clearCache()
    end)
    -- Prestige connections are memoized against the map table's identity plus
    -- the three settings that shape them. Applying a frame swaps the map for a
    -- different table, so today the memo breaks on its own - but that is a
    -- property of how a frame happens to be applied, not of this list. Naming it
    -- here means a later change to the apply path cannot silently leave a client
    -- deriving prestige against the settings it had before the host spoke.
    invalidate("prestige", function()
        local prestige = require("prestige")
        if not (prestige and prestige.invalidate) then error("invalidator unavailable") end
        prestige.invalidate()
    end)
    invalidate("tree view", function()
        local view = require("treeview")
        if not (view and view.invalidate) then error("invalidator unavailable") end
        view.invalidate()
    end)
    invalidate("tree HTML", function()
        local html = require("treehtml")
        if not (html and html.invalidate) then error("invalidator unavailable") end
        html.invalidate()
    end)
    -- The Palpedia page keeps the last built page next to the Pal it was built
    -- for, and reuses it whenever those two still agree - so dropping the html
    -- module's cache alone leaves the Pal the player looked at last showing the
    -- old tree. Reached through package.loaded rather than require: this module
    -- also loads on a dedicated server, which must never pull in a UI module.
    local tree = package.loaded["paldextree"]
    if not tree then
        Log("[INFO] server tree Palpedia cache was not loaded; no invalidation was needed")
    else
        invalidate("Palpedia", function()
            if not tree.invalidate then error("invalidator unavailable") end
            tree.invalidate()
        end)
    end
    return allOk
end

local function syncRoleChatMode()
    local ok, err = pcall(function()
        local Role = require("role")
        if not Role then error("role module unavailable") end
        Role.chatMode = Config.chatMessages
    end)
    if not ok then
        Log("[ERROR] server tree chat mode application failed: " .. tostring(err))
        return false
    end
    Log("[INFO] server tree chat mode applied")
    return true
end

--- Applies a received tree. Returns false when nothing usable came out of it,
--- in which case the client keeps its previous tree rather than showing an empty
--- tree that claims to be the server's.
function TreeSync.applyFrame(frame)
    frame = tostring(frame or "")
    if #frame > MAX_PAYLOAD then
        Log(string.format("[WARN] server tree rejected: %d bytes exceeds the %d byte cap",
            #frame, MAX_PAYLOAD))
        return false
    end
    local version, prefix = nil, nil
    if frame:sub(1, #TreeSync.PREFIX_V3) == TreeSync.PREFIX_V3 then
        version, prefix = 3, TreeSync.PREFIX_V3
    elseif frame:sub(1, #TreeSync.PREFIX_V2) == TreeSync.PREFIX_V2 then
        version, prefix = 2, TreeSync.PREFIX_V2
    else
        Log("[WARN] tree frame rejected: unknown protocol prefix")
        return false
    end
    local hash, count, body = frame:match("^" .. prefix:gsub("|", "%%|")
        .. "(%x+)|(%d+)|(.*)$")
    if not (hash and body) then
        Log(string.format("[WARN] server v%d tree rejected: malformed header", version))
        return false
    end
    if hashOf(body) ~= hash:lower() then
        Log(string.format("[WARN] server v%d tree checksum mismatch, keeping the current tree", version))
        return false
    end
    if version == 2 and activeVersion == 3 and activeGeneration == connectionGeneration then
        lastFrameAt = os.clock()
        Log("[INFO] server v2 tree ignored because v3 is already active for this connection")
        return true
    end
    if activeHash == hash and activeVersion == version
        and activeGeneration == connectionGeneration then
        Log(string.format("[INFO] duplicate server v%d tree already active: %s", version, hash))
        return true
    end
    local received, globals = TreeSync.decode(body, version)
    -- An empty tree is a decision a host is allowed to make ("nothing evolves
    -- here"), and it only counts as damage when the frame says otherwise. The
    -- count travels with it precisely so the two can be told apart.
    if #received == 0 and tonumber(count) ~= 0 then
        Log("[WARN] server tree arrived empty, keeping the local one")
        return false
    end
    if tonumber(count) and #received ~= tonumber(count) then
        Log(string.format("[WARN] server tree incomplete: %d of %s pairs, keeping the local one",
            #received, count))
        return false
    end
    local previousMap = Config.map
    local previousGlobals = {}
    for _, g in ipairs(GLOBALS) do previousGlobals[g.key] = readPath(Config, g.key) end
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
    local roleOk = syncRoleChatMode()
    local viewsOk = invalidateViews()
    if not (roleOk and viewsOk) then
        Config.map = previousMap
        for key, value in pairs(previousGlobals) do writePath(Config, key, value) end
        local roleRollbackOk = syncRoleChatMode()
        local viewsRollbackOk = invalidateViews()
        if roleRollbackOk and viewsRollbackOk then
            Log(string.format("[ERROR] server v%d tree activation failed; the previous tree was restored",
                version))
        else
            Log(string.format("[ERROR] server v%d tree activation failed and rollback was incomplete; restart the client",
                version))
        end
        return false
    end
    if localMap == nil then
        localMap = previousMap
        localGlobals = previousGlobals
    end
    activeHash = hash
    activeVersion = version
    activeGeneration = connectionGeneration
    lastFrameAt = os.clock()
    Log(string.format("[INFO] server v%d tree active: %d pairs, %d settings, %s",
        version, #received, applied, hash))
    return true
end

--- Back to the player's own tree, for when this client leaves the server.
function TreeSync.restoreLocal()
    if localMap == nil then
        Log("[INFO] local tree restore skipped: no server tree is active")
        return
    end
    Config.map = localMap
    for key, value in pairs(localGlobals or {}) do
        if value ~= nil then writePath(Config, key, value) end
    end
    localMap, localGlobals, activeHash = nil, nil, nil
    activeVersion, activeGeneration, lastFrameAt = nil, nil, nil
    local roleOk = syncRoleChatMode()
    local viewsOk = invalidateViews()
    if roleOk and viewsOk then
        Log("[INFO] back to the local tree")
    else
        Log("[ERROR] local tree restored, but one or more dependent caches failed to refresh")
    end
end

return TreeSync
