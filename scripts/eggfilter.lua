-- Palvolve egg filter: eggs only ever hatch BASE forms. Evolved/adapted
-- species inside an egg are normalized back to their base species right
-- before the hatched character is obtained (server-side pre-hook), so the
-- mod-exclusive forms stay exclusive to the evolution flow.
--
-- Mechanism: the hatching model carries the hatched pal's save parameter;
-- rewriting its CharacterID (the same FName property write the evolution
-- swap uses) makes the game create the base form while every other rolled
-- stat (talents, passives, gender) stays untouched. Both the single-egg
-- incubator model and the multi-slot base variant are covered.

local Config = require("config")

local EggFilter = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- Rewrites one save-parameter struct; returns "old>new" when it changed
local function normalize(saveParam)
    local changed = nil
    pcall(function()
        local id = saveParam.CharacterID:ToString()
        local base = Config.baseFormOf(id)
        if base and base ~= id then
            saveParam.CharacterID = FName(base)
            changed = id .. " -> " .. base
        end
    end)
    return changed
end

local function normalizeModel(model)
    local changes = {}
    -- single incubator: one hatched parameter on the model
    pcall(function()
        local c = normalize(model.HatchedCharacterSaveParameter)
        if c then table.insert(changes, c) end
    end)
    -- multi-slot base variant: per-slot rep and save infos
    pcall(function()
        local items = model.RepInfoArray.Items
        for i = 1, #items do
            pcall(function()
                local c = normalize(items[i].HatchedCharacterSaveParameter)
                if c then table.insert(changes, c) end
            end)
            pcall(function()
                -- no IsValid() gate: PalEggData may marshal as a struct
                -- rather than a UObject; normalize() is pcall-safe anyway
                local egg = items[i].PalEggData
                if egg then
                    local c1 = normalize(egg)                 -- CharacterID on the item
                    if c1 then table.insert(changes, c1) end
                    pcall(function()
                        local c2 = normalize(egg.SaveParameter)
                        if c2 then table.insert(changes, c2) end
                    end)
                end
            end)
        end
    end)
    pcall(function()
        local infos = model.TmpSaveInfoArray
        for i = 1, #infos do
            pcall(function()
                local c = normalize(infos[i].HatchedCharacterSaveParameter)
                if c then table.insert(changes, c) end
            end)
        end
    end)
    if #changes > 0 then
        Log("Egg filter: normalized " .. table.concat(changes, ", "))
    elseif Config.devMode then
        Log("[probe-eggfill] hatch hook fired, nothing to normalize")
    end
end

function EggFilter.init()
    if not (Config.eggFilter and Config.eggFilter.enabled) then return end

    local hooks = {
        "/Script/Pal.PalMapObjectHatchingEggModelBase:ObtainHatchedCharacter_ServerInternal",
        "/Script/Pal.PalMapObjectHatchingEggModel:ObtainHatchedCharacter_ServerInternal",
    }
    local registered = {}
    local function tryHooks()
        local allOk = true
        for _, path in ipairs(hooks) do
            if not registered[path] then
                local ok = pcall(RegisterHook, path, function(self)
                    pcall(function() normalizeModel(self:get()) end)
                end)
                registered[path] = ok
                allOk = allOk and ok
            end
        end
        return allOk
    end
    if not tryHooks() then
        -- BP-adjacent classes may load late; retry like the level-up hook
        LoopAsync(5000, function()
            local done = false
            ExecuteInGameThread(function() done = tryHooks() end)
            return done
        end)
    end
    Log("Egg filter active: eggs hatch base forms only")
end

return EggFilter
