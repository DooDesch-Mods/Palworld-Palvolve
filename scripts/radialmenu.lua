-- Palvolve radial menu integration: adds a real "Evolve" entry to the hold-4
-- player action wheel (pure Lua widget injection, mapped from the in-world
-- dumps 2026-07-13).
--
-- How the vanilla wheel works: WBP_PlayerRadialMenu builds the pal action
-- menu in CreatePlayerActionMenu. The generic WBP_CommonRadialMenuBase
-- (native base PalUIRadialMenuWidgetBase carries menuNum/nowSelectedIndex
-- and the hit testing) draws menuNum segments procedurally; the labels are
-- WBP_PlayerRadialMenu_MenuContent widgets on the menuCanvas of the nested
-- WBP_RadialMenu_base, registered per segment index via "Set Additional
-- Widget" (its Canvas is an OUT param, passed from Lua as an empty table).
-- RecalcMenuNum clears all registered label widgets, which is why vanilla
-- always calls it before adding labels.
--
-- UE4SS constraints (verified against the shipped v3.0.1 source): hooks on
-- /Game/ BP functions are POST-hooks (body already ran, parameter writes
-- are dead), so the wheel cannot be grown before vanilla lays out its
-- labels. The injection therefore runs after the build: capture the label
-- widgets, grow via a direct wheel:RecalcMenuNum(vanilla + 1) call (which
-- clears the canvas), then re-register every vanilla label plus our entry
-- at the last index.
--
-- Selecting the extra segment must NOT reach the vanilla decide switch:
-- unknown indices run the photo mode branch. The natives
-- UpdateSelectedIndex_ForMouse/ForPad/ForceAxis recompute nowSelectedIndex
-- from the cursor; a synchronous post-hook flips our index to -1 (vanilla
-- treats the release as "nothing selected") and remembers the hover, and
-- the wheel's Close/decide hooks then commit the evolution check
-- ourselves.

local Config = require("config")

local RadialMenu = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local MENU_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu.WBP_PlayerRadialMenu_C"
local WHEEL_WBP = "/Game/Pal/Blueprint/UI/CommonWidget/RadialMenu/WBP_CommonRadialMenuBase.WBP_CommonRadialMenuBase_C"
local CONTENT_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu_MenuContent.WBP_PlayerRadialMenu_MenuContent_C"
local RADIAL_NATIVE = "/Script/Pal.PalUIRadialMenuWidgetBase"

-- state of the currently open wheel
local ourIndex = nil
local ourWidget = nil
-- true while the cursor rests on our segment (maintained by the native
-- UpdateSelectedIndex post-hooks); consumed on wheel close/decide
local ourHover = false

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

local function labelText()
    -- vanilla labels are localized, so at least follow the game language
    -- for our own entry (fallback: English)
    local txt = "Evolve"
    pcall(function()
        local intl = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
        if not (intl and intl:IsValid()) then return end
        local lang = intl:GetCurrentLanguage()
        local s = type(lang) == "string" and lang or lang:ToString()
        if s:sub(1, 2) == "de" then txt = "Entwickeln" end
    end)
    return txt
end

local function makeLabelWidget(owner)
    local widget = nil
    pcall(function()
        local cls = StaticFindObject(CONTENT_WBP)
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local pc = FindFirstOf("PalPlayerController")
        if not (cls and cls:IsValid() and lib and lib:IsValid() and pc and pc:IsValid()) then return end
        widget = lib:Create(owner, cls, pc)
    end)
    if widget and widget:IsValid() then
        local okText = pcall(function() widget:SetText(FText(labelText())) end)
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

local function injectEntry(menu)
    local okAll, errAll = pcall(function()
        local wheel = menu.WBP_CommonRadialMenuBase
        if not (wheel and wheel:IsValid()) then
            if Config.devMode then Log("[radial] wheel reference missing") end
            return
        end
        -- the labels live on the menuCanvas of the nested WBP_RadialMenu_base
        local canvas = nil
        pcall(function()
            local base = wheel.WBP_RadialMenu_base
            if base and base:IsValid() then canvas = base.menuCanvas end
        end)
        if not (canvas and canvas:IsValid()) then
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

        if not (ourWidget and ourWidget:IsValid()) then
            ourWidget = makeLabelWidget(menu)
        end
        if not ourWidget then
            if Config.devMode then Log("[radial] label widget creation failed") end
            return
        end

        -- preferred path: let the wheel register everything itself, which
        -- keeps the AdditionalWidget map intact for hover highlights
        local sawErr = nil
        local function saw(idx, w)
            local okS, e = pcall(function()
                -- trailing table receives the Canvas OUT param
                wheel["Set Additional Widget"](wheel, idx, w, {})
            end)
            if not okS and not sawErr then sawErr = tostring(e) end
            return okS
        end
        local sawOk = true
        for i, lbl in ipairs(labels) do
            if lbl:IsValid() then
                sawOk = saw(i - 1, lbl) and sawOk
            end
        end
        sawOk = saw(vanillaCount, ourWidget) and sawOk
        if sawOk then
            ourIndex = vanillaCount
            if Config.devMode then
                Log(string.format("[radial] Evolve entry injected at index %d via Set Additional Widget", ourIndex))
            end
            return
        end
        if Config.devMode then
            Log("[radial] Set Additional Widget failed: " .. tostring(sawErr))
        end

        -- fallback: re-add and place everything ourselves. Preferred
        -- position source is the wheel's own CalcAdditionalWidgetPosition;
        -- if that call fails, derive the circle from the captured layout
        -- (anchors/alignment 0.5 center the coordinates on the wheel
        -- middle: pos = (r sin th, -r cos th), th clockwise from the top).
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
    end)
    if not okAll and Config.devMode then
        Log("[radial] injectEntry error: " .. tostring(errAll))
    end
end

function RadialMenu.init(evolutionCheck)
    if not (Config.radialMenu == nil or Config.radialMenu) then return end

    -- consume-once commit shared by the close/decide hooks
    local function commitOurs()
        if not ourHover then return end
        ourHover = false
        ExecuteInGameThread(function()
            pcall(evolutionCheck)
        end)
    end

    -- runs synchronously right after the native recomputed nowSelectedIndex:
    -- claim our segment and hide it from the vanilla decide switch (unknown
    -- indices would run the photo mode branch there)
    local function suppressHandler(self)
        pcall(function()
            local wheel = self:get()
            if not (wheel and wheel:IsValid() and isActionWheel(wheel)) then return end
            local idx = wheel.nowSelectedIndex
            if ourIndex ~= nil and idx == ourIndex then
                ourHover = true
                wheel.nowSelectedIndex = -1
            elseif idx >= 0 then
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
                ExecuteInGameThread(function()
                    pcall(function() injectEntry(menu) end)
                end)
            end,
        },
        {
            path = MENU_WBP .. ":OnDecidedPlayerActionMenu",
            fn = function(self, Index)
                commitOurs()
            end,
        },
        {
            -- release without a vanilla-known selection skips the decide
            -- path, so the wheel close is the reliable commit point
            path = WHEEL_WBP .. ":Close",
            fn = function(self)
                local wheel = nil
                pcall(function() wheel = self:get() end)
                if wheel and isActionWheel(wheel) then
                    commitOurs()
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
    if tryHooks() then
        Log("Radial menu integration active: Evolve entry in the hold-4 wheel")
    else
        -- the WBPs load with the HUD; retry until all hooks are in
        local done = false
        LoopAsync(5000, function()
            if done then return true end
            ExecuteInGameThread(function()
                if done then return end
                done = tryHooks()
                if done then
                    Log("Radial menu integration active: Evolve entry in the hold-4 wheel")
                end
            end)
            return done
        end)
    end
end

return RadialMenu
