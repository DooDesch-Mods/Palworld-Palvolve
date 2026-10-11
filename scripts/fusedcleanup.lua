-- Retire the cosmetic altar marker on the authority as saved Pals enter memory.
local ObjTrack = require("objtrack")
local GameLoop = require("gameloop")
local Role = require("role")
local PalPassives = require("palpassives")

local FusedCleanup = {}
local parameters = nil
local failures = {}

local function Log(msg)
    print(string.format("[Palvolve] [fused cleanup] %s\n", msg))
end

local function readReady(param)
    return param.SaveParameter.IsPlayer, param:GetCharacterID():ToString(), param:GetFullName()
end

local function worldLoaded()
    local manager = ObjTrack.first("PalSaveGameManager")
    return manager ~= nil and manager:IsValid() and manager:IsLoadedWorldData()
end

local function clean(param)
    if not ObjTrack.notDefault(param) then return false end
    if not Role.hasWorldAuthority() then
        local pc = Role.getLocalPlayerController()
        -- A connected client receives the host's cleaned save parameters.
        -- Drop its queue instead of retrying work it can never authorize.
        if pc and pc:IsValid() then return false end
        return nil
    end
    if not worldLoaded() then return nil end
    local ready, isPlayer, species, name = pcall(readReady, param)
    -- Construction notifications precede save restoration. Wait for the next
    -- game-thread drain until this parameter has a species and passive list.
    if not ready then error("saved parameter unreadable: " .. tostring(isPlayer)) end
    if species == nil or species == "" or species == "None" then return nil end
    if isPlayer then return false end
    local ok, changed = PalPassives.removeFusedMarker(param)
    if not ok then
        local reason = tostring(changed)
        local fault = failures[name]
        local now = os.clock()
        if not fault or fault.reason ~= reason or now - fault.at >= 30 then
            Log(string.format("[ERROR] %s: %s%s", name, reason,
                fault and string.format(" (%d attempts)", fault.count + 1) or ""))
            failures[name] = { reason = reason, at = now, count = fault and fault.count + 1 or 1 }
        else
            fault.count = fault.count + 1
        end
        return nil
    end
    if changed or failures[name] then
        Log(string.format("[INFO] %s: Fused marker absent, other passives preserved", name))
    end
    failures[name] = nil
    -- Completed parameters need no further visits. The tracker keeps only
    -- parameters awaiting restoration or a failed removal, including boxed Pals.
    return false
end

local function tick()
    if parameters and Role.hasWorldAuthority() then parameters:list() end
    return false
end

function FusedCleanup.init()
    if parameters then return end
    parameters = ObjTrack.follow("/Script/Pal.PalIndividualCharacterParameter",
        "PalIndividualCharacterParameter", { accept = clean })
    if GameLoop.start(500, tick, "Fused marker cleanup") == nil then
        Log("[ERROR] cleanup loop did not start; queued Pals may retain the Fused marker")
    end
end

return FusedCleanup
