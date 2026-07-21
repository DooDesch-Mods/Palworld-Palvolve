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

local function saw(wheel, idx, widget)
    -- trailing table receives the Canvas OUT param
    return pcall(function()
        wheel["Set Additional Widget"](wheel, idx, widget, {})
    end)
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
    local okGrow, errGrow = pcall(function() wheel:RecalcMenuNum(newCount) end)
    if not (okGrow and wheel.menuNum == newCount) then
        if Config.devMode then
            Log(string.format("[radial] grow to %d failed (ok=%s menuNum=%d%s)",
                newCount, tostring(okGrow), wheel.menuNum,
                okGrow and "" or (" err=" .. tostring(errGrow))))
        end
        return
    end

    -- grey out like Feed/Pet while no own pal with options is summoned
    local offered = true
    if api and api.canOffer then
        local okAvail, avail = pcall(api.canOffer)
        offered = okAvail and avail == true
    end
    if offered and ourWidgetGreyed and ourWidget then
        -- recreating restores the widget's default text color
        pcall(function()
            if ourWidget:IsValid() then ourWidget:RemoveFromParent() end
        end)
        ourWidget = nil
        ourWidgetGreyed = false
    end
    if not (ourWidget and ourWidget:IsValid()) then
        ourWidget = makeLabelWidget(menu, labelText())
        ourWidgetGreyed = false
    end
    if not ourWidget then
        if Config.devMode then Log("[radial] label widget creation failed") end
        return
    end
    local relabel = toText(labelText())
    if relabel then pcall(function() ourWidget:SetText(relabel) end) end
    if not offered and not ourWidgetGreyed then
        local flat = readGrey(menu)
        ourWidgetGreyed = applyGrey(ourWidget, flat)
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
        if lbl:IsValid() then
            sawOk = saw(wheel, i - 1, lbl) and sawOk
        end
    end
    sawOk = saw(wheel, vanillaCount, ourWidget) and sawOk
    if sawOk then
        ourIndex = vanillaCount
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
    local function calcPos(idx)
        local out = {}
        local okC = pcall(function()
            wheel:CalcAdditionalWidgetPosition(idx, out)
        end)
        if okC and type(out.X) == "number" and type(out.Y) == "number" then
            return out.X, out.Y
        end
        if radius < 1 then return nil end
        local th = angle0 + idx * (2 * math.pi / newCount)
        return radius * math.sin(th), -radius * math.cos(th)
    end
    local function addAndPlace(widget, idx)
        pcall(function()
            canvas:AddChildToCanvas(widget)
            local slot = canvasSlot(widget)
            slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
            slot:SetAlignment({ X = 0.5, Y = 0.5 })
            slot:SetAutoSize(true)
            local px, py = calcPos(idx)
            if px then slot:SetPosition({ X = px, Y = py }) end
        end)
    end
    for i, lbl in ipairs(labels) do
        if lbl:IsValid() then addAndPlace(lbl, i - 1) end
    end
    addAndPlace(ourWidget, vanillaCount)
    ourIndex = vanillaCount
    if Config.devMode then
        Log(string.format("[radial] Evolve entry injected at index %d via slot fallback", ourIndex))
    end
end

-- ---------------------------------------------------------------- submenu

local function optionLabel(opt)
    return opt.label or (opt.pair and opt.pair.to) or "?"
end

local function buildSubmenu(menu)
    local wheel = wheelOf(menu)
    if not wheel then subMode = false; return end
    local options = subOptions
    if not (options and #options > 0) then subMode = false; return end

    -- a single option still needs two segments for a drawable wheel
    local count = math.max(#options, 2)
    local okGrow = pcall(function() wheel:RecalcMenuNum(count) end)
    if not (okGrow and wheel.menuNum == count) then
        if Config.devMode then Log("[radial] submenu recalc failed") end
        subMode = false
        return
    end

    -- fresh widgets per build (runs once per submenu open): the default
    -- text color is the available state, blocked options get vanilla's
    -- no-otomo grey
    local grey = readGrey(menu)
    for i, opt in ipairs(options) do
        local w = makeLabelWidget(menu, optionLabel(opt))
        subWidgets[i] = w
        if w then
            if opt.blocked then
                applyGrey(w, grey)
            end
            saw(wheel, i - 1, w)
        end
    end

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
            -- stale submenu state (reopen never happened): fall back
            subMode = false
            subOptions = nil
            subHoverIdx = nil
        end
        if subMode then
            buildSubmenu(menu)
        else
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
                local opts, reason = api.listOptions()
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
                if wheel and wheel:IsValid() and isActionWheel(wheel) then
                    if cancelRequested then
                        if Config.devMode and (ourHover or subMode) then
                            Log("[radial] close: cancelled, nothing committed")
                        end
                        subMode = false
                        subOptions = nil
                        subHoverIdx = nil
                    elseif subMode then
                        subCommit()
                    else
                        commitOurs()
                    end
                    restoreHoverSound(wheel)
                    wheelOpen = false
                    cancelRequested = false
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
                if Config.devMode then Log("[radial] cancel gesture (4) detected") end
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
    if not doneRegistering then
        local wantRegister = true -- one retry after load, then armed by the notify
        pcall(function()
            NotifyOnNewObject(MENU_WBP, function() wantRegister = true end)
        end)
        LoopAsync(1000, function()
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
