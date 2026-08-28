-- Palvolve bench visual: the Pal Alchemy Workbench reuses the vanilla medieval
-- medicine workbench blueprint, so placed instances get a teal tint to stand
-- apart from the real thing. Instances are recognized by their data row id
-- (Model.MapObjectMasterDataId / BuildObjectId == our PalSchema row), never
-- by class - the class is shared with vanilla benches.

local Config = require("config")
local ServerCheck = require("servercheck")

local BenchVisual = {}

local ROW_ID = "Palvolve_ElementExtractor"
-- optional diagnostics: logs mesh/material names of our bench for tint debugging
local PROBE = false
-- teal accent, matches the mod's stone/branding palette
local TINT = { R = 0.12, G = 0.55, B = 0.60, A = 1.0 }
-- tint parameters of the bench materials' parent (M_PalLit): "BaseColor"
-- multiplies the base texture, "ChangeColor" + "ChangeColor Rate" drive the
-- game's own recolor system. Setting a parameter that does not exist on a
-- material is a harmless no-op.
local VECTOR_PARAMS = { "BaseColor", "ChangeColor" }
local SCALAR_PARAMS = { ["ChangeColor Rate"] = 0.6 }

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

--- Named body, called once per build object. See the note on getSelf below:
--- an anonymous closure here is allocated for every object in the base.
local function readIsOurBench(actor)
    if not (actor and actor:IsValid()) then return false end
    local direct = actor.BuildObjectId
    if direct and direct.ToString and direct:ToString() == ROW_ID then
        return true
    end
    local model = actor:GetModel()
    if model and model:IsValid() then
        local master = model.MapObjectMasterDataId
        local build = model.BuildObjectId
        if (master and master.ToString and master:ToString() == ROW_ID)
            or (build and build.ToString and build:ToString() == ROW_ID) then
            return true
        end
    end
    return false
end

local function readMasterId(actor)
    local model = actor:GetModel()
    if not (model and model:IsValid()) then return nil end
    local master = model.MapObjectMasterDataId
    if master and master.ToString then return master:ToString() end
    return nil
end

local function isOurBench(actor)
    local ok, found = pcall(readIsOurBench, actor)
    return ok and found == true
end

-- TArrays returned from UFunctions hand out RemoteUnrealParam wrappers on
-- indexing - unwrap before calling UObject methods on the element
local function unwrap(elem)
    if elem and type(elem) == "userdata" and elem.get then
        return elem:get()
    end
    return elem
end

local function tintActor(actor)
    local ok, err = pcall(function()
        local meshClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
        if not (meshClass and meshClass:IsValid()) then
            Log("bench tint: StaticMeshComponent class not found")
            return
        end
        local meshes = actor:K2_GetComponentsByClass(meshClass)
        local count = meshes and #meshes or 0
        if PROBE or Config.devMode then
            Log(string.format("bench tint: %d static mesh components on %s",
                count, actor:GetFName():ToString()))
        end
        if count == 0 and (PROBE or Config.devMode) then
            -- the visuals may live on other component types (or on a child
            -- actor entirely) - list what the actor actually carries
            local allClass = StaticFindObject("/Script/Engine.ActorComponent")
            local comps = actor:K2_GetComponentsByClass(allClass)
            local total = comps and #comps or 0
            Log(string.format("bench tint: %d total components", total))
            for i = 1, math.min(total, 30) do
                local c = unwrap(comps[i])
                if c and c:IsValid() then
                    Log(string.format("bench tint: comp[%d]=%s (%s)", i,
                        c:GetFName():ToString(), c:GetClass():GetFName():ToString()))
                end
            end
        end
        -- the game already assigns MaterialInstanceDynamic objects to placed
        -- build objects, so the tint parameters are set DIRECTLY on those
        -- per-instance MIDs (parameters resolve through the parent chain up
        -- to M_PalLit). Never wrap the runtime MID in another MID - that
        -- loses the texture overrides and renders the mesh untextured.
        local midClass = StaticFindObject("/Script/Engine.MaterialInstanceDynamic")
        local kismet = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
        for i = 1, count do
            local mesh = unwrap(meshes[i])
            if mesh and mesh:IsValid() then
                local mats = mesh:GetMaterials()
                local matCount = mats and #mats or 0
                for m = 1, matCount do
                    local mat = unwrap(mats[m])
                    if mat and mat:IsValid() then
                        local isMid = midClass and midClass:IsValid() and mat:IsA(midClass)
                        if not isMid and kismet and kismet:IsValid() then
                            -- static slot: create a MID from the constant
                            -- instance and assign it immediately (unassigned
                            -- MIDs are garbage collected within a minute)
                            local okMid, made = pcall(makeMid, kismet, actor, mat, mesh, m - 1)
                            if okMid and made then
                                mat = made
                                isMid = true
                            end
                            if not okMid and (PROBE or Config.devMode) then
                                Log(string.format("bench tint: MID creation failed for slot %d", m - 1))
                            end
                        end
                        if isMid then
                            -- Named, and it matters here more than anywhere: this
                            -- is per object, per mesh, per material slot, per
                            -- parameter. A base full of benches used to allocate
                            -- thousands of closures while the world streamed in.
                            for _, param in ipairs(VECTOR_PARAMS) do
                                pcall(setVectorParam, mat, param)
                            end
                            for param, value in pairs(SCALAR_PARAMS) do
                                pcall(setScalarParam, mat, param, value)
                            end
                            if PROBE or Config.devMode then
                                Log(string.format("bench tint: set on slot %d (%s)",
                                    m - 1, mat:GetFName():ToString()))
                            end
                        end
                    end
                end
            end
        end
    end)
    if not ok then
        Log(string.format("bench tint: failed: %s", tostring(err)))
    end
end

-- The model (and with it the row id) arrives via replication after the actor
-- constructs, so candidates are queued and retried from a single LoopAsync.
-- ExecuteWithDelay is avoided on purpose - its transient callback refs get
-- garbage collected under load ("Ref was not function"), which can free
-- every deferred callback of the mod at once.
local MAX_TRIES = 8

-- returns true when the entry is finished (tinted or not ours), false when
-- the actor's row id is not readable yet and the entry should be retried
local function handleActor(actor)
    if not (actor and actor:IsValid()) then return true end
    local okId, id = pcall(readMasterId, actor)
    if not okId then id = nil end
    if id == nil or id == "" or id == "None" then return false end
    -- host has no Palvolve: skip the tint (the extractor bench is not a real thing
    -- this session, so leave the shared vanilla bench untouched)
    if isOurBench(actor) and not ServerCheck.blocked() then
        tintActor(actor)
        if PROBE or Config.devMode then Log("bench tint: attempting on Pal Alchemy Workbench instance") end
    end
    return true
end

-- Named, because it is called from a hook body that runs per build object.
local function getSelf(selfParam) return selfParam:get() end

local function makeMid(kismet, actor, mat, mesh, slot)
    local mid = kismet:CreateDynamicMaterialInstance(actor, mat, FName(""), 0)
    if not (mid and mid:IsValid()) then return nil end
    mesh:SetMaterial(slot, mid)
    return mid
end

local function setVectorParam(mat, param) mat:SetVectorParameterValue(FName(param), TINT) end
local function setScalarParam(mat, param, value) mat:SetScalarParameterValue(FName(param), value) end

function BenchVisual.init()
    local pending = {}
    local swept = false

    NotifyOnNewObject("/Script/Pal.PalBuildObject", function(actor)
        pending[#pending + 1] = { actor = actor, tries = 0 }
    end)

    -- Freshly BUILT benches: the construction-to-finished transition swaps the
    -- meshes and their materials, which discards any tint applied during the
    -- build phase. Re-queue the actor when the game signals completion; the
    -- delay ticks let the swap and the completion animation settle before the
    -- loop re-reads the (new) materials. Three hooks cover every role:
    -- the multicast FX call (host + clients), the replicated state flip
    -- (clients, in case the FX call is suppressed) and the server-internal
    -- finish (host, same reason). The tint is idempotent, duplicates are fine.
    local function queueRetint(actor)
        if actor and actor:IsValid() then
            pending[#pending + 1] = { actor = actor, tries = 0, delay = 3 }
        end
    end

    -- ONE hook body, named, shared by all three paths.
    --
    -- It used to be a fresh closure per hook wrapping a second closure per call,
    -- which is the allocation UE4SS-LESSONS.md rule 2 forbids in anything that
    -- runs per spawn. Every build object in a base flips state while a world
    -- loads, so this is one of the busiest dispatch sites in the mod.
    local function onBuildComplete(selfParam)
        local ok, actor = pcall(getSelf, selfParam)
        if ok then queueRetint(actor) end
    end

    -- Which of these fire depends on the role, and a LISTEN HOST is the one case
    -- where all three do: it is the authority and the drawing client at once. A
    -- dedicated server never runs the multicast, a remote client never runs the
    -- server-internal finish. Singleplayer runs the lot, so it sees three times
    -- the dispatch of anything that was ever tested against a server.
    local COMPLETION_HOOKS = {
        "/Script/Pal.PalBuildObject:PlayBuildCompleteFX_ToALL",
        "/Script/Pal.PalBuildObject:OnRep_CurrentState",
        "/Script/Pal.PalBuildObject:OnFinishBuildWork_ServerInternal",
    }
    for _, path in ipairs(COMPLETION_HOOKS) do
        local ok = pcall(RegisterHook, path, onBuildComplete)
        if not ok and Config.devMode then
            Log(string.format("bench tint: completion hook failed: %s", path))
        end
    end

    LoopAsync(1000, function()
        -- idle ticks must not enter the game thread: every ExecuteInGameThread
        -- call registers a transient callback ref, and UE4SS's callback GC
        -- occasionally frees such refs while still scheduled
        if swept and #pending == 0 then return false end
        ExecuteInGameThread(function()
            pcall(function()
                if not swept then
                    -- benches already placed when the mod loads
                    swept = true
                    local objs = FindAllOf("PalBuildObject") or {}
                    for _, bo in ipairs(objs) do
                        pending[#pending + 1] = { actor = bo, tries = 0 }
                    end
                end
                if #pending == 0 then return end
                local batch = pending
                pending = {}
                for _, entry in ipairs(batch) do
                    if entry.delay and entry.delay > 0 then
                        -- completion re-tints wait out the mesh swap and the
                        -- build-complete animation before touching materials
                        entry.delay = entry.delay - 1
                        pending[#pending + 1] = entry
                    else
                        -- pcall(namedFn, arg): one per queued object per tick,
                        -- and the initial sweep queues every build object in the
                        -- base at once.
                        local ok, done = pcall(handleActor, entry.actor)
                        if ok and done == nil then done = true end
                        if not (ok and done) then
                            entry.tries = entry.tries + 1
                            if entry.tries < MAX_TRIES then
                                pending[#pending + 1] = entry
                            end
                        end
                    end
                end
            end)
        end)
        return false
    end)
end

return BenchVisual
