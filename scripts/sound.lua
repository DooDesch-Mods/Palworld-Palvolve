-- sound.lua: posts the game's Wwise events.
--
-- Event assets that no loaded map or menu uses are not in memory, so a missing
-- event is loaded once before it plays. Every call runs on the game thread and
-- reports what it did: a sound that never plays looks exactly like one that
-- played quietly.

local Sound = {}

local function Log(msg)
    print(string.format("[Palvolve] [sound] %s\n", tostring(msg)))
end

local statics = nil
local function ak()
    if not (statics and statics:IsValid()) then
        statics = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics")
    end
    return statics and statics:IsValid() and statics or nil
end

local events = {}
local function event(path)
    local ev = events[path]
    if ev and ev:IsValid() then return ev end
    ev = StaticFindObject(path)
    if not (ev and ev:IsValid()) then
        local okLoad, loaded = pcall(LoadAsset, path)
        if not okLoad then
            Log("[WARN] sound did not load: " .. path .. ": " .. tostring(loaded))
            return nil
        end
        ev = StaticFindObject(path)
    end
    if not (ev and ev:IsValid()) then
        Log("[WARN] sound missing: " .. path)
        return nil
    end
    events[path] = ev
    return ev
end

local function short(path)
    return path:match("([^/.]+)$") or path
end

--- Plays path on actor; the sound follows the actor and, with stopWithActor,
--- ends when the actor is removed. Returns the playing id or nil.
function Sound.onActor(path, actor, stopWithActor)
    local ev, aks = event(path), ak()
    if not (ev and aks) then return nil end
    if not (actor and actor:IsValid()) then
        Log("[WARN] sound " .. short(path) .. " has no actor to play on")
        return nil
    end
    local ok, id = pcall(function() return aks:PostEvent(ev, actor, 0, nil, stopWithActor == true) end)
    if not ok then
        Log("[WARN] sound " .. short(path) .. " failed: " .. tostring(id))
        return nil
    end
    Log("played " .. short(path) .. " (id " .. tostring(id) .. ")")
    return id
end

--- Plays path at a world point. Returns the playing id or nil.
function Sound.at(path, worldCtx, x, y, z)
    local ev, aks = event(path), ak()
    if not (ev and aks) then return nil end
    local ok, id = pcall(function()
        return aks:PostEventAtLocation(ev, { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 }, worldCtx)
    end)
    if not ok then
        Log("[WARN] sound " .. short(path) .. " failed: " .. tostring(id))
        return nil
    end
    Log("played " .. short(path) .. " (id " .. tostring(id) .. ")")
    return id
end

--- Stops everything playing on actor.
function Sound.stopOn(actor)
    local aks = ak()
    if not (aks and actor and actor:IsValid()) then return end
    local ok, err = pcall(function() aks:StopActor(actor) end)
    if not ok then Log("[WARN] sounds on the actor not stopped: " .. tostring(err)) end
end

return Sound
