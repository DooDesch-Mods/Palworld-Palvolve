-- Chat commands: the retail build ships without an in-game console, so
-- maintenance commands travel through the chat box instead ("/palvolve
-- rollback"). PalPlayerState:EnterChat executes on the world authority for
-- every sender, so the same command works in singleplayer, for a co-op host
-- and for clients on dedicated servers. The typed command stays visible as a
-- normal chat line; the response goes back to the sender only.

local Role = require("role")

local ChatCommands = {}

local PREFIX = "/palvolve"

-- resolves the sending player's context from the chatting PlayerState
local function senderCtxOf(ps)
    if not (ps and ps:IsValid()) then return nil end
    local pc = nil
    pcall(function() pc = ps:GetPlayerController() end)
    if not (pc and pc:IsValid()) then
        pcall(function() pc = ps:GetOwner() end)
    end
    return Role.playerCtxFor(pc)
end

-- handlers = { rollback = function(playerCtx) ... end, ... }; unknown
-- subcommands fall back to handlers.help
function ChatCommands.init(handlers)
    return pcall(function()
        RegisterHook("/Script/Pal.PalPlayerState:EnterChat", function(self, msgParam)
            pcall(function()
                local text = ""
                pcall(function() text = msgParam:get():ToString() end)
                if type(text) ~= "string" then return end
                local lower = text:lower()
                if lower:sub(1, #PREFIX) ~= PREFIX then return end
                local ctx = senderCtxOf(self:get())
                if not ctx then return end
                local sub = lower:match("^%S+%s+(%S+)") or "help"
                local handler = handlers[sub] or handlers.help
                if handler then handler(ctx) end
            end)
        end)
    end)
end

return ChatCommands
