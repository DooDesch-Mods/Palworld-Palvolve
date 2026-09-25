-- fusionpartner.lua: the partner steps out before a battle fusion, about 2 seconds.
--
--   appear   B's body forms next to the summoned Pal A in a burst of B's element
--   hold     B stands still, facing A
--   merge    B glides into A and shrinks away; the fusion scene takes over
--
-- B lives in the party ball during a battle fusion, and a player has only one
-- summoned Pal. Its body here is a phantom (the same kind the Display Cage
-- spawns), created on the host and replicated, so every player sees it.
-- Nothing of either Pal is written while this plays: the caller commits the
-- fusion in onDone, and a phantom that does not appear only skips the show.
--
-- One LoopAsync driver hands its ticks to the game thread through a function
-- the module holds, as fusionfx.lua does (UE4SS-LESSONS.md section 1).

local Elements = require("elements")
local FusionFx = require("fusionfx")

local FusionPartner = {}

local function Log(msg)
    print(string.format("[Palvolve] [fusionpartner] %s\n", tostring(msg)))
end

local TICK_MS = 33
local FIND_S = 1.5              -- how long to wait for the phantom to exist
local HOLD_S, MERGE_S = 1.2, 0.9
local SIDE = 240                -- units beside A where B appears
local FRONT = 200               -- and towards the player, so A does not hide it

local run = nil
local driving = false

local function valid(a) return a ~= nil and a:IsValid() end
local function lerp(a, b, t) return a + (b - a) * t end
local function ease(t) return t * t * (3 - 2 * t) end

local function characterManager()
    for _, m in ipairs(FindAllOf("PalCharacterManager") or {}) do
        local okName, name = pcall(function() return m:GetFullName() end)
        if okName and not name:find("Default__", 1, true) and m:IsValid() then return m end
    end
    return nil
end

--- Phantom ids of B that exist right now, as a set.
local function phantomIds(paramB)
    local ids = {}
    local ok, err = pcall(function()
        paramB.PhantomActorMap:ForEach(function(k, v)
            ids[k:get()] = v:get()
        end)
    end)
    if not ok then Log("[WARN] phantom map unreadable: " .. tostring(err)) end
    return ids
end

local function finish(reason, shown)
    if not run then return end
    local r = run
    run = nil
    -- hidden first, so the removal does not flash the body at full size
    if valid(r.b) then
        local okHide, hideErr = pcall(function() r.b:SetActorHiddenInGame(true) end)
        if not okHide then Log("[WARN] partner not hidden before removal: " .. tostring(hideErr)) end
    end
    if r.phantomId ~= nil then
        local mgr = characterManager()
        local okDespawn, despawnErr = false, "no character manager"
        if mgr then
            okDespawn, despawnErr = pcall(function() mgr:DespawnPhantomByHandle(r.handleB, r.phantomId, nil) end)
        end
        if okDespawn then
            Log("partner phantom removed (" .. reason .. ")")
        else
            Log("[WARN] partner phantom not removed: " .. tostring(despawnErr))
        end
    end
    -- A removed body can come back from the pool: it goes back full size, free and visible.
    if valid(r.b) then
        local okScale, scaleErr = pcall(function() r.b:SetActorScale3D({ X = 1, Y = 1, Z = 1 }) end)
        if not okScale then Log("[WARN] partner scale not reset: " .. tostring(scaleErr)) end
        local okFree, freeErr = pcall(r.freeze, r.b, false)
        if not okFree then Log("[WARN] partner not unfrozen: " .. tostring(freeErr)) end
        local okShow, showErr = pcall(function() r.b:SetActorHiddenInGame(false) end)
        if not okShow then Log("[WARN] partner visibility not reset: " .. tostring(showErr)) end
    end
    Log("partner scene ended: " .. reason)
    local ok, err = pcall(r.onDone, shown == true)
    if not ok then Log("[ERROR] partner onDone failed: " .. tostring(err)) end
end

local function aLocation(r)
    local l = r.actorA:K2_GetActorLocation()
    return l.X, l.Y, l.Z
end

local function stepFind(r, t)
    for id, actor in pairs(phantomIds(r.paramB)) do
        if not r.before[id] and valid(actor) then
            r.phantomId, r.b = id, actor
            local okFreeze, freezeErr = pcall(r.freeze, actor, true)
            if not okFreeze then Log("[WARN] partner not frozen: " .. tostring(freezeErr)) end
            local l = actor:K2_GetActorLocation()
            r.bx, r.by, r.bz = l.X, l.Y, l.Z
            r.foundAt = t
            FusionFx.spark(r.worldCtx, r.elemB, r.bx, r.by, r.bz + 60, 1.0)
            Log("partner phantom " .. tostring(id) .. " appeared")
            return
        end
    end
    if t > FIND_S then finish("the partner's body did not appear", false) end
end

local function stepMerge(r, t)
    local ax, ay, az = aLocation(r)
    local yaw = math.deg(math.atan(ay - r.by, ax - r.bx))
    local mt = (t - r.foundAt - HOLD_S) / MERGE_S
    if mt < 0 then
        r.b:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
        return
    end
    mt = math.min(1, mt)
    local e = ease(mt)
    local x, y = lerp(r.bx, ax, e), lerp(r.by, ay, e)
    local z = lerp(r.bz, az, e) + math.sin(mt * math.pi) * 120
    r.b:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true)
    local s = lerp(1, 0.15, e)
    r.b:SetActorScale3D({ X = s, Y = s, Z = s })
    if mt >= 1 then
        FusionFx.absorbAt(r.worldCtx, ax, ay, az + 80)
        finish("merged", true)
    end
end

local function tickGameThread()
    local r = run
    if not r then return end
    local t = os.clock() - r.startedAt
    if not valid(r.actorA) then
        finish("the summoned Pal left", false)
        return
    end
    if t > FIND_S + HOLD_S + MERGE_S + 2 then
        finish("timed out", r.b ~= nil)
        return
    end
    local ok, err
    if not r.b then
        ok, err = pcall(stepFind, r, t)
    elseif not valid(r.b) then
        finish("the partner's body vanished", false)
        return
    else
        ok, err = pcall(stepMerge, r, t)
    end
    if not ok then
        Log("[ERROR] partner scene step failed: " .. tostring(err))
        finish("step failed", false)
    end
end
FusionPartner._tickGameThread = tickGameThread

local function tick()
    if not run then
        driving = false
        return true
    end
    ExecuteInGameThread(FusionPartner._tickGameThread)
    return false
end
FusionPartner._tick = tick -- held by the module so the scheduled callback is never collected

--- Shows B stepping out next to A and merging into it. Host only.
--- opts: worldCtx, actorA, handleB, paramB, idB, freeze(actor, frozen),
--- onDone(shown). Returns false (and does not call onDone) when nothing starts.
function FusionPartner.play(opts)
    if run then return false, "a partner scene is already playing" end
    if not (valid(opts.actorA) and valid(opts.handleB) and valid(opts.paramB)) then
        return false, "no summoned Pal or partner"
    end
    local mgr = characterManager()
    if not mgr then return false, "no character manager" end

    local okLoc, ax, ay, az = pcall(function()
        local l = opts.actorA:K2_GetActorLocation()
        return l.X, l.Y, l.Z
    end)
    if not okLoc then return false, "summoned Pal has no location: " .. tostring(ax) end
    -- beside A and a little towards the player, so the camera sees both
    local sx, sy, fx, fy = 1, 0, 0, 0
    local okDir, px, py = pcall(function()
        local l = opts.worldCtx:K2_GetPawn():K2_GetActorLocation()
        return l.X, l.Y
    end)
    if okDir then
        local dx, dy = ax - px, ay - py
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 1 then sx, sy, fx, fy = -dy / len, dx / len, -dx / len, -dy / len end
    else
        Log("[WARN] player location unreadable, B appears on the X side of A: " .. tostring(px))
    end

    local before = phantomIds(opts.paramB)
    local okSpawn, spawnErr = pcall(function()
        mgr:SpawnPhantomByHandle(opts.handleB, {
            SpawnLocation = { X = ax + sx * SIDE + fx * FRONT, Y = ay + sy * SIDE + fy * FRONT, Z = az },
            SpawnRotation = { Pitch = 0, Yaw = 0, Roll = 0 },
            SpawnScale = { X = 1, Y = 1, Z = 1 },
            bNeedAdjustToFloor = true,
        }, nil)
    end)
    if not okSpawn then return false, "phantom spawn failed: " .. tostring(spawnErr) end

    run = {
        worldCtx = opts.worldCtx, actorA = opts.actorA, handleB = opts.handleB, paramB = opts.paramB,
        elemB = (Elements.of(opts.idB, opts.worldCtx) or {})[1] or "Normal",
        freeze = opts.freeze, onDone = opts.onDone, before = before, startedAt = os.clock(),
    }
    if not driving then
        driving = true
        LoopAsync(TICK_MS, FusionPartner._tick)
    end
    Log("partner scene started (" .. tostring(opts.idB) .. ")")
    return true
end

return FusionPartner
