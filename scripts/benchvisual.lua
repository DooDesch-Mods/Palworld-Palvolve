-- Palvolve bench visual: the Element Extractor reuses the vanilla medieval
-- medicine workbench blueprint, so placed instances get a teal tint to stand
-- apart from the real thing. Instances are recognized by their data row id
-- (Model.MapObjectMasterDataId / BuildObjectId == our PalSchema row), never
-- by class - the class is shared with vanilla benches.

local Config = require("config")

local BenchVisual = {}

local ROW_ID = "Palvolve_ElementExtractor"
-- material probe: logs mesh/material names of our bench so the tint can
-- target real parameter names; flip to false once the tint is verified
local PROBE = true
-- teal accent, matches the mod's stone/branding palette
local TINT = { R = 0.12, G = 0.55, B = 0.60, A = 1.0 }
-- common tint parameter names across Palworld building materials; setting a
-- parameter that does not exist on a material is a harmless no-op
local PARAM_NAMES = { "BaseColor", "Color", "Tint", "MainColor", "ColorA" }

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

local function tintActor(actor)
    pcall(function()
        local meshes = actor:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.StaticMeshComponent"))
        for i = 1, #meshes do
            local mesh = meshes[i]
            if mesh and mesh:IsValid() then
                if PROBE or Config.devMode then
                    pcall(function()
                        local mats = mesh:GetMaterials()
                        for m = 1, #mats do
                            local mat = mats[m]
                            local name = mat and mat:IsValid() and mat:GetFName():ToString() or "nil"
                            local full = ""
                            pcall(function() full = mat:GetFullName() end)
                            Log(string.format("[probe-bench] mesh=%s material[%d]=%s (%s)",
                                mesh:GetFName():ToString(), m, name, full))
                        end
                    end)
                end
                for _, param in ipairs(PARAM_NAMES) do
                    pcall(function()
                        mesh:SetVectorParameterValueOnMaterials(FName(param), TINT)
                    end)
                end
            end
        end
    end)
end

-- The model (and with it the row id) arrives via replication after the actor
-- constructs, so the check runs slightly deferred.
local function onBuildObject(actor)
    ExecuteWithDelay(750, function()
        ExecuteInGameThread(function()
            if isOurBench(actor) then
                tintActor(actor)
                if PROBE or Config.devMode then Log("[probe-bench] tint attempt on Element Extractor instance") end
            end
        end)
    end)
end

function BenchVisual.init()
    NotifyOnNewObject("/Script/Pal.PalBuildObject", function(actor)
        pcall(onBuildObject, actor)
    end)
    -- benches already placed when the mod loads (world load order)
    ExecuteWithDelay(5000, function()
        ExecuteInGameThread(function()
            pcall(function()
                local objs = FindAllOf("PalBuildObject") or {}
                for _, bo in ipairs(objs) do
                    if isOurBench(bo) then tintActor(bo) end
                end
            end)
        end)
    end)
end

return BenchVisual
