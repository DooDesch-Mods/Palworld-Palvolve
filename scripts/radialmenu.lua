-- Palvolve radial menu integration: adds a real "Evolve" entry to the hold-4
-- player action wheel and opens an option submenu in the same wheel, the way
-- the vanilla emote submenu works.
--
-- How the vanilla wheel works: WBP_PlayerRadialMenu builds the pal action
-- menu in CreatePlayerActionMenu. The generic WBP_CommonRadialMenuBase
-- (native base PalUIRadialMenuWidgetBase carries menuNum/nowSelectedIndex
-- and the hit testing) draws menuNum segments procedurally; the labels are
-- WBP_PlayerRadialMenu_MenuContent widgets on the menuCanvas of the nested
-- WBP_RadialMenu_base, registered per segment index via "Set Additional
-- Widget" (its Canvas is an OUT param, passed from Lua as an empty table).
-- RecalcMenuNum clears all registered label widgets, which is why vanilla
-- always calls it before adding labels. Submenus reuse the SAME wheel: the
-- emote flow swaps the content and rebinds the decide delegates
-- (Bind/UnbindPlayerActionMenuEvent) instead of opening another widget.
--
-- UE4SS constraints (v3.0.1): hooks on /Game/ BP functions are POST-hooks
-- (body already ran, parameter writes are dead), so the wheel cannot be
-- grown before vanilla lays out its labels. The injection therefore runs after the build: capture the label
-- widgets, grow via a direct wheel:RecalcMenuNum(vanilla + 1) call (which
-- clears the canvas), then re-register every vanilla label plus our entry
-- at the last index.
--
-- Selecting the extra segment must NOT reach the vanilla decide switch:
-- unknown indices run the photo mode branch. The natives
-- UpdateSelectedIndex_ForMouse/ForPad/ForceAxis recompute nowSelectedIndex
-- from the cursor; a synchronous post-hook flips our index to -1 (vanilla
-- treats the release as "nothing selected") and remembers the hover. The
-- wheel close then reopens the menu with OUR options: vanilla's decide
-- delegates are unbound for the submenu (its own pattern), so hover sound,
-- highlight and hit testing stay fully native there; our hooks track the
-- hovered option and commit the selected evolution on decide/close.

local Config = require("config")
local I18n = require("i18n")

-- In-game options (Mod Options Framework), loaded defensively exactly as
-- evolution.lua does it: a missing or broken modoptions.lua must not cost the
-- wheel anything. Opening the wheel is one of the pump's always-armed drivers -
-- see the hook below.
local ModOptions
do
    local okMO, mo = pcall(require, "modoptions")
    ModOptions = (okMO and type(mo) == "table") and mo or nil
end

local RadialMenu = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local MENU_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu.WBP_PlayerRadialMenu_C"
local WHEEL_WBP = "/Game/Pal/Blueprint/UI/CommonWidget/RadialMenu/WBP_CommonRadialMenuBase.WBP_CommonRadialMenuBase_C"
local CONTENT_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu_MenuContent.WBP_PlayerRadialMenu_MenuContent_C"
local RADIAL_NATIVE = "/Script/Pal.PalUIRadialMenuWidgetBase"

-- evolution API wired in init: check, listOptions, executeOption
local api = nil

-- state of the currently open wheel (main mode)
local ourIndex = nil
local ourWidget = nil
-- whether the cached label currently carries the vanilla "no otomo" grey;
-- flipping back to available recreates the widget (default color)
local ourWidgetGreyed = false
-- true while the cursor rests on our segment (maintained by the native
-- UpdateSelectedIndex post-hooks); consumed on wheel close/decide
local ourHover = false
-- the outer WBP_PlayerRadialMenu instance, captured on every build
local menuRef = nil

-- submenu state: the wheel shows OUR options instead of the pal actions
local subMode = false
local subModeSince = 0
local subOptions = nil
local subHoverIdx = nil
local subWidgets = {}
-- true while the action wheel is on screen; a 4-press in that state is
-- the vanilla cancel gesture and must close without committing anything
local wheelOpen = false
local cancelRequested = false

-- vanilla hover sound while it is muted on our segment: the per-frame
-- index reset would retrigger it every recompute, so the first (real)
-- tick plays and the flapping afterwards is silenced
local savedHoverSound = nil

local function muteHoverSound(wheel)
    if savedHoverSound ~= nil then return end
    pcall(function()
        local snd = wheel.HoveredSound
        if snd and snd:IsValid() then
            savedHoverSound = snd
            wheel.HoveredSound = nil
        end
    end)
end

local function restoreHoverSound(wheel)
    if savedHoverSound == nil then return end
    pcall(function()
        wheel.HoveredSound = savedHoverSound
    end)
    savedHoverSound = nil
end

-- the wheel plays its hover tick inside the native index update, which
-- runs while the sound is still muted - post the swallowed tick manually
-- (Wwise event, same route as the evolution fanfare); works both from the
-- muted state (savedHoverSound) and the live property
local function playHoverTick(wheel)
    pcall(function()
        local snd = savedHoverSound
        if not (snd and snd:IsValid()) then snd = wheel.HoveredSound end
        if not (snd and snd:IsValid()) then return end
        local aks = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics")
        if not (aks and aks:IsValid()) then return end
        local pawn = FindFirstOf("PalPlayerCharacter")
        aks:PostEvent(snd, pawn, 0, nil, false)
    end)
end

-- Identify the action wheel by its outer chain: the inner
-- WBP_CommonRadialMenuBase lives in WBP_PlayerRadialMenu's widget tree.
-- Other wheels (build menu, worker menu) share the class but not the outer.
local function isActionWheel(wheel)
    local ok, res = pcall(function()
        local o = wheel:GetOuter()
        for _ = 1, 3 do
            if not (o and o:IsValid()) then return false end
            local cls = o:GetClass():GetFullName()
            if string.find(cls, "WBP_PlayerRadialMenu_C", 1, true) then return true end
            o = o:GetOuter()
        end
        return false
    end)
    return ok and res == true
end

-- language detection and the localized entry label live in i18n.lua

local function labelText()
    return I18n.msg("evolve")
end

-- FText from a Lua string. UE4SS resolves the engine converter behind FText()
-- once per session; when that first lookup ran before UE4SS finished
-- initializing it stays broken for the whole session, so fall back to calling
-- the engine's own converter through reflection, which does a fresh lookup.
local fallbackAnnounced = false
local function toText(s)
    local okDirect, text = pcall(FText, s)
    if okDirect and text then return text end
    local okFallback, converted = pcall(function()
        local ktl = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        if not (ktl and ktl:IsValid()) then return nil end
        return ktl:Conv_StringToText(s)
    end)
    if okFallback and converted then
        if not fallbackAnnounced then
            fallbackAnnounced = true
            Log("[radial] FText broken this session - using engine text converter")
        end
        return converted
    end
    return nil
end

local function makeLabelWidget(owner, text)
    local widget = nil
    pcall(function()
        local cls = StaticFindObject(CONTENT_WBP)
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        -- widget owner must be THIS machine's player controller; on a listen
        -- host FindFirstOf could return a remote client's controller
        local pc = require("role").getLocalPlayerController()
        if not (cls and cls:IsValid() and lib and lib:IsValid() and pc and pc:IsValid()) then return end
        widget = lib:Create(owner, cls, pc)
    end)
    if widget and widget:IsValid() then
        local label = toText(text)
        local okText = false
        if label then okText = pcall(function() widget:SetText(label) end) end
        if not okText and Config.devMode then
            Log("[radial] SetText failed - entry stays unlabeled")
        end
        return widget
    end
    return nil
end

local function canvasSlot(widget)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    return lib:SlotAsCanvasSlot(widget)
end

local function wheelOf(menu)
    local wheel = nil
    pcall(function() wheel = menu.WBP_CommonRadialMenuBase end)
    if not (wheel and wheel:IsValid()) then return nil end
    return wheel
end

-- the labels live on the menuCanvas of the nested WBP_RadialMenu_base
local function labelCanvasOf(wheel)
    local canvas = nil
    pcall(function()
        local base = wheel.WBP_RadialMenu_base
        if base and base:IsValid() then canvas = base.menuCanvas end
    end)
    if not (canvas and canvas:IsValid()) then return nil end
    return canvas
end

-- Flush-safe forensic crumbs for the wheel-injection window. A native fault
-- inside a UFunction is pcall-TRANSPARENT: it kills the process with no Lua
-- error and no log flush, so the only way to name the call is to bracket it
-- on disk. The culprit reads as the last "entering" line with no matching
-- survival line. Append-only - truncating would destroy an earlier run's
-- evidence. Lives at the mod root beside palvolve_state.lua.
local CRUMB_FILE = (function()
    local path = nil
    pcall(function()
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) == "@" then
            local dir = src:sub(2):match("^(.*)[/\\]")
            local root = dir and dir:match("^(.*)[/\\]") or nil
            if root then path = root .. "\\radial_stage.txt" end
        end
    end)
    return path
end)()

local crumbHeaderDone = false
local function crumb(msg)
    if not CRUMB_FILE then return end
    local header = nil
    if not crumbHeaderDone then
        crumbHeaderDone = true
        local stamp = "?"
        pcall(function() stamp = tostring(os.date("%Y-%m-%d %H:%M:%S")) end)
        header = "=== radial session " .. stamp .. " ===\n"
    end
    pcall(function()
        local f = io.open(CRUMB_FILE, "a")
        if not f then return end
        if header then f:write(header) end
        f:write(msg .. "\n")
        f:flush()
        f:close()
    end)
end

-- Error text fit for a crumb line: one line, bounded. The ladder is read line
-- by line, so a multi-line Lua error would otherwise fake several stages.
local function crumbErr(err)
    local s = tostring(err or "?"):gsub("[\r\n]+", " ")
    if #s > 120 then s = s:sub(1, 120) .. "..." end
    return s
end

local function saw(wheel, idx, widget, mode)
    -- trailing table receives the Canvas OUT param. The label widgets were
    -- captured BEFORE RecalcMenuNum cleared the canvas, so a stale handle
    -- reaching the native registrar is the standing suspect - hence the
    -- per-index bracket. mode tags main-wheel vs submenu registration: the
    -- two windows share this helper and an untagged idx would mis-attribute
    -- a submenu fault to a vanilla main-wheel label.
    crumb(string.format("entering saw %s idx=%d", mode, idx))
    local ok, err = pcall(function()
        wheel["Set Additional Widget"](wheel, idx, widget, {})
    end)
    -- the closer carries the VERDICT: a blind "ok" would graduate a shape
    -- that actually raised
    crumb(string.format("survived saw %s idx=%d ok=%s%s", mode, idx, tostring(ok),
        ok and "" or (" err=" .. tostring(err))))
    return ok
end

-- pcall'd liveness read, crumbed on BOTH outcomes: the captured labels are
-- the standing suspects, so even their IsValid dereference must never run
-- bare between brackets - and a stale skip must leave a positive record,
-- not an unexplained index gap.
local function labelAlive(lbl, mode, idx)
    local alive = false
    local okV = pcall(function() alive = lbl:IsValid() end)
    if not (okV and alive) then
        crumb(string.format("skipped %s idx=%d stale label okV=%s", mode, idx, tostring(okV)))
        return false
    end
    return true
end

-- vanilla's grey for unavailable entries (used on Feed/Pet without an
-- otomo), copied into a PLAIN table immediately: passing a live struct
-- property wrapper as a UFunction argument crashes natively
local function readGrey(menu)
    local flat = nil
    pcall(function()
        local c = menu.TextColor_NothingOtomo
        if c == nil then return end
        -- FSlateColor keeps the value in SpecifiedColor; FLinearColor is flat
        local src = nil
        pcall(function()
            local s = c.SpecifiedColor
            if s and s.R ~= nil then src = s end
        end)
        if not src then src = c end
        flat = { R = src.R + 0.0, G = src.G + 0.0, B = src.B + 0.0, A = src.A + 0.0 }
    end)
    return flat
end

local function applyGrey(widget, flat)
    -- fallback when the property read yields nothing: a grey close to the
    -- vanilla no-otomo look
    flat = flat or { R = 0.35, G = 0.35, B = 0.35, A = 1.0 }
    local ok = pcall(function() widget:SetTextColor(flat) end)
    if not ok then
        -- the parameter may be an FSlateColor instead of an FLinearColor
        ok = pcall(function()
            widget:SetTextColor({ SpecifiedColor = flat, ColorUseRule = 0 })
        end)
    end
    return ok
end

-- ---------------------------------------------------------------- main mode

local function injectMainEntry(menu)
    local wheel = wheelOf(menu)
    if not wheel then
        if Config.devMode then Log("[radial] wheel reference missing") end
        return
    end
    local canvas = labelCanvasOf(wheel)
    if not canvas then
        if Config.devMode then Log("[radial] menuCanvas missing") end
        return
    end

    ourIndex = nil

    -- census BEFORE growing: RecalcMenuNum clears the canvas, so the
    -- label widgets (add order = segment index order) are captured now
    local labels = {}
    local geo = {}
    local childCount = canvas:GetChildrenCount()
    for i = 0, childCount - 1 do
        local child = canvas:GetChildAt(i)
        if child and child:IsValid() then
            local cls = child:GetClass():GetFullName()
            if string.find(cls, "WBP_PlayerRadialMenu_MenuContent_C", 1, true) then
                table.insert(labels, child)
                pcall(function()
                    local p = canvasSlot(child):GetPosition()
                    geo[#labels] = { x = p.X, y = p.Y }
                end)
            end
        end
    end
    if Config.devMode then
        Log(string.format("[radial] canvas census: %d children, %d labels, menuNum=%d",
            childCount, #labels, wheel.menuNum))
    end
    if #labels == 0 then return end

    local vanillaCount = #labels
    local newCount = vanillaCount + 1

    -- grow the wheel: runs the vanilla redraw AND clears all label
    -- widgets from the canvas - everything is re-added below
    -- the menuNum read-back is a reflection read on the same wheel object
    -- and belongs INSIDE the bracket: a wheel gone bad faults on the read
    -- one line after the grow, and a bare read would end the ladder at a
    -- clean-looking closer
    crumb(string.format("entering RecalcMenuNum(%d)", newCount))
    local grownNum = -1
    local okGrow, errGrow = pcall(function()
        wheel:RecalcMenuNum(newCount)
        grownNum = wheel.menuNum
    end)
    crumb(string.format("survived RecalcMenuNum ok=%s menuNum=%d", tostring(okGrow), grownNum))
    if not (okGrow and grownNum == newCount) then
        if Config.devMode then
            Log(string.format("[radial] grow to %d failed (ok=%s menuNum=%d%s)",
                newCount, tostring(okGrow), grownNum,
                okGrow and "" or (" err=" .. tostring(errGrow))))
        end
        return
    end

    -- grey out like Feed/Pet while no own pal with options is summoned
    local offered = true
    if api and api.canOffer then
        crumb("entering canOffer")
        local okAvail, avail = pcall(api.canOffer)
        crumb(string.format("survived canOffer ok=%s", tostring(okAvail)))
        offered = okAvail and avail == true
    end
    -- ourWidget is CACHED module state surviving across wheel opens - crash
    -- #8 was a re-open 48 minutes after a clean first open, so every touch
    -- of the cached handle is a prime suspect and gets its own bracket
    if offered and ourWidgetGreyed and ourWidget then
        -- recreating restores the widget's default text color
        crumb("entering ungrey remove")
        local okR = pcall(function()
            if ourWidget:IsValid() then ourWidget:RemoveFromParent() end
        end)
        crumb(string.format("survived ungrey remove ok=%s", tostring(okR)))
        ourWidget = nil
        ourWidgetGreyed = false
    end
    crumb("entering cached-widget IsValid")
    local widgetAlive = false
    pcall(function() widgetAlive = (ourWidget and ourWidget:IsValid()) == true end)
    crumb(string.format("survived cached-widget IsValid alive=%s", tostring(widgetAlive)))
    if not widgetAlive then
        crumb("entering makeLabelWidget")
        ourWidget = makeLabelWidget(menu, labelText())
        crumb(string.format("survived makeLabelWidget widget=%s", tostring(ourWidget ~= nil)))
        ourWidgetGreyed = false
    end
    if not ourWidget then
        if Config.devMode then Log("[radial] label widget creation failed") end
        return
    end
    crumb("entering relabel SetText")
    local relabel = toText(labelText())
    if relabel then pcall(function() ourWidget:SetText(relabel) end) end
    crumb("survived relabel SetText")
    if not offered and not ourWidgetGreyed then
        crumb("entering grey read+apply")
        local flat = readGrey(menu)
        ourWidgetGreyed = applyGrey(ourWidget, flat)
        crumb(string.format("survived grey read+apply applied=%s", tostring(ourWidgetGreyed)))
        if Config.devMode then
            Log(string.format("[radial] grey attempt: read=%s applied=%s",
                flat and string.format("%.2f/%.2f/%.2f/%.2f", flat.R, flat.G, flat.B, flat.A) or "nil",
                tostring(ourWidgetGreyed)))
        end
    end

    -- preferred path: let the wheel register everything itself, which
    -- keeps the AdditionalWidget map intact for hover highlights
    local sawOk = true
    for i, lbl in ipairs(labels) do
        -- a stale label is SKIPPED without failing sawOk (unchanged
        -- behavior: the wheel keeps its hole, the fallback is not forced) -
        -- but the skip now leaves a crumb instead of a silent index gap
        if labelAlive(lbl, "saw main", i - 1) then
            sawOk = saw(wheel, i - 1, lbl, "main") and sawOk
        end
    end
    sawOk = saw(wheel, vanillaCount, ourWidget, "main") and sawOk
    if sawOk then
        ourIndex = vanillaCount
        crumb("window complete via saw")
        if Config.devMode then
            Log(string.format("[radial] Evolve entry injected at index %d via Set Additional Widget", ourIndex))
        end
        return
    end

    -- fallback: re-add and place everything ourselves. Preferred position
    -- source is the wheel's own CalcAdditionalWidgetPosition; if that call
    -- fails, derive the circle from the captured layout (anchors/alignment
    -- 0.5 center the coordinates: pos = (r sin th, -r cos th), th clockwise
    -- from the top).
    local radius, angle0 = 0, 0
    if geo[1] then
        radius = math.sqrt(geo[1].x * geo[1].x + geo[1].y * geo[1].y)
        angle0 = math.atan(geo[1].x, -geo[1].y)
    end
    -- the fallback runs exactly when the registrar already misbehaved, so
    -- it is the path MOST likely to fault - every native cluster in it is
    -- bracketed per index
    local function calcPos(idx)
        local out = {}
        crumb(string.format("entering calcPos idx=%d", idx))
        local okC = pcall(function()
            wheel:CalcAdditionalWidgetPosition(idx, out)
        end)
        crumb(string.format("survived calcPos idx=%d ok=%s", idx, tostring(okC)))
        if okC and type(out.X) == "number" and type(out.Y) == "number" then
            return out.X, out.Y
        end
        if radius < 1 then return nil end
        local th = angle0 + idx * (2 * math.pi / newCount)
        return radius * math.sin(th), -radius * math.cos(th)
    end
    local function addAndPlace(widget, idx)
        crumb(string.format("entering addAndPlace idx=%d", idx))
        local okA = pcall(function()
            canvas:AddChildToCanvas(widget)
            local slot = canvasSlot(widget)
            slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
            slot:SetAlignment({ X = 0.5, Y = 0.5 })
            slot:SetAutoSize(true)
            local px, py = calcPos(idx)
            if px then slot:SetPosition({ X = px, Y = py }) end
        end)
        crumb(string.format("survived addAndPlace idx=%d ok=%s", idx, tostring(okA)))
    end
    for i, lbl in ipairs(labels) do
        if labelAlive(lbl, "fallback", i - 1) then addAndPlace(lbl, i - 1) end
    end
    addAndPlace(ourWidget, vanillaCount)
    ourIndex = vanillaCount
    crumb("window complete via fallback")
    if Config.devMode then
        Log(string.format("[radial] Evolve entry injected at index %d via slot fallback", ourIndex))
    end
end

-- ---------------------------------------------------------------- submenu

-- Segments carry the name alone. Requirements go to the middle of the wheel
-- instead: with several targets open, a second line per segment turns the ring
-- into a wall of text, and the segments are narrow enough that it wraps.
local function optionLabel(opt)
    return opt.label or (opt.pair and opt.pair.to) or "?"
end

-- ---------------------------------------------------------------- center text

-- The requirements of whatever the player is hovering, shown once in the middle
-- of the ring (evolution.lua wraps them; the string arrives with its own line
-- breaks). WBP_CommonRadialMenuBase carries a CenterWidget slot, but its inner
-- structure is not ours to rely on, so this places its own label into the
-- wheel's inner canvas at the center offset - the same widget class and the
-- same canvas-slot route the segment labels already use.
--
-- Purely cosmetic, so it fails CLOSED per house rule: a structural failure (no
-- inner canvas, a slot the layout library refuses) latches the whole center off
-- for the session with ONE log line, while anything that could be transient -
-- a widget the factory did not hand back this time - simply skips and is tried
-- again on the next open. The wheel never depends on it either way.
--
-- Every native call below is bracketed like the injection window above: the
-- cached widget is module state that survives across opens, which is exactly
-- the shape crash #8 keeps pointing at, so it is revalidated on every touch and
-- dropped the moment it reads stale.
--
-- CRUMB VOCABULARY. These crumbs share the file with the injection ladder, whose
-- reading matrix treats ANY "ok=false" as "the fallback ran" and a terminal
-- "window complete via ..." as proof the window survived. So nothing here writes
-- an "ok=" token: a closer says `applied` (it worked), `skipped:<why>` (a benign
-- soft-skip, no fault) or `failed:<err>` (the pcall actually raised). And every
-- center line carries a PHASE word - `sub` inside the submenu build window,
-- `hover` / `close` / `preopen` outside it - so a line sitting after a terminal
-- is self-evidently a hover or a teardown, never a second window.
local centerWidget = nil
local centerDisabled = false

local function innerCanvasOf(wheel)
    local canvas = nil
    pcall(function() canvas = wheel.CanvasPanel_Inner end)
    if canvas and canvas:IsValid() then return canvas end
    return nil
end

-- Drops the cached handle WITHOUT touching it. The teardown path uses this: the
-- engine is dismantling the UI there, and calling into a widget it already freed
-- is exactly the shape crash #8 keeps pointing at - while a handle that outlives
-- the world switch is the same bug one reload later.
local function dropCenterRef()
    centerWidget = nil
end

local function clearCenter(phase)
    if centerWidget then
        crumb("entering center remove " .. phase)
        local removed = false
        local okR, errR = pcall(function()
            if centerWidget:IsValid() then
                centerWidget:RemoveFromParent()
                removed = true
            end
        end)
        crumb(string.format("survived center remove %s %s", phase,
            okR and (removed and "applied" or "skipped:stale-widget")
                or ("failed:" .. crumbErr(errR))))
    end
    centerWidget = nil
end

local function setCenterText(menu, text, phase)
    if centerDisabled then return end

    -- ONE bracket over every reflection read this call makes: menu, the cached
    -- widget, and - when the label still has to be built - the wheel and its
    -- inner canvas. Those last two used to run bare between crumbs, which is a
    -- hole exactly where the ladder has to be tightest: a fault on them would
    -- end the file on a closer that reads clean. The closer reports what was
    -- OBTAINED, so a missing canvas is a fact on disk rather than an inference.
    crumb("entering center guard " .. phase)
    local menuAlive, widgetAlive, wheelAlive = false, false, false
    local wheel, canvas = nil, nil
    pcall(function() menuAlive = (menu and menu:IsValid()) == true end)
    pcall(function() widgetAlive = (centerWidget and centerWidget:IsValid()) == true end)
    if not widgetAlive then centerWidget = nil end
    if menuAlive and not centerWidget then
        wheel = wheelOf(menu)
        -- re-read after wheelOf's own check: the latch below may only fire on a
        -- wheel confirmed alive AT THIS MOMENT
        if wheel then pcall(function() wheelAlive = wheel:IsValid() == true end) end
        if wheelAlive then canvas = innerCanvasOf(wheel) end
    end
    crumb(string.format("survived center guard %s menu=%s widget=%s wheel=%s canvas=%s",
        phase,
        menuAlive and "alive" or "gone",
        widgetAlive and "alive" or "stale",
        wheel and (wheelAlive and "alive" or "stale") or "n-a",
        canvas and "found" or (wheelAlive and "missing" or "n-a")))
    if not menuAlive then return end

    if not centerWidget then
        -- transient: no wheel this open, or one whose validity could not be
        -- confirmed - neither says the center is structurally impossible, so
        -- this open is skipped and the next one tries again
        if not wheelAlive then return end
        if not canvas then
            -- a wheel confirmed alive that has no inner canvas: genuinely
            -- structural, nothing about that gets better on the next open
            centerDisabled = true
            Log("[radial] center text: no CanvasPanel_Inner - disabled for this session")
            return
        end
        crumb("entering center makeLabelWidget " .. phase)
        local widget = makeLabelWidget(menu, text or "")
        crumb(string.format("survived center makeLabelWidget %s %s", phase,
            widget and "applied" or "skipped:no-widget"))
        if not widget then return end -- transient: the factory may answer next time
        crumb("entering center place " .. phase)
        local placed, errPlace = pcall(function()
            canvas:AddChildToCanvas(widget)
            local slot = canvasSlot(widget)
            -- anchored to the middle of the canvas, then centered on itself, so
            -- the text grows in both directions instead of off to one side
            slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
            slot:SetAlignment({ X = 0.5, Y = 0.5 })
            slot:SetAutoSize(true)
            slot:SetPosition({ X = 0.0, Y = 0.0 })
        end)
        crumb(string.format("survived center place %s %s", phase,
            placed and "applied" or ("failed:" .. crumbErr(errPlace))))
        centerWidget = widget
        if not placed then
            -- the canvas took the widget but the slot route did not work: take
            -- the half-placed label back out and stop trying
            clearCenter(phase)
            centerDisabled = true
            Log("[radial] center text: canvas slot refused - disabled for this session")
        end
        return
    end

    crumb("entering center SetText " .. phase)
    -- a converter that hands back nothing is the transient half of the fail-
    -- closed rule (toText already says so once per session) - a soft skip, not
    -- a failure, and the closer has to say which of the two it was
    local label = toText(text or "")
    local okSet, errSet = false, nil
    if label then okSet, errSet = pcall(function() centerWidget:SetText(label) end) end
    crumb(string.format("survived center SetText %s %s", phase,
        label and (okSet and "applied" or ("failed:" .. crumbErr(errSet)))
            or "skipped:text-nil"))
end

local function buildSubmenu(menu)
    local wheel = wheelOf(menu)
    if not wheel then subMode = false; return end
    local options = subOptions
    if not (options and #options > 0) then subMode = false; return end

    -- a single option still needs two segments for a drawable wheel
    local count = math.max(#options, 2)
    crumb(string.format("entering sub RecalcMenuNum(%d)", count))
    local grownSub = -1
    local okGrow = pcall(function()
        wheel:RecalcMenuNum(count)
        grownSub = wheel.menuNum
    end)
    crumb(string.format("survived sub RecalcMenuNum ok=%s menuNum=%d", tostring(okGrow), grownSub))
    if not (okGrow and grownSub == count) then
        if Config.devMode then Log("[radial] submenu recalc failed") end
        subMode = false
        return
    end

    -- fresh widgets per build (runs once per submenu open): the default
    -- text color is the available state, blocked options get vanilla's
    -- no-otomo grey
    crumb("entering sub greyRead")
    local grey = readGrey(menu)
    crumb("survived sub greyRead")
    for i, opt in ipairs(options) do
        crumb(string.format("entering sub makeLabelWidget %d", i))
        local w = makeLabelWidget(menu, optionLabel(opt))
        crumb(string.format("survived sub makeLabelWidget %d widget=%s", i, tostring(w ~= nil)))
        subWidgets[i] = w
        if w then
            if opt.blocked then
                crumb(string.format("entering sub applyGrey %d", i))
                applyGrey(w, grey)
                crumb(string.format("survived sub applyGrey %d", i))
            end
            saw(wheel, i - 1, w, "sub")
        end
    end

    -- The center starts empty and fills on the first hover, so an unhovered
    -- wheel does not claim a target the player has not pointed at yet. Cosmetic,
    -- and pcall'd for that reason: a Lua raise in the label must never cost the
    -- terminal line below, because a ladder file that ends without one reads as
    -- "the window never completed" - the one verdict the crash-#8 matrix trusts
    -- most. The widget is skipped for this open; the wheel does not care.
    local okCenter, errCenter = pcall(setCenterText, menu, "", "sub")
    if not okCenter and Config.devMode then
        Log("[radial] center text skipped: " .. tostring(errCenter))
    end
    crumb("window complete via submenu")

    if Config.devMode then
        Log(string.format("[radial] submenu built with %d options", #options))
    end
end

-- consume the submenu state and run the hovered option (the submenu
-- selection is the confirmation); triggered from decide/close hooks
local function subCommit()
    if not subMode then return end
    local opt = nil
    if subHoverIdx ~= nil and subOptions then
        opt = subOptions[subHoverIdx + 1]
    end
    subMode = false
    subOptions = nil
    subHoverIdx = nil
    subWidgets = {}
    -- the wheel is on its way out here, so this is a close event and says so:
    -- these lines land AFTER a terminal and must not read like a second window
    clearCenter("close")
    if Config.devMode then
        Log(string.format("[radial] submenu commit: %s",
            opt and optionLabel(opt) or "no selection"))
    end
    if not opt or opt.cancel then
        if opt and opt.cancel and menuRef and menuRef:IsValid() then
            ExecuteInGameThread(function()
                pcall(function() menuRef:CloseMenu() end)
            end)
        end
        return
    end
    ExecuteInGameThread(function()
        pcall(function()
            if menuRef and menuRef:IsValid() then
                pcall(function() menuRef:CloseMenu() end)
            end
            api.executeOption(opt)
        end)
    end)
end

-- ---------------------------------------------------------------- injection

local function injectEntry(menu)
    local okAll, errAll = pcall(function()
        if subMode and (os.clock() - subModeSince) > 15 then
            -- stale submenu state (reopen never happened): fall back. The label
            -- widgets of that abandoned build are cached handles like the center
            -- one, so their refs go too - a wheel this old may well be from
            -- before a world switch
            subMode = false
            subOptions = nil
            subHoverIdx = nil
            subWidgets = {}
            clearCenter("preopen")
        end
        if subMode then
            buildSubmenu(menu)
        else
            -- a leftover center label from an earlier submenu must never sit in
            -- the middle of the plain action wheel
            clearCenter("preopen")
            injectMainEntry(menu)
        end
    end)
    if not okAll and Config.devMode then
        Log("[radial] injectEntry error: " .. tostring(errAll))
    end
end

function RadialMenu.init(evolutionApi)
    if not (Config.radialMenu == nil or Config.radialMenu) then return end
    api = evolutionApi

    -- normal-mode commit on our segment: opens the option submenu in the
    -- same wheel (reopened, since the release just closed it)
    local function commitOurs()
        if not ourHover then return end
        ourHover = false
        ExecuteInGameThread(function()
            pcall(function()
                -- listOptions now resolves a localized name, the conditions and
                -- the full price PER TARGET for the center text, so it is a
                -- native cluster of its own inside the open window and gets the
                -- same bracket as the wheel calls
                crumb("entering listOptions")
                local okList, opts, reason = pcall(api.listOptions)
                -- the option count is the verdict here: "ok" vocabulary is
                -- spoken for by the injection ladder, where ok=false means the
                -- fallback ran
                crumb(okList
                    and string.format("survived listOptions n=%d",
                        (type(opts) == "table") and #opts or 0)
                    or ("survived listOptions failed:" .. crumbErr(opts)))
                if not okList then
                    if Config.devMode then
                        Log("[radial] listOptions failed: " .. tostring(opts))
                    end
                    return
                end
                if not (opts and #opts > 0) then
                    Log(reason or "No evolution available")
                    return
                end
                -- an explicit cancel entry: no dead segments, backing out
                -- is always visible and clickable
                table.insert(opts, {
                    cancel = true,
                    label = I18n.msg("cancel"),
                })
                subOptions = opts
                subHoverIdx = nil
                subMode = true
                subModeSince = os.clock()
                local okOpen = false
                if menuRef and menuRef:IsValid() then
                    okOpen = pcall(function() menuRef:OpenPlayerActionMenu() end)
                end
                if Config.devMode then
                    Log(string.format("[radial] submenu open: options=%d reopen=%s",
                        #opts, tostring(okOpen)))
                end
                if not okOpen then
                    subMode = false
                    subOptions = nil
                    -- the reopen never happened, so nothing is being built:
                    -- this is the pre-open path rolling itself back
                    clearCenter("preopen")
                end
            end)
        end)
    end

    -- runs synchronously right after the native recomputed nowSelectedIndex.
    -- Main mode: claim our segment and hide it from the vanilla decide
    -- switch (unknown indices would run the photo mode branch there).
    -- Submenu mode: observe only - vanilla is unbound, everything is ours.
    local function suppressHandler(self)
        pcall(function()
            local wheel = self:get()
            if not (wheel and wheel:IsValid() and isActionWheel(wheel)) then return end
            local idx = wheel.nowSelectedIndex
            if subMode then
                -- every segment is ours here, but the vanilla decide is
                -- still bound (UnbindPlayerActionMenuEvent only detaches
                -- otomo delegates) - suppress ALL indices and track the
                -- hover ourselves; dead filler segments select "nothing"
                if idx ~= nil and idx >= 0 then
                    local newHover = nil
                    if subOptions and idx < #subOptions then
                        newHover = idx
                    end
                    if newHover ~= subHoverIdx then
                        local wasMuted = savedHoverSound ~= nil
                        subHoverIdx = newHover
                        -- The middle of the ring follows the hover: one target's
                        -- requirements at a time, where there is room for them.
                        -- Tagged `hover` because this fires long after the build
                        -- window closed - the crumbs it writes sit past a
                        -- terminal line and must not read like a new window.
                        local hovered = newHover and subOptions and subOptions[newHover + 1] or nil
                        setCenterText(menuRef, hovered and hovered.requirement or "", "hover")
                        if Config.devMode then
                            Log(string.format("[radial] sub hover idx=%s", tostring(newHover)))
                        end
                        -- vanilla's own tick already played while unmuted;
                        -- from then on the flapping is silent, so replay
                        if newHover ~= nil and wasMuted then
                            playHoverTick(wheel)
                        end
                    end
                    muteHoverSound(wheel)
                    wheel.nowSelectedIndex = -1
                end
                return
            end
            if ourIndex ~= nil and idx == ourIndex then
                if not ourHover then
                    -- first frame on our segment: vanilla just played its
                    -- hover tick, silence the flapping from here on
                    muteHoverSound(wheel)
                end
                ourHover = true
                wheel.nowSelectedIndex = -1
            elseif idx >= 0 then
                if ourHover then
                    local wasMuted = savedHoverSound ~= nil
                    restoreHoverSound(wheel)
                    if wasMuted then
                        -- the native already tried to play this segment's
                        -- tick while the sound was muted - replay it
                        playHoverTick(wheel)
                    end
                end
                ourHover = false
            end
            -- idx == -1 keeps the last state: the wheel itself is sticky
            -- about the previous selection when the cursor rests mid-wheel
        end)
    end
    local noopPre = function() end

    local hooks = {
        {
            -- fires AFTER the BP body (script hooks are post-hooks); the
            -- injection defers one tick so the open flow has settled
            path = MENU_WBP .. ":CreatePlayerActionMenu",
            fn = function(self)
                -- in-game options sync, at the cheapest per-open point we own.
                -- The pump has several independent drivers because any single
                -- one can be config-disabled (all three evolution.lua pollers
                -- are), while opening the wheel is armed on every non-dedicated
                -- session. Pure Lua, self-throttled to ~2s, pcall'd: it cannot
                -- delay or break the wheel build below (modoptions.lua)
                if ModOptions then pcall(ModOptions.pump) end
                -- capture the UObject NOW: hook params are only valid during
                -- the callback, the deferred injection then uses the object
                local menu = nil
                pcall(function() menu = self:get() end)
                if not menu then return end
                menuRef = menu
                wheelOpen = true
                cancelRequested = false
                ExecuteInGameThread(function()
                    pcall(function() injectEntry(menu) end)
                end)
            end,
        },
        {
            path = MENU_WBP .. ":OnDecidedPlayerActionMenu",
            fn = function(self, Index)
                -- only bound in main mode; the submenu unbinds it
                commitOurs()
            end,
        },
        {
            -- fires on the real decide gesture (click/commit release)
            path = WHEEL_WBP .. ":OnDecided",
            fn = function(self)
                local wheel = nil
                pcall(function() wheel = self:get() end)
                if not (wheel and wheel:IsValid() and isActionWheel(wheel)) then return end
                if Config.devMode then Log("[radial] wheel OnDecided") end
                if subMode then subCommit() else commitOurs() end
            end,
        },
        {
            -- closes on both commit and cancel; a preceding 4-press marks
            -- the vanilla cancel gesture, which must not run anything
            path = WHEEL_WBP .. ":Close",
            fn = function(self)
                local wheel = nil
                pcall(function() wheel = self:get() end)
                -- Close is what the engine calls while dismantling the UI on the
                -- way back to the main menu, so the widget can already be gone
                local wheelAlive = false
                pcall(function() wheelAlive = (wheel and wheel:IsValid()) == true end)
                if wheelAlive and isActionWheel(wheel) then
                    if cancelRequested then
                        if Config.devMode and (ourHover or subMode) then
                            Log("[radial] close: cancelled, nothing committed")
                        end
                        subMode = false
                        subOptions = nil
                        subHoverIdx = nil
                        subWidgets = {}
                        clearCenter("close")
                    elseif subMode then
                        subCommit()
                    else
                        commitOurs()
                    end
                    restoreHoverSound(wheel)
                    wheelOpen = false
                    cancelRequested = false
                elseif not wheelAlive then
                    -- Teardown: the wheel is already freed, so the clear branch
                    -- above is skipped and every cached HANDLE would otherwise
                    -- sit in module state across the world switch, waiting for
                    -- the next open to revalidate a pointer into a dead world.
                    -- The refs are dropped WITHOUT touching the widgets - not
                    -- even IsValid may be called on them here, which is why
                    -- clearCenter is not what runs.
                    -- Only handles are dropped. subMode/subOptions are pure Lua
                    -- intent with a stale-timeout of their own, and a Close that
                    -- merely failed to resolve its widget must not be able to
                    -- cancel a submenu that is about to be built.
                    if centerWidget or ourWidget then
                        crumb("dropped cached widgets close (wheel gone, untouched)")
                    end
                    dropCenterRef()
                    ourWidget = nil
                    ourWidgetGreyed = false
                    ourIndex = nil
                    subWidgets = {}
                    menuRef = nil
                    -- the saved sound belongs to the wheel that just went away
                    -- and restoreHoverSound would write it into whatever wheel
                    -- comes next; the mute dies with its wheel, and the next one
                    -- builds its sound from the blueprint default
                    savedHoverSound = nil
                end
                ourHover = false
            end,
        },
        {
            path = RADIAL_NATIVE .. ":UpdateSelectedIndex_ForMouse",
            fn = noopPre,
            post = suppressHandler,
        },
        {
            path = RADIAL_NATIVE .. ":SetSelectedIndexForce",
            fn = noopPre,
            post = suppressHandler,
        },
        {
            -- the free-cursor wheel (toggle mode / reopened submenu) writes
            -- nowSelectedIndex directly from BP - no native carries it. The
            -- BP post-hooks run synchronously after each update and before
            -- the click decide processes, so the reset stays race-free.
            path = WHEEL_WBP .. ":OnMouseMove",
            fn = suppressHandler,
        },
        {
            path = WHEEL_WBP .. ":Tick",
            fn = suppressHandler,
        },
        {
            path = RADIAL_NATIVE .. ":UpdateSelectedIndex_ForPad",
            fn = noopPre,
            post = suppressHandler,
        },
        {
            path = RADIAL_NATIVE .. ":UpdateSelectedIndex_ForceAxis",
            fn = noopPre,
            post = suppressHandler,
        },
    }
    -- the vanilla cancel gesture: pressing 4 while the wheel is on screen
    -- closes it without running any action - mirror that for our commits.
    -- UE4SS keybinds fire on press, so the press that OPENS the menu comes
    -- before wheelOpen is set and never counts as cancel.
    pcall(function()
        local function markCancel()
            if wheelOpen then
                cancelRequested = true
                if Config.devMode then Log("[radial] cancel gesture detected") end
            end
        end
        -- Key.FOUR is the top digit row (the radial key); NUM_FOUR is the
        -- numpad - register both
        if Key.FOUR then RegisterKeyBind(Key.FOUR, markCancel) end
        if Key.NUM_FOUR then RegisterKeyBind(Key.NUM_FOUR, markCancel) end
        -- ESC dismisses the wheel too; without marking it as a cancel the
        -- Close hook would commit the hovered entry (the markCancel no-ops
        -- while no wheel is open, so a global ESC bind is safe)
        if Key.ESCAPE then RegisterKeyBind(Key.ESCAPE, markCancel) end
    end)

    local registered = {}
    local function tryHooks()
        local allOk = true
        for _, h in ipairs(hooks) do
            if not registered[h.path] then
                local ok
                if h.post then
                    ok = pcall(RegisterHook, h.path, h.fn, h.post)
                else
                    ok = pcall(RegisterHook, h.path, h.fn)
                end
                registered[h.path] = ok
                allOk = allOk and ok
            end
        end
        return allOk
    end
    local doneRegistering = false
    if tryHooks() then
        doneRegistering = true
        Log("Radial menu integration active: Evolve entry in the hold-4 wheel")
    end

    -- The radial WBP classes load LAZILY (the UI is built on demand, often only when
    -- the wheel is first opened), so register when a radial-menu WBP instance
    -- appears rather than polling for a class that is not loaded yet.
    -- NotifyOnNewObject flags a registration pass; a single idle-guarded LoopAsync
    -- performs it on the game thread (RegisterHook needs the game thread). This is
    -- the canonical GC-safe pattern (UE4SS-LESSONS 1/4): it never polls forever (the
    -- "evolve tab disappears until relaunch" trap) and never gives up early (it
    -- re-arms every time the UI reappears, fixing the "hooks unavailable" give-up
    -- that left single-player with no Evolve entry).
    --
    -- The notify keeps to that rule and only sets the flag, with ONE exception:
    -- when the drain loop has stopped ticking. UE4SS can tear down its Lua tick
    -- hook mid-session ("Ref was not function ... removing hook!"), and every
    -- LoopAsync in the process dies with it - including this one, which left the
    -- wheel without an Evolve entry until the next relaunch. Starting another
    -- LoopAsync would not help: the machinery that runs them is what died. The
    -- notify fires from the game thread while the widget is built, so on that
    -- path it can register itself. `lastTick` separates the two cases - a live
    -- loop refreshes it every second, so the inline branch stays dormant while
    -- the normal path works.
    --
    -- HOUSE LAW (v1.4.8, no NEW NotifyOnNewObject on a BP class): this adds no
    -- notify. It is the SAME long-proven registration notify on the SAME class,
    -- given a second, strictly-gated job. The added work is one os.clock compare
    -- while the loop is alive (the cheap path, and the only one that ever runs
    -- in a healthy session), and the branch that does fire is fully pcall'd and
    -- latched by doneRegistering exactly like the loop body.
    if not doneRegistering then
        local wantRegister = true -- one retry after load, then armed by the notify
        -- declared above the notify closure that captures it (house law)
        local lastTick = os.clock()
        local TICK_DEAD_AFTER = 3.0
        pcall(function()
            NotifyOnNewObject(MENU_WBP, function()
                if doneRegistering then return end
                wantRegister = true
                if os.clock() - lastTick < TICK_DEAD_AFTER then return end
                pcall(function()
                    if tryHooks() then
                        doneRegistering = true
                        Log("Radial menu integration active (drain loop gone): Evolve entry in the hold-4 wheel")
                    end
                end)
            end)
        end)
        LoopAsync(1000, function()
            lastTick = os.clock()
            if doneRegistering then return true end -- all hooks in -> stop looping
            if not wantRegister then return false end -- idle: nothing pending, ref-free
            ExecuteInGameThread(function()
                pcall(function()
                    if doneRegistering then return end
                    wantRegister = false
                    if tryHooks() then
                        doneRegistering = true
                        Log("Radial menu integration active: Evolve entry in the hold-4 wheel")
                    end
                end)
            end)
            return false
        end)
    end
end

return RadialMenu
