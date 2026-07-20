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

local function isOurBench(actor)
    local found = false
    pcall(function()
        if not (actor and actor:IsValid()) then return end
        local direct = actor.BuildObjectId
        if direct and direct.ToString and direct:ToString() == ROW_ID then
            found = true
            return
        end
        local model = actor:GetModel()
        if model and model:IsValid() then
            local master = model.MapObjectMasterDataId
            local build = model.BuildObjectId
            if (master and master.ToString and master:ToString() == ROW_ID)
                or (build and build.ToString and build:ToString() == ROW_ID) then
                found = true
            end
        end
    end)
    return found
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
            Log("[probe-bench] StaticMeshComponent class not found")
            return
        end
        local meshes = actor:K2_GetComponentsByClass(meshClass)
        local count = meshes and #meshes or 0
        if PROBE or Config.devMode then
            Log(string.format("[probe-bench] %d static mesh components on %s",
                count, actor:GetFName():ToString()))
        end
        if count == 0 and (PROBE or Config.devMode) then
            -- the visuals may live on other component types (or on a child
            -- actor entirely) - list what the actor actually carries
            local allClass = StaticFindObject("/Script/Engine.ActorComponent")
            local comps = actor:K2_GetComponentsByClass(allClass)
            local total = comps and #comps or 0
            Log(string.format("[probe-bench] %d total components", total))
            for i = 1, math.min(total, 30) do
                local c = unwrap(comps[i])
                if c and c:IsValid() then
                    Log(string.format("[probe-bench] comp[%d]=%s (%s)", i,
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
                            local okMid = pcall(function()
                                local mid = kismet:CreateDynamicMaterialInstance(actor, mat, FName(""), 0)
                                if mid and mid:IsValid() then
                                    mesh:SetMaterial(m - 1, mid)
                                    mat = mid
                                    isMid = true
                                end
                            end)
                            if not okMid and (PROBE or Config.devMode) then
                                Log(string.format("[probe-bench] MID creation failed for slot %d", m - 1))
                            end
                        end
                        if isMid then
                            for _, param in ipairs(VECTOR_PARAMS) do
                                pcall(function()
                                    mat:SetVectorParameterValue(FName(param), TINT)
                                end)
                            end
                            for param, value in pairs(SCALAR_PARAMS) do
                                pcall(function()
                                    mat:SetScalarParameterValue(FName(param), value)
                                end)
                            end
                            if PROBE or Config.devMode then
                                Log(string.format("[probe-bench] tint set on slot %d (%s)",
                                    m - 1, mat:GetFName():ToString()))
                            end
                        end
                    end
                end
            end
        end
    end)
    if not ok then
        Log(string.format("[probe-bench] tint error: %s", tostring(err)))
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
    local id = nil
    pcall(function()
        local model = actor:GetModel()
        if model and model:IsValid() then
            local master = model.MapObjectMasterDataId
            if master and master.ToString then id = master:ToString() end
        end
    end)
    if id == nil or id == "" or id == "None" then return false end
    -- host has no Palvolve: skip the tint (the extractor bench is not a real thing
    -- this session, so leave the shared vanilla bench untouched)
    if isOurBench(actor) and not ServerCheck.blocked() then
        tintActor(actor)
        if PROBE or Config.devMode then Log("[probe-bench] tint attempt on Pal Alchemy Workbench instance") end
    end
    return true
end

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
    local COMPLETION_HOOKS = {
        "/Script/Pal.PalBuildObject:PlayBuildCompleteFX_ToALL",
        "/Script/Pal.PalBuildObject:OnRep_CurrentState",
        "/Script/Pal.PalBuildObject:OnFinishBuildWork_ServerInternal",
    }
    for _, path in ipairs(COMPLETION_HOOKS) do
        local ok = pcall(RegisterHook, path, function(selfParam)
            pcall(function()
                queueRetint(selfParam:get())
            end)
        end)
        if not ok and Config.devMode then
            Log(string.format("[probe-bench] completion hook failed: %s", path))
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
                        local done = true
                        pcall(function() done = handleActor(entry.actor) end)
                        if not done then
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
