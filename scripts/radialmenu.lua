-- Palvolve radial menu integration: adds a real "Evolve" entry to the hold-4
-- player action wheel (pure Lua widget injection, mapped from the in-world
-- dump 2026-07-13).
--
-- How the vanilla wheel works: WBP_PlayerRadialMenu builds the pal action
-- menu in CreatePlayerActionMenu - the generic WBP_CommonRadialMenuBase
-- draws menuNum segments procedurally and the entry labels are
-- WBP_PlayerRadialMenu_MenuContent widgets registered per segment index via
-- "Set Additional Widget" (Canvas is an OUT param there). Label positions
-- are computed against menuNum AT REGISTRATION TIME, so growing the wheel
-- after the build misplaces every vanilla label. The open flow calls
-- RecalcMenuNum right before CreatePlayerActionMenu, so we bump its
-- newMenuNum parameter whenever the receiving wheel belongs to
-- WBP_PlayerRadialMenu (outer-chain check): vanilla then positions all of
-- its own labels for the extra segment already and we only append our
-- label to the reserved last index after the build. The committed segment
-- lands in OnDecidedPlayerActionMenu(Index), whose BP switch simply
-- ignores indices it does not know - so the appended entry is exclusively
-- ours.

local Config = require("config")

local RadialMenu = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local MENU_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu.WBP_PlayerRadialMenu_C"
local WHEEL_WBP = "/Game/Pal/Blueprint/UI/CommonWidget/RadialMenu/WBP_CommonRadialMenuBase.WBP_CommonRadialMenuBase_C"
local CONTENT_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu_MenuContent.WBP_PlayerRadialMenu_MenuContent_C"

-- state of the currently open wheel
local ourIndex = nil
-- set when the action wheel's RecalcMenuNum was bumped; consumed by the
-- deferred injection so a rebuild without a preceding bump never adds a
-- label to a segment that does not exist
local pendingBump = false

-- The open flow calls RecalcMenuNum BEFORE CreatePlayerActionMenu (3 ms
-- apart in the live log), so a build-window flag can never cover it.
-- Identify the action wheel by its outer chain instead: the inner
-- WBP_CommonRadialMenuBase lives in WBP_PlayerRadialMenu's widget tree.
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

local function injectEntry(menu)
    pcall(function()
        local wheel = menu.WBP_CommonRadialMenuBase
        if not (wheel and wheel:IsValid()) then
            if Config.devMode then Log("[radial] wheel reference missing") end
            return
        end
        if not pendingBump then
            ourIndex = nil
            if Config.devMode then Log("[radial] no bump before this build - entry skipped") end
            return
        end
        pendingBump = false
        -- the RecalcMenuNum pre-hook already reserved the last segment
        ourIndex = wheel.menuNum - 1
        local widget = makeLabelWidget(menu)
        if not widget then
            ourIndex = nil
            if Config.devMode then Log("[radial] label widget creation failed") end
            return
        end
        local okSet = pcall(function()
            -- last argument fills the Canvas OUT param slot; the value
            -- itself is ignored by the function
            wheel["Set Additional Widget"](wheel, ourIndex, widget, wheel.CanvasPanel_Inner)
        end)
        if Config.devMode then
            Log(string.format("[radial] Evolve entry injected at index %d (menuNum %d, set=%s)",
                ourIndex, wheel.menuNum, tostring(okSet)))
        end
    end)
end

function RadialMenu.init(evolutionCheck)
    if not (Config.radialMenu == nil or Config.radialMenu) then return end

    -- post callbacks on script hooks never fired in this UE4SS build (the
    -- live log showed pre lines but no post lines), so everything runs in
    -- pre callbacks; the injection defers one tick, which lands after the
    -- BP body has completed
    local hooks = {
        {
            path = WHEEL_WBP .. ":RecalcMenuNum",
            fn = function(self, NewMenuNum)
                local wheel = nil
                pcall(function() wheel = self:get() end)
                if not (wheel and isActionWheel(wheel)) then return end
                pcall(function()
                    local n = NewMenuNum:get()
                    -- log BEFORE the write-back: if set() dies natively,
                    -- the log tail still shows how far we got
                    if Config.devMode then
                        Log(string.format("[radial] bumping menuNum %d -> %d", n, n + 1))
                    end
                    NewMenuNum:set(n + 1)
                    pendingBump = true
                end)
            end,
        },
        {
            path = MENU_WBP .. ":CreatePlayerActionMenu",
            fn = function(self)
                if Config.devMode then Log("[radial] action menu build begin") end
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
