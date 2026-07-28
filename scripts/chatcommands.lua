-- Chat commands: the retail build ships without an in-game console, so
-- maintenance commands travel through the chat box instead ("!palvolve
-- rollback"). PalPlayerState:EnterChat executes on the world authority for
-- every sender, so the same command works in singleplayer, for a co-op host
-- and for clients on dedicated servers. The typed command stays visible as a
-- normal chat line; the response goes back to the sender only.
--
-- "!" is the documented prefix, "/" still works. A leading slash is the game's
-- own admin sigil: it answers every such line with "You are not an Admin.
-- /AdminPassword <Password>" before any mod sees it. That refusal is emitted
-- inside the chat widget itself, not through Debug_ReceiveCheatCommand_ToClient
-- or SendSystemToPlayerChat, so no Lua hook can suppress it. Hence the same "!"
-- convention the other Palworld command mods use.

local Role = require("role")

local ChatCommands = {}

local NAME = "palvolve"
local SIGILS = { ["!"] = true, ["/"] = true }

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

-- Splits "!palvolve rollback" into its subcommand, nil for anything that is
-- not addressed to this mod.
local function subcommandOf(lower)
    local first = lower:match("^(%S+)")
    if not first then return nil end
    if not SIGILS[first:sub(1, 1)] then return nil end
    if first:sub(2) ~= NAME then return nil end
    return lower:match("^%S+%s+(%S+)") or "help"
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
                local sub = subcommandOf(text:lower())
                if not sub then return end
                local ctx = senderCtxOf(self:get())
                if not ctx then return end
                local handler = handlers[sub] or handlers.help
                if not handler then return end
                -- Run one tick later, outside this hook. A reply sent from
                -- inside the chat frame is swallowed: the handler runs and logs
                -- its answer, but nothing reaches the chat box. Deferring puts
                -- the reply in a normal frame, where it renders.
                local ran = false
                LoopAsync(1, function()
                    if ran then return true end
                    ran = true
                    ExecuteInGameThread(function()
                        -- re-check at the point of use: the sender can be gone
                        -- by the time the deferred stage runs, and a UFunction
                        -- call on a freed controller is a native crash that
                        -- pcall does not catch
                        if not (ctx.pc and ctx.pc:IsValid()) then return end
                        pcall(handler, ctx)
                    end)
                    return true
                end)
            end)
        end)
    end)
end

return ChatCommands
