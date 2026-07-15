-- role.lua: runtime role detection for multiplayer support.
-- First slice: process-static dedicated-server detection. The dedicated
-- server never has a game viewport, but at mod-load time the viewport does
-- not exist on clients either - the ship binary layout is the only signal
-- available this early. The dedicated build lives under "PalServer\Pal\..."
-- (Steam app 2394010), the game client under "Palworld\Pal\..." or a copy
-- of it, so the mod's own script path is a process-static discriminator.
local Role = {}

local isDedicatedCached = nil

function Role.isDedicated()
    if isDedicatedCached ~= nil then return isDedicatedCached end
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    isDedicatedCached = (src:find("PalServer", 1, true) ~= nil)
        or (src:find("palserver", 1, true) ~= nil)
    return isDedicatedCached
end

return Role
