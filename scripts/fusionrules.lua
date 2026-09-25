-- fusionrules.lua: which species two Pals fuse into, and what the result keeps.
--
-- Pure functions only: no game objects, no hooks. fusion.lua feeds them values
-- it read from the Pals and writes the answers back.
--
-- Species: an authored rule (A + B -> C, order does not matter) always wins.
-- Without one, the fallback picks a species stronger than both inputs:
--
--   target = rankStrong - (RANK_MAX - rankWeak) * factor
--
-- CombiRank is the breeding power (lower = stronger). Only species of the
-- generic breeding pool ranked below the stronger input qualify; the one nearest
-- the target wins, with the breeding tie-break. The website runs the same
-- formula (Palvolve-Web/web/src/lib/fusion.ts) over the same generated data.

local COMBI = require("combi_static")

local FusionRules = {}

FusionRules.DEFAULT_FACTOR = 0.2

-- Palvolve's own markers never take one of the four passive places the player
-- picks from; they are merged separately.
local MARKER_PREFIX = "Palvolve_"

local RANK_MAX = 0
for _, id in ipairs(COMBI.pool) do
    local r = COMBI.ranks[id]
    if r and r.rank > RANK_MAX then RANK_MAX = r.rank end
end
FusionRules.RANK_MAX = RANK_MAX

--- Alpha individuals fuse as their base species.
function FusionRules.baseSpecies(id)
    if type(id) ~= "string" then return nil end
    if id:sub(1, 5) == "BOSS_" then return id:sub(6) end
    return id
end

--- Order-free key for a pair of species.
function FusionRules.pairKey(a, b)
    local x, y = FusionRules.baseSpecies(a), FusionRules.baseSpecies(b)
    if not (x and y) then return nil end
    if x < y then return x .. "|" .. y end
    return y .. "|" .. x
end

--- Whether a rule of kind ruleKind applies to a fusion of kind wanted
--- ("permanent" or "temporary").
function FusionRules.kindAllows(ruleKind, wanted)
    return ruleKind == "both" or ruleKind == wanted
end

--- Enabled rules for this pair and kind, in authored order.
function FusionRules.findRules(rules, a, b, wanted)
    local key = FusionRules.pairKey(a, b)
    local found = {}
    if not key or type(rules) ~= "table" then return found end
    for _, rule in ipairs(rules) do
        if rule.enabled ~= false and FusionRules.kindAllows(rule.kind or "both", wanted)
            and FusionRules.pairKey(rule.a, rule.b) == key then
            found[#found + 1] = rule
        end
    end
    return found
end

local function better(p, pr, best, br, target)
    local dp = math.abs(pr.rank - target)
    local db = math.abs(br.rank - target)
    if dp ~= db then return dp < db end
    if pr.priority ~= br.priority then return pr.priority > br.priority end
    local pv = pr.variant and 1 or 0
    local bv = br.variant and 1 or 0
    if pv ~= bv then return pv < bv end
    return p < best
end

--- The fallback formula. Returns child (or nil) and a table with target, the
--- two ranks and, when there is no child, the reason.
function FusionRules.fallback(a, b, factor)
    factor = tonumber(factor) or FusionRules.DEFAULT_FACTOR
    local ida, idb = FusionRules.baseSpecies(a), FusionRules.baseSpecies(b)
    local ra, rb = ida and COMBI.ranks[ida], idb and COMBI.ranks[idb]
    if not (ra and rb) then return nil, { reason = "unknown-species" } end
    if not (ra.breedable and rb.breedable) then
        return nil, { reason = "not-breedable", rankA = ra.rank, rankB = rb.rank }
    end
    local strong = math.min(ra.rank, rb.rank)
    local weak = math.max(ra.rank, rb.rank)
    local target = math.floor(strong - (RANK_MAX - weak) * factor)
    local best, bestRank = nil, nil
    for _, id in ipairs(COMBI.pool) do
        local r = COMBI.ranks[id]
        if r and r.rank < strong and id ~= ida and id ~= idb then
            if not best or better(id, r, best, bestRank, target) then
                best, bestRank = id, r
            end
        end
    end
    local info = { target = target, rankA = ra.rank, rankB = rb.rank }
    if not best then info.reason = "nothing-stronger" end
    return best, info
end

--- The level a fusion reaches: the highest level whose total exp fits the sum
--- of both Pals' exp. A Pal can sit at a level with less exp than that level
--- needs (a wild one caught at level 3 with 0 exp), so each side counts at
--- least its own level's total. totalExp(level) comes from the game's exp table.
function FusionRules.levelFor(levelA, expA, levelB, expB, totalExp, maxLevel)
    local function effective(level, exp)
        local floor = tonumber(totalExp(level)) or 0
        exp = tonumber(exp) or 0
        if exp < floor then return floor end
        return exp
    end
    local sum = effective(levelA, expA) + effective(levelB, expB)
    local level = math.max(levelA, levelB)
    local cap = tonumber(maxLevel) or 80
    while level < cap do
        local need = tonumber(totalExp(level + 1))
        -- every level above 1 needs some exp; a 0 means the table did not answer
        if not need or need <= 0 or need > sum then break end
        level = level + 1
    end
    return level, sum
end

--- The higher of two numbers, treating a missing one as 0.
function FusionRules.best(a, b)
    return math.max(tonumber(a) or 0, tonumber(b) or 0)
end

local function isMarker(id)
    return type(id) == "string" and id:sub(1, #MARKER_PREFIX) == MARKER_PREFIX
end
FusionRules.isMarker = isMarker

--- Every non-marker passive of both Pals, without duplicates, first A's then B's.
function FusionRules.passivePool(listA, listB)
    local seen, pool = {}, {}
    for _, list in ipairs({ listA or {}, listB or {} }) do
        for _, id in ipairs(list) do
            if not isMarker(id) and not seen[id] then
                seen[id] = true
                pool[#pool + 1] = id
            end
        end
    end
    return pool
end

--- Palvolve's markers for the fused Pal: the higher Evolved and the higher
--- Prestige stage of the two, the Evolved lock as A had it, and A's other
--- markers. skip names a marker that never carries over.
function FusionRules.mergeMarkers(listA, listB, skip)
    local evolved, prestige, locked = 0, 0, false
    local others = {}
    local function scan(list, fromA)
        for _, id in ipairs(list or {}) do
            local e, lock, pr = nil, nil, nil
            if type(id) == "string" then
                e, lock = id:match("^Palvolve_Evolved_(%d+)(_Locked)$")
                if not e then e = id:match("^Palvolve_Evolved_(%d+)$") end
                pr = id:match("^Palvolve_Prestige_(%d+)$")
            end
            if e then
                evolved = math.max(evolved, tonumber(e))
                if fromA and lock then locked = true end
            elseif pr then
                prestige = math.max(prestige, tonumber(pr))
            elseif fromA and isMarker(id) and id ~= skip then
                others[#others + 1] = id
            end
        end
    end
    scan(listA, true)
    scan(listB, false)
    local out = {}
    if evolved > 0 then out[#out + 1] = "Palvolve_Evolved_" .. evolved .. (locked and "_Locked" or "") end
    if prestige > 0 then out[#out + 1] = "Palvolve_Prestige_" .. prestige end
    for _, id in ipairs(others) do out[#out + 1] = id end
    return out
end

--- Up to max passives chosen by rank (highest first), ties by pool order.
--- rankOf(id) returns the passive's rank, nil counts as 0.
function FusionRules.autoPassives(listA, listB, rankOf, max)
    local pool = FusionRules.passivePool(listA, listB)
    local order = {}
    for i, id in ipairs(pool) do order[id] = i end
    table.sort(pool, function(x, y)
        local rx, ry = tonumber(rankOf(x)) or 0, tonumber(rankOf(y)) or 0
        if rx ~= ry then return rx > ry end
        return order[x] < order[y]
    end)
    local picked = {}
    for i = 1, math.min(max or 4, #pool) do picked[i] = pool[i] end
    return picked
end

return FusionRules
