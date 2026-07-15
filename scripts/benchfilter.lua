-- Palvolve bench filter: the Pal Alchemy Workbench shares its blueprint class
-- (and therefore its class-default ItemConverterParameter) with the vanilla
-- medieval medicine bench, so both benches would list both recipe sets. The
-- runtime converter model keeps a PER-INSTANCE copy of the target type
-- filters, which this module rewrites in place (no TArray resize needed):
--   Pal Alchemy Workbench   -> accepts only the mod's Palvolve_Craft item type
--   MedicineFacility_01 -> the appended Palvolve_Craft entry is reverted so
--                          the vanilla bench stays a pure medicine bench
--
-- Timing: NotifyOnNewObject only ENQUEUES; a single LoopAsync drains the
-- queue with retries. ExecuteWithDelay is avoided on purpose - its transient
-- callback refs get garbage collected under load ("Ref was not function"),
-- which killed every deferred callback of the mod in one session.
local Config = require("config")

local BenchFilter = {}

local OUR_ID = "Palvolve_ElementExtractor"
local VANILLA_ID = "MedicineFacility_01"
-- probe: logs converter state before/after patching
local PROBE = false
local MAX_TRIES = 8

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local function typesToString(arr)
    local parts = {}
    for i = 1, #arr do parts[#parts + 1] = tostring(arr[i]) end
    return table.concat(parts, ",")
end

local function recipeCount(model)
    local n = 0
    pcall(function() n = #model.RecipeIds end)
    return n
end

-- returns true when the entry is finished (patched or not ours), false when
-- the model is not ready yet and the entry should be retried
local function patchModel(model)
    local done = true
    local ok, err = pcall(function()
        if not (model and model:IsValid()) then return end
        local id = ""
        pcall(function() id = model:TryGetMapObjectId():ToString() end)
        if id == "" or id == "None" then
            -- the map object id arrives via native setup/replication
            done = false
            return
        end
        if id ~= OUR_ID and id ~= VANILLA_ID then return end
        local types = model.TargetTypesB
        local n = #types
        if n == 0 then
            done = false
            return
        end
        if PROBE or Config.devMode then
            Log(string.format("[probe-conv] %s: typesB=[%s] rankMax=%s recipes=%d",
                id, typesToString(types), tostring(model.TargetRankMax), recipeCount(model)))
        end
        -- the appended Palvolve_Craft entry is the LAST one in the class
        -- default list (Medicine, Drug, ConsumeGainStatusPoints, Palvolve_Craft)
        if id == OUR_ID then
            local craftType = types[n]
            for i = 1, n do types[i] = craftType end
        elseif n >= 2 then
            types[n] = types[1]
        end
        if PROBE or Config.devMode then
            Log(string.format("[probe-conv] %s: patched typesB=[%s]", id, typesToString(model.TargetTypesB)))
        end
    end)
    if not ok then
        Log(string.format("[probe-conv] patch error: %s", tostring(err)))
    end
    return done
end

function BenchFilter.init()
    local pending = {}
    local swept = false

    NotifyOnNewObject("/Script/Pal.PalMapObjectConvertItemModel", function(model)
        pending[#pending + 1] = { model = model, tries = 0 }
    end)

    LoopAsync(1000, function()
        -- Only enter the game thread when there is actual work: every
        -- ExecuteInGameThread call registers a transient callback ref, and
        -- UE4SS's callback GC occasionally frees such refs while they are
        -- still scheduled (corrupted closures, in the worst case a silent
        -- process death). Idle ticks must therefore stay ref-free.
        if swept and #pending == 0 then return false end
        ExecuteInGameThread(function()
            pcall(function()
                if not swept then
                    -- converter models of buildings placed before the mod
                    -- loaded (world already running / hot reload)
                    swept = true
                    local models = FindAllOf("PalMapObjectConvertItemModel") or {}
                    for _, m in ipairs(models) do
                        pending[#pending + 1] = { model = m, tries = 0 }
                    end
                    if PROBE or Config.devMode then
                        -- one-shot check whether PalSchema applied our SortId
                        pcall(function()
                            local mgr = FindFirstOf("PalItemIDManager")
                            if mgr and mgr:IsValid() then
                                local data = mgr:GetStaticItemData(FName("Palvolve_EvolutionStone"))
                                if data and data:IsValid() then
                                    Log(string.format("[probe-sortid] Palvolve_EvolutionStone SortId=%s",
                                        tostring(data.SortId)))
                                else
                                    Log("[probe-sortid] item data not found")
                                end
                            else
                                Log("[probe-sortid] no PalItemIDManager")
                            end
                        end)
                    end
                end
                if #pending == 0 then return end
                local batch = pending
                pending = {}
                for _, entry in ipairs(batch) do
                    if not patchModel(entry.model) then
                        entry.tries = entry.tries + 1
                        if entry.tries < MAX_TRIES then
                            pending[#pending + 1] = entry
                        end
                    end
                end
            end)
        end)
        return false
    end)
end

return BenchFilter
