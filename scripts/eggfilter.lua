-- Palvolve egg filter: eggs only ever hatch BASE forms, following EVOLUTION
-- chains only. Element adaptations are never gated - an egg of a pure element
-- variant hatches unchanged, and a normalized egg may hatch the base in any of
-- its element variants (see Config.baseFormsOf).
--
-- Server-side hooks on the incubator model:
--   OnFinishWorkInServer (hatch-complete)   - PRIMARY. The game writes the
--     replicated HatchedCharacterSaveParameter here and the "born" notification
--     reads it, BEFORE the ObtainHatchedCharacter spawn step. Normalizing here
--     (pre + post) fixes both the notification and the hatched Pal.
--   OnUpdateContainerContentInServer (place) - early pass for the incubation
--     display when there is a real hatch window.
--   ObtainHatchedCharacter_ServerInternal    - final safety net for the Pal.
--
-- The base is decided ONCE per egg from the egg-data species (uniform when
-- several bases exist) and written to the hatch source (HatchedPalEggData);
-- the replicated notification copy is then mirrored to that same base, so the
-- notification and the Pal never disagree and no second random roll happens.

local Config = require("config")

local EggFilter = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- Distinct base candidates for an id (self excluded), via the unprefixed id.
local function candidates(originalId)
    local lookupId = originalId:gsub("^BOSS_", "")
    local out = {}
    for _, b in ipairs(Config.baseFormsOf(lookupId)) do
        if b ~= lookupId then table.insert(out, b) end
    end
    return out
end

-- One random base for an original species id; nil = not an evolution target.
local function pickBase(originalId)
    local cand = candidates(originalId)
    local n = #cand
    if n == 0 then return nil end
    if n == 1 then return cand[1] end
    return cand[math.random(n)]
end

local function isTarget(originalId)
    return #candidates(originalId) > 0
end

-- Normalize one egg: decide the base once from the egg-data species and write
-- it to the hatch source, then mirror the replicated notification copy to that
-- same base. Idempotent: once the source is a base, pickBase returns nil and
-- only a stale (still-evolved) notification copy is re-synced. Returns a log
-- fragment or nil.
local function normalizeEgg(eggData, hatchedParam)
    local changed = nil
    pcall(function()
        if not (eggData and eggData:IsValid()) then return end
        -- Never normalize a base-game special egg (mutation / WorldTree). Their
        -- special result is tied to the egg's item type (StaticId), not its
        -- CharacterID, so a species rewrite would silently damage them. Match on
        -- the item id and fail closed when it cannot be read.
        local sid = ""
        pcall(function() sid = eggData.StaticId:ToString() end)
        if sid == "" or sid:find("PalEgg_WorldTree", 1, true) or sid:find("PalEgg_MutationPal", 1, true) then
            return
        end
        local eggId = eggData.CharacterID:ToString()
        local base = pickBase(eggId)
        if base then
            eggData.CharacterID = FName(base)
            pcall(function() eggData.SaveParameter.CharacterID = FName(base) end)
            local after = eggData.CharacterID:ToString()
            changed = eggId .. " -> " .. base
            if after ~= base then changed = changed .. " (could not update egg species, still " .. after .. ")" end
            eggId = base
        end
        -- mirror the notification copy onto the decided base, but only when it
        -- still holds an evolved form (never touch a normal egg's species)
        if hatchedParam then
            pcall(function()
                local hp = hatchedParam.CharacterID:ToString()
                if hp ~= eggId and isTarget(hp) then
                    hatchedParam.CharacterID = FName(eggId)
                    if not changed then changed = hp .. " -> " .. eggId .. " (hatch notification)" end
                end
            end)
        end
    end)
    return changed
end

local function normalizeModel(model, source)
    local changes = {}
    -- single incubator: HatchedPalEggData is the hatch source, and the model's
    -- HatchedCharacterSaveParameter is the replicated copy the notification reads
    pcall(function()
        local c = normalizeEgg(model.HatchedPalEggData, model.HatchedCharacterSaveParameter)
        if c then table.insert(changes, c) end
    end)
    -- multi-slot base variant: one egg per RepInfoArray slot
    pcall(function()
        local items = model.RepInfoArray.Items
        for i = 1, #items do
            pcall(function()
                local c = normalizeEgg(items[i].PalEggData, items[i].HatchedCharacterSaveParameter)
                if c then table.insert(changes, c) end
            end)
        end
    end)
    if #changes > 0 then
        Log(string.format("Egg filter: normalized %s", table.concat(changes, ", ")))
    end
end

function EggFilter.init()
    if not (Config.eggFilter and Config.eggFilter.enabled) then return end
    pcall(function() math.randomseed(os.time()) end)

    -- {path, label, alsoPost}
    local hooks = {
        { "/Script/Pal.PalMapObjectHatchingEggModel:OnFinishWorkInServer", "finish", true },
        { "/Script/Pal.PalMapObjectHatchingEggModelBase:OnFinishWorkInServer", "finish", true },
        { "/Script/Pal.PalMapObjectHatchingEggModel:OnUpdateContainerContentInServer", "place", false },
        { "/Script/Pal.PalMapObjectHatchingEggModelBase:OnUpdateContainerContentInServer", "place", false },
        { "/Script/Pal.PalMapObjectHatchingEggModelBase:ObtainHatchedCharacter_ServerInternal", "hatch", false },
        { "/Script/Pal.PalMapObjectHatchingEggModel:ObtainHatchedCharacter_ServerInternal", "hatch", false },
    }
    local registered = {}
    local function tryHooks()
        local allOk = true
        for _, h in ipairs(hooks) do
            local path, label, alsoPost = h[1], h[2], h[3]
            if not registered[path] then
                local pre = function(self) pcall(function() normalizeModel(self:get(), label) end) end
                local ok
                if alsoPost then
                    local post = function(self) pcall(function() normalizeModel(self:get(), label .. "/post") end) end
                    ok = pcall(RegisterHook, path, pre, post)
                else
                    ok = pcall(RegisterHook, path, pre)
                end
                registered[path] = ok
                allOk = allOk and ok
            end
        end
        return allOk
    end
    if not tryHooks() then
        -- BP-adjacent classes may load late; retry until they register. The
        -- flag lives outside the tick because ExecuteInGameThread only QUEUES
        -- the work - a flag set inside it is written after this tick already
        -- returned, so the next tick is what observes success and ends the loop.
        local hooksDone = false
        LoopAsync(5000, function()
            if hooksDone then return true end
            ExecuteInGameThread(function() hooksDone = tryHooks() end)
            return false
        end)
    end
    Log("Egg filter active: eggs hatch base forms (evolution chains only)")
end

return EggFilter
