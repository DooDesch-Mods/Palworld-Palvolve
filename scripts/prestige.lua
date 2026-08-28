-- Palvolve prestige connections: roster-wide chain ends and deterministic bases.

local Prestige = {}

local okPaldex, PALDEX = pcall(require, "paldex_static")
if not okPaldex or type(PALDEX) ~= "table" then PALDEX = nil end

local okElements, ELEMENTS = pcall(require, "elements_static")
if not okElements or type(ELEMENTS) ~= "table" then ELEMENTS = {} end

local cacheMap, cacheShippedMap, cacheMin = nil, nil, nil
local cacheTargets, cacheByFrom = nil, nil

local function addUnique(list, seen, id)
    if type(id) ~= "string" or id == "" or seen[id] then return end
    seen[id] = true
    list[#list + 1] = id
end

local function isTerraria(id)
    return id:match("^YakushimaMonster%d+[_%a]*$") ~= nil
        or id:match("^YakushimaBoss001[_%a]*$") ~= nil
end

-- The runtime already ships the numbered Paldeck roster. The only rows outside
-- it which the editor admits are map-referenced hidden variants and the eleven
-- catchable Terraria forms, so the same 302-Pal roster can be rebuilt here
-- without maintaining a second hand-authored species list.
local function buildRoster(shippedMap)
    if not PALDEX then return nil, "paldex_static is unavailable" end
    local roster, seen = {}, {}
    for id in pairs(PALDEX) do addUnique(roster, seen, id) end
    for _, pair in ipairs(shippedMap or {}) do
        addUnique(roster, seen, pair.from)
        addUnique(roster, seen, pair.to)
    end
    for id in pairs(ELEMENTS) do
        if isTerraria(id) then addUnique(roster, seen, id) end
    end
    table.sort(roster)
    return roster
end

local function sharedElementCount(left, right)
    local wanted, count = {}, 0
    for _, element in ipairs(left or {}) do wanted[element] = true end
    local counted = {}
    for _, element in ipairs(right or {}) do
        if wanted[element] and not counted[element] then
            counted[element] = true
            count = count + 1
        end
    end
    return count
end

-- Every meaningful tie-break lives here, in the spec's order. Keeping the
-- precedence in one comparator prevents one traversal from quietly choosing a
-- different family when adaptations make several bases reachable.
local function betterBase(endElements, left, right)
    if not right then return true end
    local leftShared = sharedElementCount(endElements, ELEMENTS[left.id])
    local rightShared = sharedElementCount(endElements, ELEMENTS[right.id])
    if leftShared ~= rightShared then return leftShared > rightShared end
    if left.depth ~= right.depth then return left.depth > right.depth end
    return left.order < right.order
end

local function deriveConnections(map, shippedMap, minimum)
    local roster, rosterErr = buildRoster(shippedMap)
    if not roster then return nil, rosterErr end

    local incoming, outgoing, firstFromOrder = {}, {}, {}
    local authoredByFrom = {}
    for order, pair in ipairs(map or {}) do
        if type(pair) == "table" and type(pair.from) == "string"
            and type(pair.to) == "string" then
            if pair.category == "prestige" then
                local authored = authoredByFrom[pair.from]
                if not authored then authored = {}; authoredByFrom[pair.from] = authored end
                authored[#authored + 1] = pair
            elseif pair.enabled == true then
                outgoing[pair.from] = true
                if firstFromOrder[pair.from] == nil then firstFromOrder[pair.from] = order end
                local parents = incoming[pair.to]
                if not parents then parents = {}; incoming[pair.to] = parents end
                parents[#parents + 1] = pair.from
            end
        end
    end

    local derived = {}
    for _, chainEnd in ipairs(roster) do
        if not outgoing[chainEnd] then
            local candidates = {}
            local function trace(id, depth, seen)
                local parents = incoming[id]
                if not parents or #parents == 0 then
                    local existing = candidates[id]
                    if not existing or depth > existing.depth then
                        candidates[id] = {
                            id = id,
                            depth = depth,
                            order = firstFromOrder[id] or math.huge,
                        }
                    end
                    return
                end
                for _, parent in ipairs(parents) do
                    if not seen[parent] then
                        local nextSeen = {}
                        for visited in pairs(seen) do nextSeen[visited] = true end
                        nextSeen[parent] = true
                        trace(parent, depth + 1, nextSeen)
                    end
                end
            end
            trace(chainEnd, 0, { [chainEnd] = true })

            local depth, best = 0, nil
            for _, candidate in pairs(candidates) do
                if candidate.depth > depth then depth = candidate.depth end
                if betterBase(ELEMENTS[chainEnd] or {}, candidate, best) then best = candidate end
            end
            if minimum == 0 or (best and depth >= minimum) then
                derived[#derived + 1] = {
                    from = chainEnd,
                    to = minimum == 0 and chainEnd or best.id,
                    category = "prestige",
                    minLevel = nil,
                    stone = "prestige",
                    enabled = true,
                    autoEvolve = false,
                    derived = true,
                    prestigeDepth = depth,
                }
            end
        end
    end

    local targets = {}
    for _, connection in ipairs(derived) do
        local authored = authoredByFrom[connection.from]
        if authored then
            -- Any authored row, including a disabled one, replaces the default
            -- for that chain end. This is how an editor can persist an explicit
            -- disable without the runtime immediately deriving the row again.
            for _, pair in ipairs(authored) do
                if pair.enabled == true then
                    pair.prestigeDepth = connection.prestigeDepth
                    targets[#targets + 1] = pair
                end
            end
        else
            targets[#targets + 1] = connection
        end
    end

    -- An authored prestige row whose `from` is not a chain end used to be
    -- dropped without a word: the loop above only ever visits DERIVED rows, so
    -- a row nothing derived had nowhere to attach. Someone who writes an
    -- explicit prestige pair means it, and silently ignoring it is the worst of
    -- the three possible behaviours.
    local seen = {}
    for _, pair in ipairs(targets) do seen[pair] = true end
    for _, authored in pairs(authoredByFrom) do
        for _, pair in ipairs(authored) do
            if pair.enabled == true and not seen[pair] then
                targets[#targets + 1] = pair
            end
        end
    end
    return targets
end

function Prestige.targets(config)
    local map = config and config.map or nil
    local shippedMap = config and (config.builtinMap or config.map) or nil
    local minimum = math.max(0, math.floor(tonumber(config and config.prestigeMinEvolutions) or 0))
    if cacheTargets and cacheMap == map and cacheShippedMap == shippedMap and cacheMin == minimum then
        return cacheTargets, cacheByFrom
    end

    local targets, err = deriveConnections(map, shippedMap, minimum)
    if not targets then return {}, {}, err end
    local byFrom = {}
    for index, pair in ipairs(targets) do
        pair.prestigeIndex = index
        if pair.derived then pair.minLevel = config.prestigeMinLevel end
        local list = byFrom[pair.from]
        if not list then list = {}; byFrom[pair.from] = list end
        list[#list + 1] = pair
    end
    cacheMap, cacheShippedMap, cacheMin = map, shippedMap, minimum
    cacheTargets, cacheByFrom = targets, byFrom
    return targets, byFrom
end

function Prestige.forSpecies(config, characterId)
    local _, byFrom, err = Prestige.targets(config)
    return byFrom[characterId] or {}, err
end

function Prestige.invalidate()
    cacheMap, cacheShippedMap, cacheMin = nil, nil, nil
    cacheTargets, cacheByFrom = nil, nil
end

-- Exposed for the release proof and for a pure-data regression check. Runtime
-- callers use targets(), whose authored-row overlay intentionally comes later.
function Prestige.derive(map, shippedMap, minimum)
    return deriveConnections(map, shippedMap, math.max(0, math.floor(tonumber(minimum) or 0)))
end

return Prestige
