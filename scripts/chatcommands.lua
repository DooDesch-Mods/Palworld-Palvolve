-- Chat commands: the retail build ships without an in-game console, so
-- maintenance commands travel through the chat box instead ("!palvolve
-- rollback"). PalPlayerState:EnterChat executes on the world authority for
-- every sender, so the same command works in singleplayer, for a co-op host
-- and for clients on dedicated servers. The typed command stays visible as a
-- normal chat line; the response goes back to the sender only.

local Role = require("role")

local ChatCommands = {}

-- "!" is the primary sigil (upstream 1.4.2): Palworld's own admin system
-- intercepts "/"-prefixed chat before any Lua hook runs and answers "You
-- are not an Admin" on servers - other command mods settled on "!". The
-- "/" form stays for back-compat where the game still lets it through
-- (singleplayer / listen hosts).
local NAME = "palvolve"
local SIGILS = { ["!"] = true, ["/"] = true }

-- exact-token match: the first whitespace token must be sigil+name EXACTLY
-- ("/palvolvefoo" must not trigger - the old prefix match did). Returns the
-- lowercased subcommand, "help" when bare, nil when not ours.
local function subcommandOf(text)
    local first, rest = text:match("^%s*(%S+)%s*(.*)$")
    if not first then return nil end
    if not SIGILS[first:sub(1, 1)] then return nil end
    if first:sub(2):lower() ~= NAME then return nil end
    local sub = rest:match("^(%S+)")
    return (sub and sub:lower()) or "help"
end

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
                local sub = subcommandOf(text)
                if not sub then return end
                local ctx = senderCtxOf(self:get())
                if not ctx then return end
                local handler = handlers[sub] or handlers.help
                if not handler then return end
                -- one tick deferred (upstream 1.4.2): a reply sent from
                -- inside the chat frame is swallowed, and the widget can
                -- free refs the handler holds. Fired-latch one-shot per the
                -- crash-#7 law; controller revalidated on the game thread.
                local fired = false
                LoopAsync(1, function()
                    if fired then return true end
                    fired = true
                    ExecuteInGameThread(function()
                        pcall(function()
                            if ctx.pc and ctx.pc:IsValid() then handler(ctx) end
                        end)
                    end)
                    return true
                end)
            end)
        end)
    end)
end

return ChatCommands
