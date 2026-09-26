-- fusionpartner.lua: the partner steps out before a battle fusion, about 2 seconds.
--
--   appear   B's body forms next to the summoned Pal A: the sphere's release
--            sound, a lightning strike and a burst in B's element
--   charge   B rises facing A while energy gathers between them (the altar
--            scene's drone and charge sounds)
--   merge    B shoots into A and shrinks away; the fusion's impact takes over
--
-- The movement is the host's (the phantom replicates); the effects and sounds
-- are each machine's own (prelude below), because a dedicated server's reach
-- nobody.
--
-- B lives in the party ball during a battle fusion, and a player has only one
-- summoned Pal. Its body here is a phantom (the same kind the Display Cage
-- spawns), created on the host and replicated, so every player sees it.
-- Nothing of either Pal is written while this plays: the caller commits the
-- fusion in onDone, and a phantom that does not appear only skips the show.
--
-- One game-thread loop (gameloop.lua) drives the ticks through a function the
-- module holds, as fusionfx.lua does (UE4SS-LESSONS.md section 1).

local Elements = require("elements")
local FusionFx = require("fusionfx")
local FusionCam = require("fusioncam")
local Rig = require("fusionrig")
local GameLoop = require("gameloop")
local Role = require("role")
local Sound = require("sound")

local FusionPartner = {}

local function Log(msg)
    print(string.format("[Palvolve] [fusionpartner] %s\n", tostring(msg)))
end

local TICK_MS = 33
local FIND_S = 1.5              -- how long to wait for the phantom to exist
local HOLD_S, MERGE_S = 1.5, 0.6
local LIFT, LIFT_S = 80, 1.0     -- B rises this far during the charge
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
local phantomWalk = nil
local function collectPhantom(k, v) phantomWalk[k:get()] = v:get() end
local function walkPhantoms(paramB) paramB.PhantomActorMap:ForEach(collectPhantom) end
local function phantomIds(paramB)
    phantomWalk = {}
    local ok, err = pcall(walkPhantoms, paramB)
    if not ok then Log("[WARN] phantom map unreadable: " .. tostring(err)) end
    local ids = phantomWalk
    phantomWalk = nil
    return ids
end

-- The prelude: what each machine sees and hears while the host moves B.
-- Timed from B's appearance, on the same clock as HOLD_S and MERGE_S. No
-- encounter animation: for many Pals that is an attack with its hit sounds.
local prelude = nil
local preludeDriving = false

local function mid(p) return (p.ax + p.bx) / 2, (p.ay + p.by) / 2, (p.az + p.bz) / 2 + 60 end

-- The drone and the charge loop until they are stopped, so they play on a
-- holder actor that is removed at the merge, the way the altar scene plays
-- them on its pivot. A sound posted at a bare location would never end.
local function holderOf(p)
    if p.holder and p.holder:IsValid() then return p.holder end
    local x, y, z = mid(p)
    local holder, err = Rig.spawn(p.worldCtx, x, y, z, 0)
    if not holder then Log("[WARN] partner sound holder not spawned, the loops stay silent: " .. tostring(err)) end
    p.holder = holder
    return holder
end

local function loopOn(p, path)
    local holder = holderOf(p)
    if holder then Sound.onActor(path, holder, true) end
end

local function endLoops(p)
    local holder = p.holder
    p.holder = nil
    if not (holder and holder:IsValid()) then return end
    Sound.stopOn(holder)
    Rig.destroy(holder)
end

local PRELUDE_CUES = {
    { t = 0.00, fn = function(p)
        Sound.at(Sound.PAL_RELEASE, p.worldCtx, p.bx, p.by, p.bz)
        FusionFx.lightningAt(p.worldCtx, p.bx, p.by, p.bz)
        FusionFx.spark(p.worldCtx, p.elemB, p.bx, p.by, p.bz + 60, 1.3)
    end },
    { t = 0.25, fn = function(p)
        loopOn(p, Sound.SUMMON_HAZE)
        FusionFx.spark(p.worldCtx, p.elemA, p.ax, p.ay, p.az + 60, 1.1)
    end },
    { t = 0.45, fn = function(p)
        local x, y, z = mid(p)
        loopOn(p, Sound.ENERGY_CHARGE)
        FusionFx.absorbAt(p.worldCtx, x, y, z, 1.3)
    end },
    { t = HOLD_S, fn = function(p)
        local x, y, z = mid(p)
        FusionFx.speedlinesAt(p.worldCtx, x, y, z)
    end },
    { t = HOLD_S + MERGE_S, fn = function(p)
        endLoops(p)
        FusionFx.absorbAt(p.worldCtx, p.ax, p.ay, p.az + 80, 1.4)
        FusionFx.spark(p.worldCtx, p.elemB, p.ax, p.ay, p.az + 60, 1.2)
        FusionCam.shake(p.worldCtx, 0.6)
    end },
}

function FusionPartner._preludeTick()
    local p = prelude
    if not p then
        preludeDriving = false
        return true
    end
    local t = os.clock() - p.startedAt
    while p.cue <= #PRELUDE_CUES and t >= PRELUDE_CUES[p.cue].t do
        local cue = PRELUDE_CUES[p.cue]
        p.cue = p.cue + 1
        local ok, err = pcall(cue.fn, p)
        if not ok then Log("[WARN] partner prelude beat " .. p.cue - 1 .. " failed: " .. tostring(err)) end
    end
    if p.cue > #PRELUDE_CUES then
        endLoops(p)
        prelude = nil
        preludeDriving = false
        return true
    end
    return false
end

--- Starts the prelude on this machine. info: bx, by, bz, ax, ay, az, idA, idB.
local function playPrelude(worldCtx, info)
    if prelude then endLoops(prelude) end
    prelude = {
        worldCtx = worldCtx, startedAt = os.clock(), cue = 1,
        bx = info.bx, by = info.by, bz = info.bz, ax = info.ax, ay = info.ay, az = info.az,
        elemA = (Elements.of(info.idA, worldCtx) or {})[1] or "Normal",
        elemB = (Elements.of(info.idB, worldCtx) or {})[1] or "Normal",
    }
    if not preludeDriving then
        preludeDriving = true
        GameLoop.start(TICK_MS, FusionPartner._preludeTick, "partner prelude")
    end
end

--- The players' side of a server's partner scene (NetChannel.broadcastPartner).
function FusionPartner.callRemote(info)
    local pc = Role.getLocalPlayerController()
    if not (pc and pc:IsValid()) then
        Log("[WARN] partner prelude skipped: no local player")
        return
    end
    playPrelude(pc, info)
    Log("partner prelude started (" .. tostring(info.idB) .. ")")
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
            Log("partner phantom " .. tostring(id) .. " appeared")
            local ax, ay, az = aLocation(r)
            local info = { bx = r.bx, by = r.by, bz = r.bz, ax = ax, ay = ay, az = az, idA = r.idA, idB = r.idB }
            -- a dedicated server has nobody to show it to; the players play it themselves
            if not Role.isDedicated() then
                local okPrelude, preludeErr = pcall(playPrelude, r.worldCtx, info)
                if not okPrelude then Log("[WARN] partner prelude failed: " .. tostring(preludeErr)) end
            end
            local okNet, NetChannel = pcall(require, "netchannel")
            if okNet then
                local okSend, sendErr = pcall(NetChannel.broadcastPartner, info)
                if not okSend then Log("[WARN] partner call not sent to the players: " .. tostring(sendErr)) end
            else
                Log("[WARN] partner call not sent to the players: " .. tostring(NetChannel))
            end
            return
        end
    end
    if t > FIND_S then finish("the partner's body did not appear", false) end
end

local function stepMerge(r, t)
    local ax, ay, az = aLocation(r)
    local yaw = math.deg(math.atan(ay - r.by, ax - r.bx))
    local held = t - r.foundAt
    local mt = (held - HOLD_S) / MERGE_S
    if mt < 0 then
        r.b:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
        local lift = LIFT * ease(math.min(1, held / LIFT_S))
        r.b:K2_SetActorLocation({ X = r.bx, Y = r.by, Z = r.bz + lift }, false, {}, true)
        return
    end
    mt = math.min(1, mt)
    -- accelerating, so it reads as a shot rather than a glide
    local e = mt * mt
    local x, y = lerp(r.bx, ax, e), lerp(r.by, ay, e)
    local z = lerp(r.bz + LIFT, az, e) + math.sin(mt * math.pi) * 40
    r.b:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true)
    local s = lerp(1, 0.15, e)
    r.b:SetActorScale3D({ X = s, Y = s, Z = s })
    if mt >= 1 then
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

local function tick()
    if not run then
        driving = false
        return true
    end
    tickGameThread()
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
        idA = opts.idA, idB = opts.idB,
    }
    if not driving then
        driving = true
        GameLoop.start(TICK_MS, FusionPartner._tick, "partner scene")
    end
    Log("partner scene started (" .. tostring(opts.idB) .. ")")
    return true
end

return FusionPartner
