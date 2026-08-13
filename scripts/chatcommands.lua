-- Chat commands: the retail build ships without an in-game console, so
-- maintenance commands travel through the chat box instead ("!palvolve
-- rollback"). The typed command stays visible as a normal chat line; the
-- response goes back to the sender only.
--
-- The hook is PalGameStateInGame:BroadcastChatMessage, which runs on the world
-- authority. Until 1.8.1 this file hooked PalPlayerState:EnterChat and its
-- header claimed that function "executes on the world authority for every
-- sender". It does not: EnterChat runs on the machine where the player types.
-- On a listen host and in singleplayer that machine IS the authority, which is
-- why it always looked right in testing, and on a dedicated server every
-- command ran on the sender's own client against an empty local snapshot list
-- and never reached the host at all.
--
-- The measured carrier table said so all along (SERVER-COMPAT.md, carrier B:
-- "EnterChat -> BroadcastChatMessage", 9/9, sender resolved server side). The
-- broadcast carries SenderPlayerUId, which is the only thing on the authority
-- that points back at who typed it.
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

local function guidStr(g)
    return string.format("%08X-%08X-%08X-%08X", g.A or 0, g.B or 0, g.C or 0, g.D or 0)
end

-- Resolve the sender from the uid the broadcast carries. The authority has no
-- shortcut from a chat message to a controller, so this walks the controllers
-- it owns and matches on PlayerUId - the same identity the evolve path already
-- gates on.
local function senderCtxForUid(uid)
    if not uid then return nil end
    local want = guidStr(uid)
    local found = nil
    pcall(function()
        for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
            if pc and pc:IsValid() then
                local ctx = Role.playerCtxFor(pc)
                if ctx and ctx.playerUId and guidStr(ctx.playerUId) == want then
                    found = ctx
                    return
                end
            end
        end
    end)
    return found
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
        RegisterHook("/Script/Pal.PalGameStateInGame:BroadcastChatMessage", function(_, msgParam)
            pcall(function()
                -- the authority is the only place a command may run: on a
                -- listen host this hook also sees the host's own line, and a
                -- client must never execute one against its local state
                if not Role.hasWorldAuthority() then return end
                local chat = msgParam:get()
                if not chat then return end
                local text = ""
                pcall(function() text = chat.Message:ToString() end)
                if type(text) ~= "string" then return end
                local sub = subcommandOf(text:lower())
                if not sub then return end
                local ctx = nil
                pcall(function() ctx = senderCtxForUid(chat.SenderPlayerUId) end)
                if not ctx then return end
                local handler = handlers[sub] or handlers.help
                if not handler then return end
                -- Run outside this hook. A reply sent from inside the chat
                -- frame is swallowed: the handler runs and logs its answer, but
                -- nothing reaches the chat box. Deferring puts the reply in a
                -- normal frame, where it renders.
                --
                -- 1 ms was enough while this hung off EnterChat. From inside
                -- BroadcastChatMessage it is not: the reply is itself a chat
                -- broadcast, and one emitted while the first is still on the
                -- stack goes out (it shows in the log, and the hook sees it)
                -- without ever being drawn. A quarter second is imperceptible
                -- for a typed command and well clear of the frame.
                local ran = false
                LoopAsync(250, function()
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
