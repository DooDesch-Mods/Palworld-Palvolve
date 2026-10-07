-- objtrack.lua: the live objects of a class, kept without walking the object list.
--
-- FindAllOf and FindFirstOf visit every object in the game. That is about 30 ms
-- on the game thread in a near-empty world and more in a built-up one, so a
-- timer that asks either of them is a frame hitch on a schedule. This module
-- answers the same questions from a list UE4SS fills as objects are built
-- (NotifyOnNewObject), plus one search when the list is started.
--
-- Requires only gameloop, which requires nothing, so every other module can
-- require it.

local GameLoop = require("gameloop")

local ObjTrack = {}

local function Log(msg)
    print(string.format("[Palvolve] [track] %s\n", tostring(msg)))
end

-- How long an object nobody can judge yet stays in the queue. A map object
-- model, for one, is built before it is told what it is.
local UNDECIDED_S = 30
-- How often an instance that outlasted UNDECIDED_S is asked from then on.
local PARKED_RETRY_S = 5
-- How often the queues of a list nobody reads are emptied.
local HOUSEKEEPING_MS = 30000
-- How often a list that could not register its notification searches instead.
-- Each search is the full walk this module exists to avoid.
local BLIND_SWEEP_S = 10
-- How soon a lookup that found nothing may walk the object list again.
local FIRST_RETRY_S = 1
-- How long after a list is started its one search runs. Lists started in the
-- same moment share the call.
local FIRST_SEARCH_MS = 50

local function isValidUnsafe(obj) return obj:IsValid() end
local function isAUnsafe(obj, cls) return obj:IsA(cls) end
local function addressUnsafe(obj) return obj:GetAddress() end
local function fullNameUnsafe(obj) return obj:GetFullName() end

local function isLive(obj)
    if obj == nil then return false end
    local ok, valid = pcall(isValidUnsafe, obj)
    return ok and valid == true
end

--- False for a class default object, which answers to the class like an
--- instance does and faults natively on most calls.
local function notDefault(obj)
    local ok, name = pcall(fullNameUnsafe, obj)
    return ok and type(name) == "string" and not name:find("Default__", 1, true)
end
ObjTrack.notDefault = notDefault

local Tracker = {}
Tracker.__index = Tracker

local trackers = {}

function Tracker:warnOnce(key, msg)
    if self.warned[key] then return end
    self.warned[key] = true
    Log("[WARN] " .. self.shortName .. ": " .. msg)
end

function Tracker:class()
    local cls = ObjTrack.static(self.classPath)
    if isLive(cls) then return cls end
    return nil
end

--- Still the object it was listed as. IsValid only says the address holds a
--- live object, and the engine hands a freed address to the next object it
--- builds, so the class is asked as well.
function Tracker:alive(obj)
    if not isLive(obj) then return false end
    local cls = self:class()
    if not cls then
        self:warnOnce("class", "class " .. self.classPath
            .. " does not resolve, instances are kept on IsValid alone")
        return true
    end
    local ok, isA = pcall(isAUnsafe, obj, cls)
    if not ok then
        self:warnOnce("isa", "an instance would not say its class and is dropped: " .. tostring(isA))
        return false
    end
    return isA == true
end

--- true: belongs in the list. false: never will. nil: cannot be told yet.
function Tracker:judge(obj)
    if not self:alive(obj) then return false end
    if not self.accept then return notDefault(obj) end
    local ok, verdict = pcall(self.accept, obj)
    if not ok then
        self:warnOnce("accept", "an instance could not be judged: " .. tostring(verdict))
        return nil
    end
    return verdict
end

function Tracker:add(obj)
    local ok, addr = pcall(addressUnsafe, obj)
    if not ok then
        self:warnOnce("address", "an instance has no address: " .. tostring(addr))
        return
    end
    local at = self.index[addr]
    if at then
        -- The address is listed already: the engine gave it to a new object
        -- while the old one was still in the list. A reader that keeps its own
        -- view by version has to look again.
        self.objs[at] = obj
        self.version = self.version + 1
        return
    end
    local n = #self.objs + 1
    self.objs[n] = obj
    self.addrs[n] = addr
    self.index[addr] = n
    self.version = self.version + 1
    if not self.listedOne then
        self.listedOne = true
        Log("[INFO] " .. self.shortName .. ": first one listed")
    end
end

--- Judges everything that was built or offered since the last look.
function Tracker:drain()
    local now = os.clock()
    local parkedDue = #self.parked > 0 and now - self.parkedAt >= PARKED_RETRY_S
    if #self.pending == 0 and #self.waiting == 0 and not parkedDue then return end
    local fresh, waiting = self.pending, self.waiting
    self.pending, self.waiting = {}, {}
    for i = 1, #fresh do
        local obj = fresh[i]
        local verdict = self:judge(obj)
        if verdict == true then
            self:add(obj)
        elseif verdict == nil then
            self.waiting[#self.waiting + 1] = { obj = obj, since = now }
        end
    end
    for i = 1, #waiting do
        local w = waiting[i]
        local verdict = self:judge(w.obj)
        if verdict == true then
            self:add(w.obj)
        elseif verdict == nil then
            if now - w.since < UNDECIDED_S then
                self.waiting[#self.waiting + 1] = w
            else
                self.parked[#self.parked + 1] = w.obj
                self:warnOnce("undecided", string.format(
                    "an instance could not be told apart within %d s, asked every %d s from here on",
                    UNDECIDED_S, PARKED_RETRY_S))
            end
        end
    end
    if parkedDue then
        self.parkedAt = now
        local parked = self.parked
        self.parked = {}
        for i = 1, #parked do
            local verdict = self:judge(parked[i])
            if verdict == true then
                self:add(parked[i])
            elseif verdict == nil then
                self.parked[#self.parked + 1] = parked[i]
            end
        end
    end
end

--- Drops what is gone. The list a caller holds is never changed under it: a
--- loss builds new tables.
function Tracker:prune()
    local objs = self.objs
    local dead = false
    for i = 1, #objs do
        if not self:alive(objs[i]) then
            dead = true
            break
        end
    end
    if not dead then return end
    local keptObjs, keptAddrs, index = {}, {}, {}
    for i = 1, #objs do
        if self:alive(objs[i]) then
            local n = #keptObjs + 1
            keptObjs[n] = objs[i]
            keptAddrs[n] = self.addrs[i]
            index[self.addrs[i]] = n
        end
    end
    self.objs, self.addrs, self.index = keptObjs, keptAddrs, index
    self.version = self.version + 1
end

--- Walks the object list once and offers every instance. Costs a full walk.
function Tracker:sweep()
    self.sweptAt = os.clock()
    local ok, found = pcall(FindAllOf, self.shortName)
    if not ok then
        self:warnOnce("sweep", "search failed: " .. tostring(found))
        return 0
    end
    local n = 0
    for _, obj in ipairs(found or {}) do
        self:offer(obj)
        n = n + 1
    end
    return n
end

--- Hands the list an object from somewhere else, a hook's context for one.
function Tracker:offer(obj)
    if obj == nil then return end
    local ok, addr = pcall(addressUnsafe, obj)
    if ok and self.index[addr] then return end
    self.pending[#self.pending + 1] = obj
end

--- Hands the list an instance a hook was given. One the list does not have
--- although nothing was ever announced means the notification does not
--- deliver in this process, and the list searches from then on.
function Tracker:witness(obj)
    if not isLive(obj) then return end
    self:drain()
    local ok, addr = pcall(addressUnsafe, obj)
    if not ok then
        self:warnOnce("address", "an instance has no address: " .. tostring(addr))
        return
    end
    if self.index[addr] then return end
    if self.announced == 0 and not self.blind then
        self.blind = true
        Log(string.format("[ERROR] %s: an instance exists that was never announced, searching every %d s instead",
            self.shortName, BLIND_SWEEP_S))
    end
    self.pending[#self.pending + 1] = obj
end

function Tracker:sweepDue()
    return self.blind and os.clock() - self.sweptAt >= BLIND_SWEEP_S
end

--- The live instances. Read it, do not change it.
function Tracker:list()
    if self:sweepDue() then self:sweep() end
    self:prune()
    self:drain()
    return self.objs
end

--- True when a caller's tick has nothing to look at and nothing to wait for.
function Tracker:idle()
    return #self.objs == 0 and #self.pending == 0 and #self.waiting == 0
        and not self:sweepDue()
end

-- Lists started and not searched yet. The search has to run on the game
-- thread, and it goes through the game loop rather than ExecuteInGameThread:
-- that one registers a callback per call, and UE4SS collecting those is what
-- UE4SS-LESSONS.md section 1 is about.
local unswept = {}
local firstSearchDue = false

local function firstSearch()
    firstSearchDue = false
    local batch = unswept
    unswept = {}
    for _, t in ipairs(batch) do
        local n = t:sweep()
        Log(string.format("[INFO] %s: %d already there", t.shortName, n))
    end
end

local function scheduleFirstSearch()
    if firstSearchDue then return end
    firstSearchDue = true
    if GameLoop.after(FIRST_SEARCH_MS, firstSearch, "first search") == nil then
        firstSearchDue = false
        Log("[WARN] the first search was not scheduled, the lists start empty")
    end
end

--- Starts a list of the instances of one class.
---   classPath  what NotifyOnNewObject takes, "/Script/Pal.PalPlayerController"
---   shortName  what FindAllOf takes, "PalPlayerController"
---   opts.accept(obj)  true, false or nil (not known yet, asked again); without
---                     it every instance but the class default counts
---   opts.sweep = false  skips the one search at the start, for a class that
---                       cannot have instances yet
function ObjTrack.follow(classPath, shortName, opts)
    opts = opts or {}
    local t = setmetatable({
        classPath = classPath,
        shortName = shortName,
        accept = opts.accept,
        objs = {}, addrs = {}, index = {},
        pending = {}, waiting = {},
        parked = {}, parkedAt = -math.huge,
        announced = 0,
        warned = {},
        version = 0,
        sweptAt = -math.huge,
        blind = false,
    }, Tracker)

    -- Only an append: this runs inside object construction, and the object is
    -- not finished yet. Held by the list, so the callback is never collected.
    t.onNew = function(obj)
        t.announced = t.announced + 1
        t.pending[#t.pending + 1] = obj
    end
    local ok, err = pcall(NotifyOnNewObject, classPath, t.onNew)
    if ok then
        Log("following " .. shortName)
    else
        t.blind = true
        Log(string.format("[ERROR] cannot follow %s (%s), searching every %d s instead",
            shortName, tostring(err), BLIND_SWEEP_S))
    end

    if opts.sweep ~= false then
        unswept[#unswept + 1] = t
        scheduleFirstSearch()
    end

    trackers[#trackers + 1] = t
    return t
end

-- A list is only emptied of what was built when somebody reads it. One that
-- is followed and rarely read would hold a wrapper per object ever built, so
-- its queues are judged here on a slow beat. No search runs from this.
local function housekeeping()
    for _, t in ipairs(trackers) do
        if #t.pending > 0 then
            t:prune()
            t:drain()
        end
    end
    return false
end

if GameLoop.start(HOUSEKEEPING_MS, housekeeping, "list housekeeping") == nil then
    Log("[WARN] list housekeeping did not start, an unread list keeps what it was told")
end

-- ---------------------------------------------------------------- one of a kind

local firsts = {}

local function validNameUnsafe(obj)
    if not obj:IsValid() then return nil end
    return obj:GetFullName()
end

--- The first instance of a class, like FindFirstOf, but found once and kept
--- for as long as it stays the same object. A miss is not asked again within
--- FIRST_RETRY_S, so a caller polling for something that is not there walks the
--- object list once a second at most.
function ObjTrack.first(shortName)
    local e = firsts[shortName]
    if not e then
        e = { askedAt = -math.huge }
        firsts[shortName] = e
    end
    if e.obj ~= nil then
        local ok, name = pcall(validNameUnsafe, e.obj)
        if ok and name ~= nil and name == e.name then return e.obj end
        e.obj, e.name = nil, nil
    end
    local now = os.clock()
    if now - e.askedAt < FIRST_RETRY_S then return nil end
    e.askedAt = now
    local okFind, found = pcall(FindFirstOf, shortName)
    if not okFind then
        if not e.warned then
            e.warned = true
            Log("[WARN] search for " .. shortName .. " failed: " .. tostring(found))
        end
        return nil
    end
    local okName, name = pcall(validNameUnsafe, found)
    if okName and name ~= nil then
        e.obj, e.name = found, name
        return found
    end
    if not okName and not e.warned then
        e.warned = true
        Log("[WARN] " .. shortName .. " was found and would not say its name: " .. tostring(name))
    end
    return nil
end

-- ---------------------------------------------------------------- by path

-- How long a path that was not there twice in a row is left alone.
local STATIC_RETRY_S = 5

local statics = {}

local function findStaticUnsafe(path)
    local obj = StaticFindObject(path)
    return obj, obj ~= nil and obj:IsValid() == true
end

--- The object at a path, like StaticFindObject, but found once and kept.
---
--- StaticFindObject is a search in this UE4SS build too: about 1.5 ms for a
--- class default object, and a walk of the whole object list, about 30 ms, for
--- a path that is not loaded. The modules ask for the same handful of library
--- objects on every call, some of them from timers.
---
--- A path that was not there is searched for once more on the next ask,
--- because the callers load a missing asset and then ask again. A path that was
--- not there both times is left alone until STATIC_RETRY_S after the last
--- search. A miss hands back what StaticFindObject did, an object that answers
--- IsValid() with false, or nil when the lookup itself failed.
local warnedNoPath = false

function ObjTrack.static(path)
    if type(path) ~= "string" then
        if not warnedNoPath then
            warnedNoPath = true
            Log("[WARN] asked for the object at " .. tostring(path) .. ", which is not a path")
        end
        return nil
    end
    local e = statics[path]
    if not e then
        e = { misses = 0, missedAt = -math.huge }
        statics[path] = e
    end
    if e.obj ~= nil then
        if e.native then
            -- Native classes and their default objects live as long as the game.
            if isLive(e.obj) then return e.obj end
        else
            -- An asset can be unloaded and its address handed to another
            -- object, so it also has to still answer to its name.
            local ok, name = pcall(validNameUnsafe, e.obj)
            if ok and name ~= nil and name == e.name then return e.obj end
        end
        e.obj, e.name = nil, nil
    end
    local now = os.clock()
    if now - e.missedAt >= STATIC_RETRY_S then e.misses = 0 end
    if e.misses >= 2 then return e.last end
    local ok, obj, found = pcall(findStaticUnsafe, path)
    if not ok then
        if not e.warned then
            e.warned = true
            Log("[WARN] lookup of " .. tostring(path) .. " failed: " .. tostring(obj))
        end
        obj, found = nil, false
    end
    if found then
        e.misses, e.last = 0, nil
        local native = tostring(path):sub(1, 8) == "/Script/"
        local okName, name = pcall(fullNameUnsafe, obj)
        -- An asset that cannot say its name cannot be told from its successor
        -- at the same address, so it is handed on and searched for again.
        if native or (okName and type(name) == "string") then
            e.obj, e.name, e.native = obj, name, native
        end
        return obj
    end
    e.misses = e.misses + 1
    e.missedAt = now
    e.last = obj
    return obj
end

--- One line per list, for a support log or a dev probe.
function ObjTrack.report()
    for _, t in ipairs(trackers) do
        Log(string.format("[INFO] %s: %d live, %d queued, %d undecided, %d parked, %d announced%s",
            t.shortName, #t.objs, #t.pending, #t.waiting, #t.parked, t.announced,
            t.blind and ", searching (notification failed)" or ""))
    end
    for name, e in pairs(firsts) do
        Log(string.format("[INFO] %s: %s", name, e.obj ~= nil and "held" or "not held"))
    end
    local held, absent = 0, 0
    for _, e in pairs(statics) do
        if e.obj ~= nil then held = held + 1 else absent = absent + 1 end
    end
    Log(string.format("[INFO] paths: %d held, %d not there", held, absent))
end

return ObjTrack
