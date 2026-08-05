-- statuspage.lua: shows the displayed pal's configured evolutions and their
-- requirements (level, conditions, stone/material costs) on the pal status
-- page (the MonsterDetail overlay: WBP_PalStatus, native base
-- UPalUICharacterStatus). Pure presentation: it reads Palvolve's tree
-- through the evolution module's describe API and paints text labels; no
-- game state is ever written, and the first structural failure collapses
-- the feature for the session (fail closed, cosmetic only).
--
-- Triggers are NATIVE functions, registrable at init with no lazy-load
-- dance (unlike the radial's WBP hooks):
--   PalHUDService:ShowCommonUI        page OPEN; WBPType 2 = MonsterDetail,
--                                     the dispatch Parameter carries the
--                                     displayed pal's IndividualHandle
--   PalUIStatusModel:ChangeIndex /
--   OnClickedPalIcon / Initialize     pal switch inside the open page
-- All are post-hooks: the page/model state is settled when we read it.
--
-- The render defers to the game thread, re-finds the live page by its
-- NATIVE class (FindAllOf("PalUICharacterStatus") - the Base Radius
-- Improved approach, proven on this build), and places label widgets (the
-- mod's own radial label recipe) on the page's canvas panel. Placement is
-- config-tunable (Config.statusEvolutions.x/y): the WBP's internal layout
-- is pak-packed and unreadable from disk, so devMode logs a child census
-- on the first render to guide future anchor refinements.
local Config = require("config")
local Role = require("role")
local I18n = require("i18n")

local StatusPage = {}

local MONSTER_DETAIL = 2 -- EPalWidgetBlueprintType::MonsterDetail
-- the mod's proven text label class (radialmenu.lua uses the same recipe)
local CONTENT_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu_MenuContent.WBP_PlayerRadialMenu_MenuContent_C"

local api = nil          -- { describe = fn(param) -> lines[] or nil }
local disabled = false   -- fail-closed latch
local pageRef = nil      -- the page instance our labels belong to
local labels = {}        -- created label widgets, index -> widget
local censusDone = false

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local function cfg()
    return Config.statusEvolutions or {}
end

-- FText fallback, same rationale as radialmenu.lua's toText: the FText()
-- helper can stay broken for a session when its one-time lookup ran too
-- early; the engine's own converter does a fresh lookup via reflection
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
            Log("[status] FText broken this session - using engine text converter")
        end
        return converted
    end
    return nil
end

local function setLabelText(widget, text)
    local t = toText(text)
    if not t then return end
    pcall(function() widget:SetText(t) end)
end

local function makeLabel(owner, text)
    local widget = nil
    pcall(function()
        local cls = StaticFindObject(CONTENT_WBP)
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        -- widget owner must be THIS machine's player controller (listen
        -- hosts: FindFirstOf could return a remote client's controller)
        local pc = Role.getLocalPlayerController()
        if not (cls and cls:IsValid() and lib and lib:IsValid() and pc and pc:IsValid()) then return end
        widget = lib:Create(owner, cls, pc)
    end)
    if not (widget and widget:IsValid()) then return nil end
    setLabelText(widget, text)
    return widget
end

-- find the live status page by its NATIVE class: avoids the /Game path,
-- the lazy-load retry dance and any BP-subclass question at once
-- BOTH pal-detail screens: the MonsterDetail overlay (native class) and
-- the main-menu Party tab (BP class; backed by PalUIStatusModel, whose
-- hooks fire for it - the Food/EatingHabits rows prove the pairing)
local PAGE_CLASSES = { "PalUICharacterStatus", "WBP_MainMenu_Pal_00_C" }

local function findPage()
    local onScreen, lastValid = nil, nil
    pcall(function()
        for _, clsName in ipairs(PAGE_CLASSES) do
            for _, w in ipairs(FindAllOf(clsName) or {}) do
                if w and w:IsValid() then
                    -- a closed-but-not-yet-GC'd page can precede the live
                    -- one: prefer an on-screen instance, else NEWEST valid
                    lastValid = w
                    local vp = false
                    pcall(function() vp = w:IsInViewport() == true end)
                    if vp then onScreen = w end
                end
            end
        end
    end)
    return onScreen or lastValid
end

local function isCanvas(w)
    local ok, full = pcall(function() return w:GetClass():GetFullName() end)
    return ok and type(full) == "string" and full:find("CanvasPanel", 1, true) ~= nil
end

-- first canvas panel reachable from the page root (the root itself or one
-- level down); the WBP's internals are pak-packed, so this stays heuristic
local function findCanvas(page)
    local canvas = nil
    pcall(function()
        local root = page:GetRootWidget()
        if not (root and root:IsValid()) then return end
        if isCanvas(root) then
            canvas = root
            return
        end
        local n = 0
        pcall(function() n = root:GetChildrenCount() end)
        for i = 0, (n or 0) - 1 do
            local child = nil
            pcall(function() child = root:GetChildAt(i) end)
            if child and child:IsValid() and isCanvas(child) then
                canvas = child
                return
            end
        end
    end)
    return canvas
end

-- devMode: one-time dump of the page's top-level structure, the input for
-- upgrading the canvas placement to a native-styled anchored row later
local function census(page)
    if censusDone or not Config.devMode then return end
    censusDone = true
    pcall(function()
        local root = page:GetRootWidget()
        if not (root and root:IsValid()) then return end
        Log("[status] census root: " .. root:GetClass():GetFullName())
        local n = 0
        pcall(function() n = root:GetChildrenCount() end)
        for i = 0, (n or 0) - 1 do
            local child = nil
            pcall(function() child = root:GetChildAt(i) end)
            if child and child:IsValid() then
                Log(string.format("[status] census child %d: %s",
                    i, child:GetClass():GetFullName()))
            end
        end
    end)
end

local function render(param)
    if disabled then return end
    -- param == false: blank-render sentinel (unresolvable slot; the
    -- previous pal's lines must not stay painted under the wrong stats)
    if param ~= false and not (param and param:IsValid()) then return end
    local lines = nil
    if param ~= false then
        pcall(function() lines = api.describe(param) end)
    end
    local page = findPage()
    if not page then return end
    if page ~= pageRef then
        -- fresh page instance: the old one (and our labels on it) is gone
        labels = {}
        pageRef = page
    end
    census(page)
    if not lines or #lines == 0 then
        -- species without configured evolutions: blank the block
        for _, w in ipairs(labels) do
            pcall(function() if w:IsValid() then setLabelText(w, " ") end end)
        end
        return
    end
    table.insert(lines, 1, I18n.msg("statusEvolveHeader"))
    local c = cfg()
    local maxLines = math.floor(tonumber(c.maxLines) or 8)
    local x = tonumber(c.x) or 820
    local y = tonumber(c.y) or 840
    local lineH = tonumber(c.lineHeight) or 26
    local canvas = findCanvas(page)
    if not canvas then
        -- soft skip, NOT the disable latch: with two page classes a canvas
        -- miss on one layout must never kill the block on the other
        if Config.devMode then
            Log("[status] no canvas panel reachable on this page - skipped")
        end
        return
    end
    -- the label class is a /Game BP that only exists once its asset has
    -- loaded (guaranteed after the radial wheel opened once). Not-loaded is
    -- TRANSIENT: skip this render and retry on a later open instead of
    -- tripping the fail-closed latch reserved for structural failures.
    local needCreate = false
    for i = 1, math.min(#lines, maxLines) do
        local w = labels[i]
        if not (w and w:IsValid()) then
            needCreate = true
            break
        end
    end
    if needCreate then
        local clsReady = false
        pcall(function()
            local cls = StaticFindObject(CONTENT_WBP)
            clsReady = (cls and cls:IsValid()) == true
        end)
        if not clsReady then return end
    end
    for i = 1, math.min(#lines, maxLines) do
        local w = labels[i]
        if w and w:IsValid() then
            -- the game may reset runtime-created labels when the page
            -- re-constructs: re-assert text AND visibility every refresh
            setLabelText(w, lines[i])
            pcall(function() w:SetVisibility(4) end)
        else
            w = makeLabel(page, lines[i])
            if not w then
                disabled = true
                Log("[status] label creation failed - evolution block disabled this session")
                return
            end
            local placed = pcall(function()
                canvas:AddChildToCanvas(w)
                local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
                local slot = lib:SlotAsCanvasSlot(w)
                slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
                slot:SetAlignment({ X = 0, Y = 0 })
                slot:SetAutoSize(true)
                slot:SetPosition({ X = x, Y = y + (i - 1) * lineH })
                w:SetVisibility(4) -- SelfHitTestInvisible: never eats clicks
            end)
            if not placed then
                disabled = true
                Log("[status] label placement failed - evolution block disabled this session")
                return
            end
            labels[i] = w
        end
    end
    -- surplus labels from a previous, longer readout
    for i = #lines + 1, #labels do
        if labels[i] then
            pcall(function()
                if labels[i]:IsValid() then setLabelText(labels[i], " ") end
            end)
        end
    end
end

-- newest-wins coalescing: the hooks fire in bursts on open (dispatch +
-- model init + index set); one short one-shot LoopAsync lets the page
-- finish constructing, then a single render runs with the latest pal
local pendingParam = nil
local pumpArmed = false
local function schedule(handle)
    if disabled then return end
    local param = nil
    pcall(function()
        if handle and handle:IsValid() then
            param = handle:TryGetIndividualParameter()
        end
    end)
    if not (param and param:IsValid()) then
        param = false -- blank-render sentinel, see render()
    end
    pendingParam = param
    if pumpArmed then return end
    pumpArmed = true
    LoopAsync(150, function()
        pumpArmed = false
        local p = pendingParam
        pendingParam = nil
        ExecuteInGameThread(function()
            local ok, err = pcall(render, p)
            if not ok then
                disabled = true
                Log("[status] render FAIL (disabled this session): " .. tostring(err))
            end
        end)
        return true
    end)
end

function StatusPage.init(evolutionApi)
    api = evolutionApi
    if (cfg()).enabled == false then return end
    if Role.isDedicated() then return end

    local registered = 0

    -- page OPEN: the HUD service dispatch carrying the displayed pal
    if pcall(function()
        RegisterHook("/Script/Pal.PalHUDService:ShowCommonUI",
            function() end,
            function(self, WBPType, Parameter)
                pcall(function()
                    -- raw-type probe BEFORE the gate: zero [status] lines on
                    -- every surface means either the type value or the entry
                    -- point itself is wrong on this build - this line tells
                    -- us which (and what the real values are)
                    if Config.devMode then Log(string.format("[status] ShowCommonUI type=%g", WBPType:get())) end
                    if WBPType:get() ~= MONSTER_DETAIL then return end
                    local dispatch = Parameter:get()
                    if not (dispatch and dispatch:IsValid()) then return end
                    schedule(dispatch.IndividualHandle)
                end)
            end)
    end) then registered = registered + 1 end

    -- pal SWITCH inside the open page (post-hooks: model state is settled)
    if pcall(function()
        RegisterHook("/Script/Pal.PalUIStatusModel:ChangeIndex",
            function() end,
            function(self, Index)
                pcall(function()
                    if Config.devMode then Log("[status] ChangeIndex fired") end
                    local model = self:get()
                    if not (model and model:IsValid()) then return end
                    schedule(model:GetDisplayPalHandle(Index:get()))
                end)
            end)
    end) then registered = registered + 1 end

    if pcall(function()
        RegisterHook("/Script/Pal.PalUIStatusModel:OnClickedPalIcon",
            function() end,
            function(self, Index)
                pcall(function()
                    if Config.devMode then Log("[status] OnClickedPalIcon fired") end
                    local model = self:get()
                    if not (model and model:IsValid()) then return end
                    schedule(model:GetDisplayPalHandle(Index:get()))
                end)
            end)
    end) then registered = registered + 1 end

    if pcall(function()
        RegisterHook("/Script/Pal.PalUIStatusModel:Initialize",
            function() end,
            function(self, Handles)
                pcall(function()
                    if Config.devMode then Log("[status] Initialize fired") end
                    local model = self:get()
                    if not (model and model:IsValid()) then return end
                    schedule(model:GetDisplayPalHandle(model:GetNowSelectedIndex()))
                end)
            end)
    end) then registered = registered + 1 end

    if registered > 0 then
        Log(string.format("status page evolutions active (%d/4 hooks)", registered))
    else
        Log("status page evolutions: no hooks registered - feature inactive")
    end

    -- devMode-only SELECTION CENSUS (2026-07-26): the Party tab provably never
    -- calls ChangeIndex/OnClickedPalIcon/Initialize - its WBP holds the
    -- selection index privately and pulls data through pure per-index getters
    -- (SDK: PalUIStatusModel is all BlueprintPure readers; the callers pass
    -- the index). This census post-hooks the getter family and logs each
    -- fn's index TRANSITIONS only (pure getters may be frame-bound - a
    -- same-index refire never logs), so one browsing session reveals which
    -- getter uniquely tracks the SELECTED pal vs the party icon strip.
    -- Best-effort diagnostics: never load-bearing, never counted in
    -- `registered`, removed once the real trigger ships.
    if Config.devMode then
        local censusLast = {}
        local function regCensus(fn)
            local ok = pcall(RegisterHook, "/Script/Pal.PalUIStatusModel:" .. fn,
                function() end,
                function(self, Index)
                    pcall(function()
                        local i = Index:get()
                        if censusLast[fn] ~= i then
                            censusLast[fn] = i
                            Log(string.format("[status-census] %s idx=%g", fn, i))
                        end
                    end)
                end)
            if not ok then Log("[status-census] " .. fn .. " not hookable") end
        end
        regCensus("GetDisplayPalHandle")
        regCensus("GetDisplayEatingHabits")
        regCensus("GetDisplayPassiveSkillList")
        regCensus("GetDisplayCoopActionName")
    end
end

return StatusPage
