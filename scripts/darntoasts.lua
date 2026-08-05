-- darntoasts.lua: OPTIONAL DarnToasts integration (the "channel" recipe).
--
-- DarnToasts is a separate mod that draws styled HUD toasts and sticky
-- progress panels for whoever asks. Consumers ship NOTHING: the whole
-- integration is a package.path splice onto its Scripts folder plus
-- ToastLib.new("<mod name>") with NO opts, which joins the DEFAULT CHANNEL -
-- DarnToasts then owns style, position, the auto-lane that keeps two mods'
-- toasts from overlapping, and the per-mod mute toggle on its own Toasts
-- page. Passing any style opts would promote us to a "custom surface" and
-- make all of that our problem, so we never do (DarnToasts_API.md, the
-- channel-model table). Absent, stale or broken framework = every call here
-- is a no-op, one log line, and the mod behaves exactly as it always has.
--
-- LAYOUT. DarnToasts deploys as a SIBLING of our own mod folder
-- (<UE4SS Mods>/DarnToasts/Scripts/), so the relative splice its tutorial
-- documents - our script dir + "../../DarnToasts/Scripts/?.lua" - is the
-- correct one. Derived from THIS file's own source path, never from the
-- game's working directory (the same rule STATE_FILE follows in
-- evolution.lua).
--
-- KNOWN HAZARD, ACCEPTED AND CONTAINED. Requiring ToastLib runs ITS
-- ExecuteWithDelay heartbeat (a 500ms hook-health clock) and ITS config
-- watcher (a 2s file poll) inside OUR Lua state. Our house law bans EWD in
-- our own code: UE4SS's callback GC has been observed freeing a transient
-- delay-callback ref under load ("Ref was not function"), which killed every
-- deferred callback in the state at once - which is why the fork's own
-- deferred work is all latched one-shot LoopAsync, and why the radial has a
-- dead-tick fallback and the options layer is pumped from events we already
-- own. We cannot fix a dependency's internals, so we bound the exposure
-- instead: the require happens LAZILY, on the first call that would actually
-- draw something, so a session with the integration switched off (or with no
-- evolution in it) never loads ToastLib at all - and never runs its timers.
-- A dedicated server refuses outright: there is no HUD to draw on, so the
-- timers would be pure risk for zero benefit.
--
-- SURFACE CONTRACT (documented in full at the call sites in evolution.lua
-- and netchannel.lua):
--   integration off / framework missing -> notify() returns false and the
--     caller falls back to the vanilla notice feed (PalLogManager::AddLog)
--   channel loaded and accepting       -> notify() returns true; the caller
--     shows NOTHING else (one evolution, one notice - never both surfaces)
--   channel loaded and MUTED           -> notify() returns true AND muted;
--     the caller shows nothing either. The player muted the Palvolve lane on
--     the Toasts page - falling back to AddLog would defeat exactly the
--     setting they just changed. The chat fallback (evolveNotify.chatFallback)
--     and the UE4SS log line are untouched by the mute, as before.
--
-- Purely additive to the game: ToastLib draws in its own HUD hook and never
-- touches PalLogManager, so nothing about the vanilla notice feed changes.

local Config = require("config")

local DarnToasts = {}

local MOD_NAME = "Palvolve"

-- The name we join the channel under. It labels our auto-generated mute
-- toggle on the Toasts page and keys our lane in DarnToasts' consumer
-- registry, so it is stable forever - renaming it would orphan the player's
-- mute choice and move our lane.
local CHANNEL_NAME = "Palvolve"

-- The ONE sticky id this mod is ever allowed to occupy. ToastLib caps stickies
-- at 3 and auto-dismisses the oldest beyond that - PER CONSUMER INSTANCE, not
-- globally: each mod requires its own copy of ToastLib into its own Lua state,
-- and that copy's sticky list is a local of the instance it built (ToastLib.lua
-- ~374/618). So the panel a careless mod evicts is always its OWN, never
-- another mod's. The single id stays anyway, for the reason it was chosen: it
-- makes a leaked panel impossible to accumulate, since the next sequence
-- reuses the same wire id instead of stacking a second one beside it. Every
-- progress call below is funnelled onto this id; the `id` argument callers
-- pass is a LOGICAL owner token (see panelKey), not a wire id.
local PANEL_ID = "palvolve-evolve"

local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- Init latch: set on the FIRST attempt, success or failure, so a missing
-- framework costs one require and one log line per session rather than one
-- per evolution. T is the channel instance, nil whenever we have none.
local initTried = false
local T = nil

-- Single-slot bookkeeping. panelKey is the logical id of whoever owns the
-- panel right now (nil = no panel); panelTitle is that panel's headline.
-- ToastLib's T.progress keeps `text` across calls that omit it, but it does
-- NOT keep `sub` (ToastLib.lua:624-626: msg falls back to s.msg, sub is set
-- to nil when absent), so the title is cached and re-sent on every update -
-- one field of belt against a future change in that fallback.
local panelKey = nil
local panelTitle = nil

-- Read live at every call, never cached: this is a "live" options row, so a
-- player who flips it mid-session must see the change at the next message.
local function gateOn()
    local en = Config.evolveNotify
    return not (not en or en.darnToasts == false)
end

-- Splice + require + construct, exactly once. Everything is pcall'd: a
-- framework mid-update, a half-written config, a Lua error inside ToastLib's
-- own startup - none of them may cost us a single evolution.
local function ensure()
    if initTried then return T ~= nil end
    initTried = true
    local why = nil
    -- Headless has no HUD and no player: refuse before the require, so a
    -- dedicated server never runs ToastLib's timers (see the hazard note).
    local headless = false
    pcall(function() headless = require("role").isDedicated() == true end)
    if headless then
        why = "dedicated server - no HUD"
    else
        -- APPENDED, never prepended. This splice puts a FOREIGN mod's script
        -- folder on the search path of our whole Lua state, permanently, and a
        -- prepend would let a file over there answer a name of OURS first - a
        -- DarnToasts update that ever ships a config.lua, role.lua or i18n.lua
        -- would take over the fork's modules on the next lazy require. At the
        -- tail, our own folder always wins a collision, and "ToastLib" (a name
        -- nothing in this mod uses) is still found. FUTURE LAZY REQUIRES: any
        -- require issued after this call searches that folder too - keep our
        -- module names unique and never rely on the search ORDER for them.
        pcall(function()
            local src = debug.getinfo(1, "S").source
            if src:sub(1, 1) ~= "@" then return end
            local dir = src:sub(2):gsub("[^/\\]+$", "")
            package.path = package.path .. ";"
                .. dir .. "../../DarnToasts/Scripts/?.lua"
        end)
        local okLib, lib = pcall(require, "ToastLib")
        if not (okLib and type(lib) == "table"
            and type(lib.new) == "function") then
            why = okLib and "ToastLib returned no channel constructor"
                or tostring(lib)
        else
            -- NO opts, deliberately: opts promote the instance to a custom
            -- surface and we lose the page, the lane and the mute toggle.
            local okNew, inst = pcall(lib.new, CHANNEL_NAME)
            if okNew and type(inst) == "table"
                and type(inst.notify) == "function" then
                T = inst
            else
                why = okNew and "channel constructor returned no instance"
                    or tostring(inst)
            end
        end
    end
    if T then
        Log("[toasts] DarnToasts channel ready")
    else
        Log("[toasts] DarnToasts unavailable - vanilla notices only"
            .. (why and (" (" .. why .. ")") or ""))
    end
    return T ~= nil
end

-- The Toasts page's mute for OUR lane. T.muted() is ONE answer folded from
-- several switches (ToastLib.lua refreshStyle): the GLOBAL "Toasts enabled"
-- master switch being off, our entry in the mods table being false (or a table
-- with enabled = false), and the generated per-mod "mute_Palvolve" toggle. We
-- deliberately do NOT tell them apart: every one of them is a player saying
-- "not on my HUD", and our full-silence policy answers all three the same way
-- - no toast, no panel, and no fall back to the vanilla notice feed either,
-- because falling back would defeat exactly the setting they just changed. The
-- chat line (evolveNotify.chatFallback) and the UE4SS log are the guaranteed
-- surfaces and are untouched by any of it. Asked fresh every time: ToastLib
-- re-reads its config ~2s after the player hits Apply.
local function channelMuted()
    local muted = false
    pcall(function()
        muted = (type(T.muted) == "function") and (T.muted() == true)
    end)
    return muted
end

-- True when a notify/progress call would reach a live channel. Performs the
-- one-time init, so the first caller pays for it - by design: every caller
-- of this is about to try to show something.
function DarnToasts.available()
    if not gateOn() then return false end
    return ensure()
end

-- (There used to be a toastlib() accessor here, handing darnmenu.lua ToastLib's
-- registerMenuSchema when something had already loaded it. It is gone: that
-- helper's rewrite gate is version-only, so it cannot honour the content
-- fingerprint darnmenu.lua now writes, and it skips its own index merge
-- whenever that gate hits. darnmenu.lua writes both shared files itself, always
-- - one writer, one gate - and this file is back to doing exactly one job.)

-- Show a transient toast. Returns (handled, muted):
--   false, false -> nothing was shown and nothing will be; show your own
--   true,  false -> the line is on the channel; show NOTHING else
--   true,  true  -> the player muted this lane; show nothing else either
-- No accent color is passed on purpose - the channel's color is the
-- player's setting on the Toasts page, and a mod that hardcodes one is
-- overriding a choice it does not own. The message is already localized by
-- i18n before it gets here, so it is passed through verbatim.
function DarnToasts.notify(msg)
    if not DarnToasts.available() then return false, false end
    if channelMuted() then return true, true end
    local ok = pcall(T.notify, tostring(msg))
    -- a raising channel is treated as absent: the caller's vanilla fallback
    -- is strictly better than silence
    return ok, false
end

-- Open (or take over) the single sticky panel under a logical owner id.
-- A second begin with a different id takes the slot and the previous owner's
-- updates stop landing - which is what we want if a sequence ever leaked a
-- panel: the next one reuses the same wire id instead of stacking a second.
function DarnToasts.progressBegin(id, title)
    if not DarnToasts.available() then return false end
    if channelMuted() then return false end
    panelKey = tostring(id or "default")
    panelTitle = tostring(title or "")
    local ok = pcall(T.progress, PANEL_ID, { text = panelTitle, frac = 0 })
    if not ok then panelKey, panelTitle = nil, nil end
    return ok
end

-- Update the stage line and the bar. Never initializes: without a begin
-- there is no panel to update, and a stage callback firing after a finish
-- (a late async tick) must not resurrect one. frac is a float - %g, never
-- %d - and is handed to ToastLib as a number, which clamps it itself.
function DarnToasts.progressUpdate(id, sub, frac)
    if T == nil or panelKey == nil then return false end
    if tostring(id or "default") ~= panelKey then return false end
    if not gateOn() then return false end
    return pcall(T.progress, PANEL_ID, {
        text = panelTitle,
        sub = (sub ~= nil) and tostring(sub) or nil,
        frac = tonumber(frac),
    })
end

-- Ravel the panel shut. Deliberately NOT gated on the config switch: a
-- player who turns the integration off while a sequence is running must not
-- be left with a panel that nothing will ever dismiss. Only the owner can
-- close it, so a stale terminal path cannot kill a newer sequence's panel.
function DarnToasts.progressEnd(id)
    if T == nil or panelKey == nil then return false end
    if id ~= nil and tostring(id) ~= panelKey then return false end
    panelKey, panelTitle = nil, nil
    return pcall(T.dismiss, PANEL_ID)
end

return DarnToasts
