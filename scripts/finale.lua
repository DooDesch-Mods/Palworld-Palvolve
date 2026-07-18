-- Palvolve finale runtime: resolves the recipe data from finale_recipes.lua
-- into a precomputed event schedule for the reveal window and pumps it from
-- the EXISTING reveal driver in fx.lua. No LoopAsync of its own in the
-- shipping path and no per-event closures - events are plain tables executed
-- by top-level functions (see Workspace/docs/UE4SS-LESSONS.md on the
-- callback GC). All engine calls are pcall-wrapped; every failure degrades
-- (candidate chain -> hit burst -> NS_Return -> at worst the legacy climax
-- in fx.lua), never breaks the evolution sequence.

local Config = require("config")
local Recipes = require("finale_recipes")

local Finale = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local function finaleCfg()
    local c = Config.finale or {}
    return {
        style = c.style or "layered",
        maxLiveSystems = c.maxLiveSystems or 14,
        debugLog = c.debugLog == true,
    }
end

-- Whether SpawnSystemAtLocation's returned NiagaraComponent marshals into a
-- usable Lua handle in this UE4SS build. nil = unknown (assume yes, kills
-- stay best effort); set by the capture check in probeAll. While this is
-- false, looping candidates are skipped in favor of the first non-looping
-- one in the chain.
Finale.captureOk = nil

-- ---------------------------------------------------------------- asset resolve

-- Paths confirmed absent from the running build: never sync-load these
-- again this session (LoadAsset stalls are the expensive part).
local missing = {}

-- Hot-path hygiene: these run per spawn/per driver tick, so they use NAMED
-- functions with pcall(fn, args) instead of per-call anonymous closures -
-- closure churn in per-tick callbacks feeds UE4SS's callback GC and can
-- corrupt scheduled refs ("Ref was not function").
local niagaraSystemClass = nil
local function findSystemRaw(path)
    local obj = StaticFindObject(path)
    if not (obj and obj:IsValid()) then return nil end
    -- reject redirectors/partially loaded/wrong-class objects before
    -- anything native treats them as a NiagaraSystem
    if not (niagaraSystemClass and niagaraSystemClass:IsValid()) then
        niagaraSystemClass = StaticFindObject("/Script/Niagara.NiagaraSystem")
    end
    if niagaraSystemClass and niagaraSystemClass:IsValid()
        and obj.IsA and obj:IsA(niagaraSystemClass) then
        return obj
    end
    return nil
end

local function findSystem(path)
    local ok, ns = pcall(findSystemRaw, path)
    if ok then return ns end
    return nil
end

-- StaticFindObject -> LoadAsset -> StaticFindObject, with the negative
-- cache in front. Game thread only (sync load).
local function loadSystem(path)
    if missing[path] then return nil end
    local ns = findSystem(path)
    if ns then return ns end
    pcall(LoadAsset, path)
    ns = findSystem(path)
    if not ns then
        missing[path] = true
        Log("[finale] asset missing: " .. path)
    end
    return ns
end

-- Candidate entries are a path string or { path=..., overrides... }.
local function candInfo(c)
    if type(c) == "string" then return { path = c } end
    return c
end

-- Full candidate chain for a spec: moduleOverrides (centerpiece only) ->
-- declared candidates -> element hit burst -> Normal hit burst -> NS_Return.
local function chainFor(spec, elem, slotName)
    local chain = {}
    if slotName == "centerpiece" and elem and Recipes.moduleOverrides[elem] then
        chain[#chain + 1] = candInfo(Recipes.moduleOverrides[elem])
    end
    for _, c in ipairs(spec.candidates or {}) do
        chain[#chain + 1] = candInfo(c)
    end
    if elem and Recipes.hitBursts[elem] then
        chain[#chain + 1] = { path = Recipes.hitBursts[elem] }
    end
    chain[#chain + 1] = { path = Recipes.hitBursts.Normal }
    chain[#chain + 1] = { path = Recipes.RETURN_NS }
    return chain
end

-- Winning candidate per (spec, element), cached for the session. Specs are
-- shared across elements (ACCENTS/RING/CLUSTER), so the cache is keyed by
-- both.
local resolvedCache = {}

local function resolveSpec(spec, elem, slotName)
    local key = elem or ""
    local byElem = resolvedCache[spec]
    if byElem and byElem[key] then return byElem[key] end
    for _, cand in ipairs(chainFor(spec, elem, slotName)) do
        if loadSystem(cand.path) then
            resolvedCache[spec] = resolvedCache[spec] or {}
            resolvedCache[spec][key] = cand
            return cand
        end
    end
    return nil
end

-- ---------------------------------------------------------------- schedule build

-- Mirrors fx.lua digimonCfg (defaults included) - fx cannot be required
-- from here without a cycle.
local function timings()
    local c = Config.digimon or {}
    local growS = math.max(c.growMs or 1600, 1) / 1000
    local holdS = math.max(c.finaleHoldMs or 1800, 0) / 1000
    local totalS = growS + holdS
    local alignS = math.min(0.8, holdS * 0.4)
    return growS, holdS, totalS, totalS - alignS - 0.3
end

local function anchorTime(spec, growS, holdS)
    local at = spec.at or {}
    local base = growS
    if at.anchor == "reveal" then
        base = 0
    elseif at.anchor == "midHold" then
        base = growS + holdS * 0.5
    end
    return base + (at.plus or 0) / 1000
end

-- Expands one spec into concrete events: absolute times, absolute world
-- coordinates, resolved asset path - plain data only. elemCycle (optional,
-- dual-element pals) alternates the burst asset per spawn between the two
-- elements; it only applies to slots without explicit candidates, where the
-- element hit burst carries the look.
local function appendSpec(events, spec, elem, slotName, env, elemCycle)
    if not spec then return end
    local cand = resolveSpec(spec, elem, slotName)
    if not cand then return end
    local killAfterMs = cand.killAfterMs or spec.killAfterMs
    local looping = cand.looping or spec.looping or false
    if looping and (not killAfterMs or Finale.captureOk == false) then
        -- a looping winner needs a kill deadline and working component
        -- capture; otherwise advance to the first non-looping candidate
        -- instead of dropping the slot
        cand = nil
        if not spec.looping then
            for _, c in ipairs(chainFor(spec, elem, slotName)) do
                local ci = candInfo(c)
                if not ci.looping and loadSystem(ci.path) then
                    cand = ci
                    break
                end
            end
        end
        if not cand then
            if env.debugLog then
                Log(string.format("[finale] dropped looping spec %s:%s (capture=%s)",
                    slotName, elem or "base", tostring(Finale.captureOk)))
            end
            return
        end
        killAfterMs = cand.killAfterMs or spec.killAfterMs
    end
    local t0 = anchorTime(spec, env.growS, env.holdS)
    local anchor = spec.at and spec.at.anchor or "grown"
    -- reveal events surround the still-tiny pal near the ground; grown and
    -- midHold events surround the full-size body
    local zBase = (anchor == "reveal") and env.groundZ or env.grownCenterZ
    local count = spec.count or 1
    if (spec.pattern or "center") == "center" then count = 1 end
    local stagger = (spec.stagger or 0) / 1000
    local r = (spec.radius == "fr") and env.fr
        or ((tonumber(spec.radius) or 0) * env.sizeScale)
    r = r * (spec.radiusMul or 1)
    local rise = (spec.rise or 0) * env.sizeScale
    local zOff = 0
    if spec.z == "fzA" then zOff = env.fzA
    elseif spec.z == "fzB" then zOff = env.fzB
    elseif type(spec.z) == "number" then zOff = spec.z * env.sizeScale end
    local rotSpec = cand.rotation or spec.rotation
    local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
    if rotSpec then
        rot = { Pitch = rotSpec.pitch or 0, Yaw = rotSpec.yaw or 0, Roll = rotSpec.roll or 0 }
    end
    local s = cand.scale or spec.scale
    local scale = { X = 1, Y = 1, Z = 1 }
    if type(s) == "number" then
        scale = { X = s, Y = s, Z = s }
    elseif type(s) == "table" then
        scale = { X = s.x or 1, Y = s.y or 1, Z = s.z or 1 }
    end
    local pattern = spec.pattern or "center"
    local dropped = 0
    local alternate = elemCycle and #elemCycle > 1 and not spec.candidates
    for i = 1, count do
        local t = t0 + (i - 1) * stagger
        if t > env.cutoff then
            dropped = dropped + 1
        else
            local evCand, evElem = cand, elem
            if alternate then
                evElem = elemCycle[((i - 1) % #elemCycle) + 1]
                evCand = resolveSpec(spec, evElem, slotName) or cand
            end
            local x, y, z = env.cx, env.cy, zBase + zOff + (i - 1) * rise
            if pattern == "ring" then
                local a = (i - 1) * (2 * math.pi / count)
                x = x + r * math.cos(a)
                y = y + r * math.sin(a)
            elseif pattern == "cluster" then
                -- z-stack centered on the anchor so it frames the body
                z = zBase + zOff * (i - 1 - (count - 1) / 2)
            elseif pattern == "column" then
                -- beam rising from the anchor
                z = zBase + zOff * i
            end
            if env.headZ and z > env.headZ then z = env.headZ end
            events[#events + 1] = {
                t = t, x = x, y = y, z = z,
                path = evCand.path, rot = rot, scale = scale,
                -- kills are clamped to the quiet-zone cutoff so timed
                -- systems stop emitting before the steer-in landing
                killAtT = killAfterMs and math.min(t + killAfterMs / 1000, env.cutoff) or nil,
                label = slotName .. ":" .. (evElem or "base"),
            }
        end
    end
    if dropped > 0 and env.debugLog then
        Log(string.format("[finale] %s:%s dropped %d event(s) past the quiet zone",
            slotName, elem or "base", dropped))
    end
end

local function byTime(a, b) return a.t < b.t end

-- Builds the schedule for one reveal. Returns nil (caller falls back to the
-- legacy climax) when the layered style is off or nothing scheduled.
-- Game thread; ctx as assembled by evolution.lua (worldCtx, oldX/Y/Z,
-- elemsTo, groundZ, collision halves, meshHalfTo, centerAnchored on the MP
-- client, optional finaleRadius/finaleZa/finaleZb overrides).
function Finale.build(ctx)
    local fc = finaleCfg()
    if fc.style ~= "layered" then return nil end
    local built = nil
    pcall(function()
        local growS, holdS, totalS, cutoff = timings()
        -- Vertical anchoring: ctx.groundZ is the engine-measured floor at
        -- the evolution spot (SP); without it the ground derives from the
        -- scaled COLLISION capsule (MP re-anchors oldZ to the new pal's
        -- center and says so via ctx.centerAnchored). The VISIBLE body is
        -- framed by the mesh-space half (ctx.meshHalfTo, the species'
        -- MeshCapsuleHalfHeight) - collision (~30) and mesh (55-270) are
        -- different quantities and must never be mixed.
        local cz = ctx.oldZ or 0
        local oldHalf = (ctx.oldHalf and ctx.oldHalf > 0) and ctx.oldHalf or 30
        local newHalf = (ctx.newHalf and ctx.newHalf > 0) and ctx.newHalf or oldHalf
        local groundZ = ctx.groundZ
            or (ctx.centerAnchored and (cz - newHalf) or (cz - oldHalf))
        local meshHalf = (ctx.meshHalfTo and ctx.meshHalfTo > 0) and ctx.meshHalfTo or 80
        -- Recipe distances are authored for a reference BODY half of 80 and
        -- scale with the target species' visible size, so the composition
        -- frames small and large pals alike. Explicit ctx overrides win
        -- unscaled.
        local sizeScale = math.max(0.5, math.min(meshHalf / 80, 2.5))
        local fzA = ctx.finaleZa; if fzA == nil then fzA = 40 * sizeScale end
        local fzB = ctx.finaleZb; if fzB == nil then fzB = 100 * sizeScale end
        local env = {
            cx = ctx.oldX or 0, cy = ctx.oldY or 0,
            groundZ = groundZ, grownCenterZ = groundZ + meshHalf,
            -- hard ceiling: NOTHING plays above the grown pal's head (an
            -- uncapped reveal beam overshoots tall targets and reads as
            -- detached lights)
            headZ = groundZ + 2 * meshHalf,
            sizeScale = sizeScale,
            fr = ctx.finaleRadius or (80 * sizeScale), fzA = fzA, fzB = fzB,
            growS = growS, holdS = holdS, totalS = totalS, cutoff = cutoff,
            debugLog = fc.debugLog,
        }
        local events = {}
        for _, spec in ipairs(Recipes.base) do
            appendSpec(events, spec, nil, "base", env)
        end
        local e1 = ctx.elemsTo and ctx.elemsTo[1] or nil
        if e1 and (Config.digimon and Config.digimon.elementColors) then
            local e2 = ctx.elemsTo[2] or e1
            local r1 = Recipes.elements[e1] or Recipes.defaultElement
            local r2 = Recipes.elements[e2] or Recipes.defaultElement
            -- dual-element pals: accents/ring alternate both elements per
            -- spawn (e2 leads, e1 owns the centerpiece)
            local cycle = (e2 ~= e1) and { e2, e1 } or nil
            appendSpec(events, r1.centerpiece, e1, "centerpiece", env)
            appendSpec(events, r2.accents, e2, "accents", env, cycle)
            appendSpec(events, r2.ring, e2, "ring", env, cycle)
        end
        if #events == 0 then return end
        table.sort(events, byTime)
        if fc.debugLog then
            Log(string.format(
                "[finale] anchors: oldZ=%.0f collHalves=%.0f/%.0f meshHalf=%.0f groundZ=%.0f grownCenterZ=%.0f sizeScale=%.2f centerAnchored=%s events=%d",
                cz, oldHalf, newHalf, meshHalf, groundZ, env.grownCenterZ, sizeScale,
                tostring(ctx.centerAnchored or false), #events))
        end
        built = {
            events = events, idx = 1, live = {},
            maxLive = fc.maxLiveSystems, debugLog = fc.debugLog, totalS = totalS,
        }
    end)
    return built
end

-- Incremental prewarm. prepare() only QUEUES the slots the upcoming
-- sequence needs (pure Lua, no engine calls); prepareStep() resolves at
-- most ONE candidate chain per call and is pumped from the EXISTING
-- dissolve driver tick in fx.lua. The sync loads therefore spread across
-- the ~5s dissolve instead of bursting in one frame right next to a fresh
-- callback registration (UE4SS callback-GC hygiene). Anything still cold
-- at reveal time is resolved lazily by build/spawn.
local prepareQueue = {}

function Finale.prepare(elemsFrom, elemsTo)
    prepareQueue = {}
    if finaleCfg().style ~= "layered" then return end
    for _, spec in ipairs(Recipes.base) do
        prepareQueue[#prepareQueue + 1] = { spec = spec, elem = nil, slot = "base" }
    end
    for _, elem in ipairs(elemsTo or {}) do
        local rec = Recipes.elements[elem] or Recipes.defaultElement
        prepareQueue[#prepareQueue + 1] = { spec = rec.centerpiece, elem = elem, slot = "centerpiece" }
        prepareQueue[#prepareQueue + 1] = { spec = rec.accents, elem = elem, slot = "accents" }
        prepareQueue[#prepareQueue + 1] = { spec = rec.ring, elem = elem, slot = "ring" }
    end
end

-- One queue item per call; game thread (the dissolve tick).
function Finale.prepareStep()
    local item = table.remove(prepareQueue)
    if not item then return end
    pcall(resolveSpec, item.spec, item.elem, item.slot)
    if #prepareQueue == 0 and finaleCfg().debugLog then
        Log("[finale] prewarm queue drained")
    end
end

-- ---------------------------------------------------------------- spawn + kill

-- Spawns one event via the proven SpawnSystemAtLocation pattern (renders on
-- MP client proxies, unlike component VFX) and returns the NiagaraComponent
-- when the binding hands one back. Game thread; named executors, no
-- per-spawn closures.
local function doSpawn(worldCtx, ev)
    local ns = loadSystem(ev.path)
    local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not (ns and lib and lib:IsValid() and worldCtx and worldCtx:IsValid()) then
        return nil
    end
    return lib:SpawnSystemAtLocation(worldCtx, ns,
        { X = ev.x, Y = ev.y, Z = ev.z },
        ev.rot or { Pitch = 0, Yaw = 0, Roll = 0 },
        ev.scale or { X = 1, Y = 1, Z = 1 },
        true, true, 0, false)
end

local function compIsValid(comp)
    return comp ~= nil and comp:IsValid()
end

local function spawnEvent(worldCtx, ev)
    local okS, comp = pcall(doSpawn, worldCtx, ev)
    if not (okS and comp) then return nil end
    local okV, valid = pcall(compIsValid, comp)
    if okV and valid then return comp end
    return nil
end

local function callDeactivate(comp)
    if comp and comp:IsValid() then comp:Deactivate() end
end

local function callDestroy(comp)
    if comp and comp:IsValid() then comp:K2_DestroyComponent(comp) end
end

-- Graceful end for a timed system: stop emitting and let bAutoDestroy
-- (passed at spawn) reap it once the remaining particles die.
local function fadeComp(comp)
    pcall(callDeactivate, comp)
end

-- Hard teardown for aborts: deactivate AND destroy.
local function killComp(comp)
    pcall(callDeactivate, comp)
    pcall(callDestroy, comp)
end

local function compGone(comp)
    return not comp:IsValid()
end

-- One call per driver tick (fx.lua reveal driver, already on the game
-- thread). t = seconds since reveal. Spawns everything due and sweeps
-- timed-out live systems.
function Finale.pump(ctx, f, t)
    if not f then return end
    local evs = f.events
    while f.idx <= #evs and evs[f.idx].t <= t do
        local ev = evs[f.idx]
        f.idx = f.idx + 1
        if ev.killAtT and #f.live >= f.maxLive then
            -- would exceed the tracked-live cap: skip instead of leaking an
            -- unkillable system
            if f.debugLog then
                Log(string.format("[finale] skipped %s (live cap %d)", ev.label, f.maxLive))
            end
        else
            local comp = spawnEvent(ctx.worldCtx, ev)
            if f.debugLog then
                Log(string.format("[finale] t=%.2f %s z=%.0f %s comp=%s",
                    t, ev.label, ev.z, ev.path, comp and "yes" or "no"))
            end
            -- track EVERY captured component (untimed ones with an infinite
            -- deadline) so stopAll can tear down whatever is still playing
            -- on an abort; naturally finished systems auto-destroy and are
            -- pruned below
            if comp and #f.live < f.maxLive then
                f.live[#f.live + 1] = { comp = comp, killAtT = ev.killAtT or math.huge }
            end
        end
    end
    for i = #f.live, 1, -1 do
        local entry = f.live[i]
        local okG, gone = pcall(compGone, entry.comp)
        if okG and gone then
            table.remove(f.live, i)
        elseif t >= entry.killAtT then
            fadeComp(entry.comp)
            table.remove(f.live, i)
        end
    end
end

-- Ends a schedule: no further spawns, every tracked system torn down.
-- Called on completion, abort and cleanup - idempotent.
function Finale.stopAll(f)
    if not f then return end
    f.idx = #f.events + 1
    for i = #f.live, 1, -1 do
        killComp(f.live[i].comp)
        f.live[i] = nil
    end
end

-- ---------------------------------------------------------------- dev helpers

-- Resolves every slot of every element and logs a per-slot verdict, then
-- checks whether component capture works (spawns one NS_Return). Returns
-- tallies so the probe can echo a summary into the in-game chat. devMode
-- probe (F1); game thread.
function Finale.probeAll(worldCtx, x, y, z)
    local names = {}
    for name in pairs(Recipes.elements) do names[#names + 1] = name end
    table.sort(names)
    local showyOk, fallback, missing = 0, 0, 0
    for _, elem in ipairs(names) do
        local rec = Recipes.elements[elem]
        for _, slotName in ipairs({ "centerpiece", "accents", "ring" }) do
            local spec = rec[slotName]
            for _, c in ipairs((spec and spec.candidates) or {}) do
                local cand = candInfo(c)
                local found = loadSystem(cand.path)
                if not found then missing = missing + 1 end
                Log(string.format("[probe-finale-assets] %s %s candidate %s: %s",
                    elem, slotName, cand.path, found and "OK" or "MISSING"))
            end
            local winner = spec and resolveSpec(spec, elem, slotName)
            local verdict = "UNRESOLVED"
            if winner then
                if winner.path == Recipes.hitBursts[elem] or winner.path == Recipes.hitBursts.Normal then
                    verdict = "FALLBACK hit burst"
                    if spec.candidates then fallback = fallback + 1 end
                elseif winner.path == Recipes.RETURN_NS then
                    verdict = "FALLBACK NS_Return"
                    fallback = fallback + 1
                else
                    verdict = "OK " .. winner.path
                    showyOk = showyOk + 1
                end
            end
            Log(string.format("[probe-finale-assets] %s %s -> %s", elem, slotName, verdict))
        end
    end
    local comp = spawnEvent(worldCtx, { path = Recipes.RETURN_NS, x = x, y = y, z = z })
    Finale.captureOk = comp ~= nil
    Log(string.format("[probe-finale-assets] component capture: %s",
        Finale.captureOk and "OK (looping specs allowed)" or "FAIL (looping specs disabled)"))
    return { showyOk = showyOk, fallback = fallback, missing = missing,
        captureOk = Finale.captureOk }
end

local function shortName(path)
    if not path then return "?" end
    return path:match("([^/]+)%.[^.]+$") or path
end

-- One compact line describing which asset won each slot for the given
-- element list - the dev probes echo it into the in-game chat so a tester
-- sees what is playing without the log. Game thread (resolves through the
-- same session cache as a real sequence).
function Finale.describeSchedule(elems)
    if finaleCfg().style ~= "layered" then return "legacy finale (style=legacy)" end
    local e1 = elems and elems[1]
    if not e1 then return "no elements" end
    local e2 = elems[2] or e1
    local r1 = Recipes.elements[e1] or Recipes.defaultElement
    local r2 = Recipes.elements[e2] or Recipes.defaultElement
    local piece = resolveSpec(r1.centerpiece, e1, "centerpiece")
    local head = string.format("center %s: %s", e1, shortName(piece and piece.path))
    if e2 ~= e1 then
        local b2 = resolveSpec(r2.accents, e2, "accents")
        local b1 = resolveSpec(r2.accents, e1, "accents")
        return string.format("%s | accents/ring alternate %s+%s: %s / %s",
            head, e2, e1, shortName(b2 and b2.path), shortName(b1 and b1.path))
    end
    local accents = resolveSpec(r2.accents, e2, "accents")
    local ring = resolveSpec(r2.ring, e2, "ring")
    return string.format("%s | accents/ring %s: %s / %s",
        head, e2, shortName(accents and accents.path), shortName(ring and ring.path))
end

-- Plays one finale schedule standalone at a world location, without an
-- evolution. devMode probe. halfHeight (the sample pal's capsule half)
-- feeds the same anchoring/species scaling as a real sequence. Driven by a
-- hard-bounded one-shot LoopAsync with an idle guard: ticks without due
-- work never enter the game thread, and the loop always terminates by the
-- deadline.
function Finale.playStandalone(worldCtx, x, y, z, elems, halfHeight, meshHalf)
    local ctx = { worldCtx = worldCtx, oldX = x, oldY = y, oldZ = z, elemsTo = elems,
        oldHalf = halfHeight, newHalf = halfHeight, meshHalfTo = meshHalf }
    local f = Finale.build(ctx)
    if not f then
        Log("[finale] standalone: nothing to play (style/config)")
        return
    end
    local startedAt = os.clock()
    local deadline = f.totalS + 4.0
    local state = { stopped = false }
    LoopAsync(33, function()
        if state.stopped then return true end
        local t = os.clock() - startedAt
        if t > deadline or (f.idx > #f.events and #f.live == 0) then
            state.stopped = true
            ExecuteInGameThread(function() Finale.stopAll(f) end)
            return true
        end
        local dueSpawn = f.idx <= #f.events and f.events[f.idx].t <= t
        local dueKill = false
        for i = 1, #f.live do
            local k = f.live[i].killAtT
            if k < math.huge and t >= k then dueKill = true break end
        end
        if dueSpawn or dueKill then
            ExecuteInGameThread(function()
                if not state.stopped then Finale.pump(ctx, f, t) end
            end)
        end
        return false
    end)
end

return Finale
