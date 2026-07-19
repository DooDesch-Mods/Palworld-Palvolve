-- Palvolve "never evolve" opt-out.
--
-- A per-Pal flag, keyed by the Pal's stable individual GUID, that disables all
-- evolution for that specific Pal and suppresses its ready glow. It backs the
-- radial "Never Evolve" / "Allow Evolve" toggle.
--
-- This module owns only the flag set, its persistence, and the summoned-pal
-- helpers shared by the glow and the menu wrapper. Enforcement itself lives at
-- the core's evolve chokepoint (performEvolution) and in findEligibleFor, so
-- every path (radial, F2 confirm, network) is covered - see evolution.lua.

local Role = require("role")

local NeverEvolve = {}

local function Log(msg) print(string.format("[Palvolve] neverevolve: %s\n", msg)) end

-- ---------------------------------------------------------------- identity

local function guidString(g)
    return string.format("%08X-%08X-%08X-%08X", g.A, g.B, g.C, g.D)
end

-- Stable per-Pal key. IndividualId.InstanceId survives an in-place species
-- swap, so a blocked Pal stays blocked by identity, not by species.
function NeverEvolve.keyFor(param)
    local key = nil
    pcall(function() key = guidString(param.IndividualId.InstanceId) end)
    if not key then pcall(function() key = param:GetFullName() end) end
    return key
end

-- ---------------------------------------------------------------- persistence

local blocked = {} -- [guidString] = true

local stateFile = (function()
    local base = os.getenv("LOCALAPPDATA")
    if not base then return nil end
    return base .. "\\Pal\\Saved\\Palvolve\\neverevolve.txt"
end)()

local function load()
    if not stateFile then return end
    local f = io.open(stateFile, "r")
    if not f then return end
    for line in f:lines() do
        local k = line:gsub("%s+$", "")
        if #k > 0 then blocked[k] = true end
    end
    f:close()
end

local function save()
    if not stateFile then return end
    pcall(function()
        local f = io.open(stateFile, "w")
        if not f then return end
        for k in pairs(blocked) do f:write(k, "\n") end
        f:close()
    end)
end

-- ---------------------------------------------------------------- flag api

function NeverEvolve.isBlockedKey(key)
    return key ~= nil and blocked[key] == true
end

function NeverEvolve.isBlocked(param)
    return NeverEvolve.isBlockedKey(param and NeverEvolve.keyFor(param))
end

function NeverEvolve.setBlockedKey(key, on)
    if not key then return end
    blocked[key] = on and true or nil
    save()
end

-- ---------------------------------------------------------------- summoned pal

local otomoHolderClass = nil

local function paramOf(actor)
    local param = nil
    pcall(function() param = actor.CharacterParameterComponent:GetIndividualParameter() end)
    if param and param:IsValid() then return param end
    return nil
end

function NeverEvolve.summoned(playerCtx)
    playerCtx = playerCtx or Role.localPlayerCtx()
    local pc = playerCtx and playerCtx.pc
    if not (pc and pc:IsValid()) then return nil end
    local holder = nil
    pcall(function()
        if not (otomoHolderClass and otomoHolderClass:IsValid()) then
            otomoHolderClass = StaticFindObject("/Script/Pal.PalOtomoHolderComponentBase")
        end
        if otomoHolderClass then
            local h = pc:GetComponentByClass(otomoHolderClass)
            if h and h:IsValid() then holder = h end
        end
    end)
    if not holder then
        pcall(function()
            local util = StaticFindObject("/Script/Pal.Default__PalUtility")
            if util and util:IsValid() then holder = util:GetOtomoHolderComponent(pc) end
        end)
    end
    if not (holder and holder:IsValid()) then return nil end
    local actor = nil
    pcall(function() actor = holder:TryGetSpawnedOtomo() end)
    if not (actor and actor:IsValid()) then return nil end
    return actor, paramOf(actor)
end

local function clearOverlay(actor)
    pcall(function()
        if actor and actor:IsValid() then actor:GetMainMesh():SetOverlayMaterial(nil) end
    end)
end

-- ---------------------------------------------------------------- menu wrappers

function NeverEvolve.wrapListOptions(evo)
    local playerCtx = Role.localPlayerCtx()
    local _, param = NeverEvolve.summoned(playerCtx)
    local opts, reason = evo.listOptions()
    if not param then return opts, reason end
    local key = NeverEvolve.keyFor(param)
    if NeverEvolve.isBlockedKey(key) then
        return { { neverToggle = true, allow = true, palKey = key, label = "Allow Evolve" } }
    end
    if type(opts) ~= "table" then return opts, reason end
    table.insert(opts, { neverToggle = true, allow = false, palKey = key, label = "Disable Evolve" })
    return opts
end

function NeverEvolve.wrapExecuteOption(evo, opt)
    if opt and opt.neverToggle then
        local playerCtx = Role.localPlayerCtx()
        local actor, param = NeverEvolve.summoned(playerCtx)
        local key = (param and NeverEvolve.keyFor(param)) or opt.palKey
        if not key then return end
        if opt.allow then
            NeverEvolve.setBlockedKey(key, false)
            pcall(function() Role.chat(playerCtx, "[Palvolve] Evolutions re-enabled for this Pal.") end)
        else
            NeverEvolve.setBlockedKey(key, true)
            clearOverlay(actor)
            pcall(function() Role.chat(playerCtx, "[Palvolve] This Pal is set to never evolve.") end)
        end
        return
    end
    return evo.executeOption(opt)
end

function NeverEvolve.init()
    load()
    local n = 0
    for _ in pairs(blocked) do n = n + 1 end
    Log(string.format("loaded (%d pal(s) opted out)%s", n,
        stateFile and "" or " [no persistence: LOCALAPPDATA unset]"))
end

return NeverEvolve