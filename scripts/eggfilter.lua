-- Palvolve egg filter: eggs only ever hatch BASE forms. Evolution chains
-- always gate; since v1.7.3 CROSS-SPECIES adaptation edges gate too by
-- default (eggFilter.gateCrossAdaptations - the classification happens in
-- config.lua's eggParents). Same-species element variants are never gated -
-- an egg of a pure element variant hatches unchanged, and a normalized egg
-- may hatch the base in any of its element variants (see Config.baseFormsOf).
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
local Role = require("role")

local EggFilter = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- devMode forensics (v1.7.3): "fired and passed" used to be indistinguishable
-- from "never fired" - the Braloha investigation had to reconstruct the
-- verdict from the map instead of one log line. One line per DISTINCT id
-- (the same egg re-fires its hooks 4+ times across place/finish/hatch, and
-- an egg the filter itself normalized re-enters as its base id), budget-
-- capped so a zoo of distinct species still cannot flood a session.
local passLogBudget = 5
local passLogged = {}
local specialLogBudget = 5
local specialLogged = {}

-- Per-hook fire receipts (v1.7.4): a ready-at-save-load Braloha egg hatched
-- with ZERO filter lines - "which hook actually fires on this path" must be
-- readable from the log, not reconstructed. Budgeted per label; the class
-- name distinguishes Model from ModelBase instances.
local fireLogBudget = {}
local function fireReceipt(label, self)
    if not Config.devMode then return end
    local left = fireLogBudget[label]
    if left == nil then left = 3 end
    if left <= 0 then return end
    fireLogBudget[label] = left - 1
    local cls = "?"
    pcall(function() cls = self:get():GetClass():GetFName():ToString() end)
    Log(string.format("Egg filter: hook %s fired (%s)", label, cls))
end

-- "hook fired but found nothing readable" (v1.7.4): normalizeEgg exits
-- silently on nil/invalid egg data, which made a bypassed collection and an
-- unreadable restored model indistinguishable. One budgeted line per source.
local noEggBudget = 5
local noEggLogged = {}

-- Registration failures were swallowed by pcall with no trace, so a renamed
-- function on a new game build was indistinguishable from a hook that
-- registered and never fired - the same zero-lines ambiguity, one layer
-- down. One devMode line per path, first failure only (retries continue).
local regFailLogged = {}

-- The pass-through line only speaks about ids the MAP knows (from or to,
-- enabled or not): a never-mapped base species passing through is trivially
-- expected and would burn the budget before the one interesting id - a
-- mapped species that passed anyway (disabled edge, classification surprise)
-- - ever logs. Built lazily so it reflects the merged user map.
local mappedIds = nil
local function isMappedId(id)
    if mappedIds == nil then
        mappedIds = {}
        pcall(function()
            for _, p in ipairs(Config.map) do
                if type(p.from) == "string" then mappedIds[p.from] = true end
                if type(p.to) == "string" then mappedIds[p.to] = true end
            end
        end)
    end
    return mappedIds[(tostring(id)):gsub("^BOSS_", "")] == true
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
            local skey = (sid == "") and "<unreadable>" or sid
            if Config.devMode and specialLogBudget > 0 and not specialLogged[skey] then
                specialLogged[skey] = true
                specialLogBudget = specialLogBudget - 1
                Log(string.format("Egg filter: special/unreadable egg untouched (StaticId=%s)", skey))
            end
            return
        end
        local eggId = eggData.CharacterID:ToString()
        local base = pickBase(eggId)
        if not base and Config.devMode and passLogBudget > 0
            and not passLogged[eggId] and isMappedId(eggId) then
            passLogged[eggId] = true
            passLogBudget = passLogBudget - 1
            Log(string.format("Egg filter: pass-through %s (no gated ancestry)", eggId))
        end
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
    local sawAny = false
    -- single incubator: HatchedPalEggData is the hatch source, and the model's
    -- HatchedCharacterSaveParameter is the replicated copy the notification reads
    pcall(function()
        local egg = model.HatchedPalEggData
        if egg and egg:IsValid() then sawAny = true end
        local c = normalizeEgg(egg, model.HatchedCharacterSaveParameter)
        if c then table.insert(changes, c) end
    end)
    -- multi-slot base variant: one egg per RepInfoArray slot
    pcall(function()
        local items = model.RepInfoArray.Items
        for i = 1, #items do
            pcall(function()
                local egg = items[i].PalEggData
                if egg and egg:IsValid() then sawAny = true end
                local c = normalizeEgg(egg, items[i].HatchedCharacterSaveParameter)
                if c then table.insert(changes, c) end
            end)
        end
    end)
    if #changes > 0 then
        Log(string.format("Egg filter: normalized %s", table.concat(changes, ", ")))
    elseif not sawAny and source ~= "load-sweep"
        and Config.devMode and noEggBudget > 0 and not noEggLogged[source] then
        -- fired, but neither model shape yielded a readable egg - the
        -- restored-incubator suspect the Braloha bypass investigation named.
        -- The load sweep is exempt: an EMPTY incubator is its normal case,
        -- and its own done-line already reports the count.
        noEggLogged[source] = true
        noEggBudget = noEggBudget - 1
        Log(string.format("Egg filter: hook %s saw no readable egg data", source))
    end
end

-- One-shot load sweep (v1.7.4): eggs restored from a save may already be
-- past every hookable moment (finish fired pre-save; the single-slot Model
-- class exposes no reflected collection request), so once per session, as
-- soon as a world exists, every live incubator model gets one normalize
-- pass. This is what guarantees "eggs currently incubating or ready to
-- hatch obey the map" - the collection hooks are belt-and-braces after it.
-- Authority-side only: a client's replicated copies are display state.
local function armLoadSweep()
    -- once per WORLD, not per Lua state: a save-and-reload in one game
    -- process keeps this state alive, and the second world's restored eggs
    -- need their own pass (the census world-boundary lesson). The 15s visit
    -- is one FindFirstOf + a name compare - the Palcology world watch runs
    -- the same shape at 10s.
    local sweptWorld = nil
    local candidateWorld = nil
    local authorityWaits = 0
    LoopAsync(15000, function()
        ExecuteInGameThread(function()
            pcall(function()
                -- world gate: GameInstance-ish objects exist on the main
                -- menu, the in-game state does not (census precedent)
                local gs = FindFirstOf("PalGameStateInGame")
                if not (gs and gs:IsValid()) then return end
                local worldId = gs:GetFullName()
                if worldId == sweptWorld then return end
                -- SETTLE before deciding anything: the game state spawns
                -- before the local controller logs in AND before the save
                -- restore finishes spawning map-object models. A first-sight
                -- sweep could read a host as a client or walk a partial
                -- incubator set - either way stamping the world and silently
                -- cancelling its one sweep forever (review catch). First
                -- sighting only starts the clock; the next tick may act.
                if worldId ~= candidateWorld then
                    candidateWorld = worldId
                    authorityWaits = 0
                    return
                end
                if not Role.hasWorldAuthority() then
                    -- transient on a loading host (controller not in yet):
                    -- keep waiting; only a PERSISTENT no is a real client
                    authorityWaits = authorityWaits + 1
                    if authorityWaits < 8 then return end
                    if Config.devMode then
                        Log("Egg filter: load sweep skipped (no world authority - client)")
                    end
                    sweptWorld = worldId
                    return
                end
                local total = 0
                for _, cls in ipairs({ "PalMapObjectHatchingEggModel",
                                       "PalMapObjectHatchingEggModelBase" }) do
                    pcall(function()
                        local all = FindAllOf(cls)
                        if type(all) == "table" then
                            for _, m in ipairs(all) do
                                pcall(function()
                                    if m and m:IsValid() then
                                        total = total + 1
                                        normalizeModel(m, "load-sweep")
                                    end
                                end)
                            end
                        end
                    end)
                end
                if Config.devMode then
                    Log(string.format("Egg filter: load sweep done (%d incubator model(s))", total))
                end
                sweptWorld = worldId
            end)
        end)
        return false
    end)
end

function EggFilter.init()
    if not (Config.eggFilter and Config.eggFilter.enabled) then return end
    pcall(function() math.randomseed(os.time()) end)

    -- {path, label, alsoPost}. ModelBase labels carry "-mb" so the two
    -- classes' receipts and noEgg dedupe keys can never mask one another
    -- (a Model line silencing a ModelBase line was the review catch).
    local hooks = {
        { "/Script/Pal.PalMapObjectHatchingEggModel:OnFinishWorkInServer", "finish", true },
        { "/Script/Pal.PalMapObjectHatchingEggModelBase:OnFinishWorkInServer", "finish-mb", true },
        { "/Script/Pal.PalMapObjectHatchingEggModel:OnUpdateContainerContentInServer", "place", false },
        { "/Script/Pal.PalMapObjectHatchingEggModelBase:OnUpdateContainerContentInServer", "place-mb", false },
        { "/Script/Pal.PalMapObjectHatchingEggModelBase:ObtainHatchedCharacter_ServerInternal", "hatch-mb", false },
        { "/Script/Pal.PalMapObjectHatchingEggModel:ObtainHatchedCharacter_ServerInternal", "hatch", false },
        -- v1.7.4: the UI-facing collection requests. A ready-at-save-load egg
        -- hatched UNFILTERED: its OnFinishWorkInServer fired before the save,
        -- and collection reaches ObtainHatchedCharacter_ServerInternal via a
        -- native C++ call our hook never sees (the Tier-3 trap). These two are
        -- the reflection-routed entry points of that path - the pre-hook
        -- normalizes every slot BEFORE the native builds the pal. ModelBase
        -- ONLY: the single-slot Model class is a SIBLING (both derive from
        -- ConcreteModelBase) and exposes no reflected collection request at
        -- all - the load sweep below is what covers ITS restored eggs.
        { "/Script/Pal.PalMapObjectHatchingEggModelBase:RequestObtainSingleHatchedCharacter", "obtain-one", false },
        { "/Script/Pal.PalMapObjectHatchingEggModelBase:RequestObtainAllHatchedCharacter", "obtain-all", false },
    }
    local registered = {}
    local function tryHooks()
        local allOk = true
        for _, h in ipairs(hooks) do
            local path, label, alsoPost = h[1], h[2], h[3]
            if not registered[path] then
                -- fireReceipt rides inside pcall too: its Log/print is the
                -- one call whose failure modes (output device torn down at
                -- shutdown-time fires) are outside this module's control,
                -- and nothing may unwind into the native dispatcher
                local pre = function(self)
                    pcall(fireReceipt, label, self)
                    pcall(function() normalizeModel(self:get(), label) end)
                end
                local ok
                if alsoPost then
                    local post = function(self)
                        pcall(fireReceipt, label .. "/post", self)
                        pcall(function() normalizeModel(self:get(), label .. "/post") end)
                    end
                    ok = pcall(RegisterHook, path, pre, post)
                else
                    ok = pcall(RegisterHook, path, pre)
                end
                registered[path] = ok
                if not ok and Config.devMode and not regFailLogged[path] then
                    regFailLogged[path] = true
                    -- the label, not the bare function name: Model and
                    -- ModelBase share function names, and a class-ambiguous
                    -- line recreates the masking the -mb labels killed
                    Log(string.format("Egg filter: hook not registered (will retry): %s (%s)",
                        label, path:match("[^:]+$") or path))
                end
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
    armLoadSweep()
    local gateCross = not (Config.eggFilter
        and Config.eggFilter.gateCrossAdaptations == false)
    Log("Egg filter active: eggs hatch base forms ("
        .. (gateCross and "evolution chains + cross-species adaptations"
            or "evolution chains only") .. ")")
end

return EggFilter
