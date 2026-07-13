-- Palvolve radial menu integration: adds a real "Evolve" entry to the hold-4
-- player action wheel (pure Lua widget injection, mapped from the in-world
-- dump 2026-07-13).
--
-- How the vanilla wheel works: WBP_PlayerRadialMenu builds the pal action
-- menu in CreatePlayerActionMenu - the generic WBP_CommonRadialMenuBase
-- draws menuNum segments procedurally and the entry labels are
-- WBP_PlayerRadialMenu_MenuContent widgets registered per segment index via
-- "Set Additional Widget" (Canvas is an OUT param there). Label positions
-- are computed against menuNum AT REGISTRATION TIME.
--
-- UE4SS constraint (verified against the shipped v3.0.1 build's source):
-- RegisterHook on /Game/ BP functions is always a POST-hook - the callback
-- runs after the BP body, parameter writes land in dead locals and a post
-- callback argument is silently ignored. So there is no way to grow the
-- wheel before vanilla lays out its labels; instead the injection runs
-- after the build and redoes the layout: grow via a direct
-- wheel:RecalcMenuNum(vanilla + 1) call, re-register the vanilla labels
-- for the new segment count, then append our label to the last index.
-- The committed segment lands in OnDecidedPlayerActionMenu(Index), whose
-- BP switch simply ignores indices it does not know - so the appended
-- entry is exclusively ours.

local Config = require("config")

local RadialMenu = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local MENU_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu.WBP_PlayerRadialMenu_C"
local CONTENT_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu_MenuContent.WBP_PlayerRadialMenu_MenuContent_C"

-- state of the currently open wheel
local ourIndex = nil
local ourWidget = nil

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
        -- the labels live on the menuCanvas of the nested WBP_RadialMenu_base,
        -- not on the wheel's own CanvasPanel_Inner (in-world dump 2026-07-13)
        local canvas = nil
        pcall(function()
            local base = wheel.WBP_RadialMenu_base
            if base and base:IsValid() then canvas = base.menuCanvas end
        end)
        if not (canvas and canvas:IsValid()) then
            if Config.devMode then Log("[radial] menuCanvas missing") end
            return
        end

        -- drop our label from the previous open: a vanilla rebuild only
        -- overwrites indices 0..N-1 and would leave ours as a ghost
        if ourWidget then
            pcall(function()
                if ourWidget:IsValid() then ourWidget:RemoveFromParent() end
            end)
            ourWidget = nil
        end
        ourIndex = nil

        -- census: the vanilla label widgets currently on the wheel canvas,
        -- in add order = segment index order
        local labels = {}
        local childCount = canvas:GetChildrenCount()
        for i = 0, childCount - 1 do
            local child = canvas:GetChildAt(i)
            if child and child:IsValid() then
                local cls = child:GetClass():GetFullName()
                if string.find(cls, "WBP_PlayerRadialMenu_MenuContent_C", 1, true) then
                    table.insert(labels, child)
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

        -- capture the layout BEFORE growing: positions still reflect the
        -- vanilla segment count and give us radius and base angle
        local geo = {}
        for i, lbl in ipairs(labels) do
            pcall(function()
                local p = canvasSlot(lbl):GetPosition()
                geo[i] = { x = p.X, y = p.Y }
            end)
        end
        if Config.devMode and geo[1] then
            Log(string.format("[radial] label0 pos=(%.1f, %.1f)", geo[1].x, geo[1].y))
        end

        -- grow the wheel: a direct call runs the full vanilla redraw
        local okGrow, errGrow = pcall(function() wheel:RecalcMenuNum(newCount) end)
        if Config.devMode then
            Log(string.format("[radial] grow to %d: ok=%s menuNum=%d%s",
                newCount, tostring(okGrow), wheel.menuNum,
                okGrow and "" or (" err=" .. tostring(errGrow))))
        end
        if not (okGrow and wheel.menuNum == newCount) then return end

        ourWidget = makeLabelWidget(menu)
        if not ourWidget then
            if Config.devMode then Log("[radial] label widget creation failed") end
            return
        end

        -- preferred path: let the wheel register everything itself, which
        -- also keeps the AdditionalWidget map intact for hover highlights
        local sawErr = nil
        local function saw(idx, w)
            local okS, e = pcall(function()
                wheel["Set Additional Widget"](wheel, idx, w, canvas)
            end)
            if not okS and not sawErr then sawErr = tostring(e) end
            return okS
        end
        local sawOk = true
        for i, lbl in ipairs(labels) do
            sawOk = saw(i - 1, lbl) and sawOk
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

        -- fallback: reposition the labels ourselves through the canvas
        -- slots. Anchors/alignment 0.5 center the coordinates on the wheel
        -- middle: pos = (r sin th, -r cos th), th clockwise from the top.
        local base = geo[1]
        local radius = base and math.sqrt(base.x * base.x + base.y * base.y) or 0
        if radius < 1 then
            if Config.devMode then Log("[radial] fallback geometry unusable") end
            return
        end
        local offset = math.atan(base.x, -base.y)
        local function place(widget, idx)
            local th = offset + idx * (2 * math.pi / newCount)
            pcall(function()
                canvasSlot(widget):SetPosition({
                    X = radius * math.sin(th),
                    Y = -radius * math.cos(th),
                })
            end)
        end
        for i, lbl in ipairs(labels) do
            place(lbl, i - 1)
        end
        local okAdd, errAdd = pcall(function()
            canvas:AddChildToCanvas(ourWidget)
            local slot = canvasSlot(ourWidget)
            slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
            slot:SetAlignment({ X = 0.5, Y = 0.5 })
            slot:SetAutoSize(true)
        end)
        if not okAdd then
            if Config.devMode then Log("[radial] fallback add failed: " .. tostring(errAdd)) end
            pcall(function() ourWidget:RemoveFromParent() end)
            ourWidget = nil
            return
        end
        place(ourWidget, vanillaCount)
        ourIndex = vanillaCount
        if Config.devMode then
            Log(string.format("[radial] Evolve entry injected at index %d via slot fallback (no hover highlight)", ourIndex))
        end
    end)
    if not okAll and Config.devMode then
        Log("[radial] injectEntry error: " .. tostring(errAll))
    end
end

function RadialMenu.init(evolutionCheck)
    if not (Config.radialMenu == nil or Config.radialMenu) then return end

    local hooks = {
        {
            -- fires AFTER the BP body (script hooks are post-hooks); the
            -- injection defers one more tick so the open flow has settled
            path = MENU_WBP .. ":CreatePlayerActionMenu",
            fn = function(self)
                if Config.devMode then Log("[radial] action menu built") end
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
                local idx = nil
                pcall(function() idx = Index:get() end)
                if idx ~= nil and ourIndex ~= nil and idx == ourIndex then
                    ExecuteInGameThread(function()
                        pcall(evolutionCheck)
                    end)
                end
            end,
        },
    }
    local registered = {}
    local function tryHooks()
        local allOk = true
        for _, h in ipairs(hooks) do
            if not registered[h.path] then
                local ok = pcall(RegisterHook, h.path, h.fn)
                registered[h.path] = ok
                allOk = allOk and ok
            end
        end
        return allOk
    end
    if tryHooks() then
        Log("Radial menu integration active: Evolve entry in the hold-4 wheel")
    else
        -- the WBP loads with the HUD; retry until all hooks are in
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
