-- Stable dedicated-server presentation for UE4SS builds whose callback GC can
-- invalidate the nested effect drivers used by the full multiplayer cinematic.
-- The authority still performs and saves the evolution; the client only recalls
-- once so the server can replace the pooled actor with the evolved species.
local RemotePresentation = {}

local PASSTHROUGH_MODES = {
    prestigepreview = true,
    prestigeglow = true,
}

function RemotePresentation.consume(kind, phaseInfo, recall)
    if kind == "start" then
        local mode = phaseInfo and phaseInfo.mode or nil
        if PASSTHROUGH_MODES[mode] then return false end
        if type(recall) == "function" then recall() end
        return true
    end
    if kind == "reveal" then return true end
    return false
end

return RemotePresentation
