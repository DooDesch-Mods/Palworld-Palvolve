-- Palvolve radial menu integration: adds a real "Evolve" entry to the hold-4
-- player action wheel (pure Lua widget injection, mapped from the in-world
-- dump 2026-07-13).
--
-- How the vanilla wheel works: WBP_PlayerRadialMenu builds the pal action
-- menu in CreatePlayerActionMenu - the generic WBP_CommonRadialMenuBase
-- draws menuNum segments procedurally and the entry labels are
-- WBP_PlayerRadialMenu_MenuContent widgets registered per segment index via
-- "Set Additional Widget". The committed segment lands in
-- OnDecidedPlayerActionMenu(Index), whose BP switch simply ignores indices
-- it does not know - so an appended entry is exclusively ours.

local Config = require("config")

local RadialMenu = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local MENU_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu.WBP_PlayerRadialMenu_C"
local CONTENT_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu_MenuContent.WBP_PlayerRadialMenu_MenuContent_C"

-- state of the currently open wheel
local ourIndex = nil

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
        local okText = pcall(function() widget:SetText(FText("Evolve")) end)
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
        local vanillaCount = wheel.menuNum
        -- CreatePlayerActionMenu rebuilds the wheel on every open, so the
        -- menuNum we see here is the vanilla count and our slot is appended
        -- fresh each time
        ourIndex = vanillaCount
        local widget = makeLabelWidget(menu)
        if not widget then
            ourIndex = nil
            if Config.devMode then Log("[radial] label widget creation failed") end
            return
        end
        wheel:RecalcMenuNum(vanillaCount + 1)
        local okSet = pcall(function() wheel["Set Additional Widget"](wheel, ourIndex, widget) end)
        if Config.devMode then
            Log(string.format("[radial] Evolve entry injected at index %d (vanilla %d, set=%s)",
                ourIndex, vanillaCount, tostring(okSet)))
        end
    end)
end

function RadialMenu.init(evolutionCheck)
    if not (Config.radialMenu == nil or Config.radialMenu) then return end

    local hooks = {
        {
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
        -- the WBP loads with the HUD; retry until both hooks are in
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
