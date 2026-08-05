-- palpedia.lua: an "Evolutions" tab on the Palpedia. The tab is a text
-- label overlaid beside the game's own Stats/Habitat tabs; clicking it
-- opens a panel listing what the selected species evolves into - each
-- target tagged as an Evolution or an (element) Adaptation, name line
-- plus an indented requirements line, a blank spacer between targets.
-- Clicking Stats or Habitat closes the panel (real tab semantics), the
-- toggle key (default V) works as the keyboard shortcut, and everything
-- hides when the Palpedia leaves the screen.
--
-- (A CLONE of the game's own WBP_Paldex_tab widget was tried first for a
-- native look: the clone attaches but always renders as an EMPTY
-- zero-size shell - its label/brush are injected by sealed owner logic
-- and its subtree is unreachable from script, so there is nothing to
-- dress. The overlay label is the honest version of the same idea.)
--
-- Click handling is GEOMETRY HIT-TESTING, not widget events: UMG click
-- delegates cannot be bound from UE4SS Lua, but every widget reports its
-- viewport rectangle (SlateBlueprintLibrary LocalToViewport - the same
-- out-param call style radialmenu's CalcAdditionalWidgetPosition proved)
-- and the mouse position is readable. The CLICK itself arrives through a
-- raw UE4SS keybind on LeftMouseButton: menus run in UI input mode where
-- Slate consumes the button before the player controller's input stack
-- sees it, so IsInputKeyDown polling stays silent there - the same raw
-- input layer that makes the toggle key work in menus delivers the
-- click. The old poll survives as a fallback for input modes that still
-- feed it. A 120ms watch ticks ONLY while the Palpedia is on screen, on
-- cached references - no object scans per tick (the earlier per-tick
-- scans were a measurable stutter).
--
-- Pure presentation, fail-closed: no game state is ever written.
local Config = require("config")
local Role = require("role")
local I18n = require("i18n")

local Palpedia = {}

-- the mod's proven text label class (same recipe as radialmenu/statuspage)
local CONTENT_WBP = "/Game/Pal/Blueprint/UI/PlayerRadialMenu/WBP_PlayerRadialMenu_MenuContent.WBP_PlayerRadialMenu_MenuContent_C"
local TAB_WBP_CLASS = "WBP_Paldex_tab_C" -- the game's own tab widget class
                                         -- (hit-tested for close-on-click)

local api = nil          -- { describeSpecies = fn(idString) -> entries[] or nil }
local disabled = false   -- fail-closed latch
local pageRef = nil      -- live Paldex widget, captured from the open hook
local hudRef = nil       -- PalHUDService, found once and cached
local mapRef = nil       -- WBP_Paldex_Map widget (Habitat tab), cached
local labels = {}        -- panel label widgets, index -> widget. SPARSE:
                         -- spacer slots hold no widget, so ipairs/# are
                         -- unusable - iterate 1..labelsMax with nil checks
local labelsMax = 0      -- highest slot ever occupied this page instance
local ourTab = nil       -- our Evolutions tab label (screen-space overlay)
local gameTabs = {}      -- the game's own tab widgets (for close-on-click)
local panelShown = false
local lastWant = false   -- edge detector for show/hide transitions
local mouseWasDown = false
local lastShownId = nil
local watching = false
local watchGen = 0
local censusDone = false

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local function cfg()
    return Config.palpediaEvolutions or {}
end

-- FText fallback, same rationale as radialmenu.lua's toText
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
            Log("[palpedia] FText broken this session - using engine text converter")
        end
        return converted
    end
    return nil
end

-- returns true only when a text object was actually applied - a silent
-- no-op here would let a reused label keep a previous species' line
local function setLabelText(widget, text)
    local t = toText(text)
    if not t then return false end
    local applied = false
    pcall(function()
        widget:SetText(t)
        applied = true
    end)
    return applied
end

local function labelClassReady()
    local ready = false
    pcall(function()
        local cls = StaticFindObject(CONTENT_WBP)
        ready = (cls and cls:IsValid()) == true
    end)
    return ready
end

local function makeLabel(owner, text)
    local widget = nil
    pcall(function()
        local cls = StaticFindObject(CONTENT_WBP)
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local pc = Role.getLocalPlayerController()
        if not (cls and cls:IsValid() and lib and lib:IsValid() and pc and pc:IsValid()) then return end
        widget = lib:Create(owner, cls, pc)
    end)
    if not (widget and widget:IsValid()) then return nil end
    setLabelText(widget, text)
    return widget
end

-- place (or re-place) an overlay label at viewport position x,y. An optional
-- scale shrinks the label around its TOP-LEFT (the anchor we position by -
-- the default centre pivot would shift a scaled label off its x/y); scaling
-- is cosmetic, so its own failure is swallowed rather than failing the place.
local function placeOverlay(w, x, y, scale)
    return pcall(function()
        if not w:IsInViewport() then w:AddToViewport(120) end
        w:SetPositionInViewport({ X = x, Y = y }, true)
        if scale and scale > 0 and scale ~= 1 then
            pcall(function()
                w:SetRenderTransformPivot({ X = 0, Y = 0 })
                w:SetRenderScale({ X = scale, Y = scale })
            end)
        end
        w:SetVisibility(4) -- SelfHitTestInvisible: never eats clicks
    end)
end

-- soft-wrap requirement lines that would overflow the panel: split at the
-- separators the lines are actually joined with - ", " (the reqs/costs
-- top-level joiner) and " + " (the conditions joiner) - never mid-word.
-- A break re-emits the separator that preceded it ("," / " +") so the reader
-- knows the line continues; continuation lines indent past the reqs indent.
-- Lines without separators (names, header) pass through however long.
local function wrapPanelLines(lines, wrapChars)
    if not wrapChars or wrapChars <= 0 then return lines end
    local out = {}
    for _, line in ipairs(lines) do
        if #line <= wrapChars
            or not (line:find(" + ", 1, true) or line:find(", ", 1, true)) then
            out[#out + 1] = line
        else
            local indent = line:match("^(%s*)") .. "      "
            -- tokenize, remembering the separator FOLLOWING each piece
            local pieces = {}
            local rest = line
            while true do
                local pC = rest:find(", ", 1, true)
                local pP = rest:find(" + ", 1, true)
                local pos, sep
                if pC and (not pP or pC < pP) then pos, sep = pC, ", "
                elseif pP then pos, sep = pP, " + "
                else break end
                pieces[#pieces + 1] = { text = rest:sub(1, pos - 1), sep = sep }
                rest = rest:sub(pos + #sep)
            end
            pieces[#pieces + 1] = { text = rest, sep = "" }
            local cur = pieces[1].text
            local prevSep = pieces[1].sep
            for i = 2, #pieces do
                local p = pieces[i]
                if #cur + #prevSep + #p.text <= wrapChars then
                    cur = cur .. prevSep .. p.text
                else
                    out[#out + 1] = cur .. (prevSep == ", " and "," or " +")
                    cur = indent .. p.text
                end
                prevSep = p.sep
            end
            out[#out + 1] = cur
        end
    end
    return out
end

local function hidePanelLabels()
    for i = 1, labelsMax do
        local w = labels[i]
        if w then
            pcall(function() if w:IsValid() then w:SetVisibility(1) end end) -- Collapsed
        end
    end
end

local function hideTab()
    if ourTab then
        pcall(function() if ourTab:IsValid() then ourTab:SetVisibility(1) end end)
    end
end

local function dropAllLabels()
    for i = 1, labelsMax do
        local w = labels[i]
        if w then
            pcall(function() if w:IsValid() then w:RemoveFromParent() end end)
        end
    end
    labels = {}
    labelsMax = 0
    if ourTab then
        pcall(function() if ourTab:IsValid() then ourTab:RemoveFromParent() end end)
        ourTab = nil
    end
    gameTabs = {}
end

-- devMode: one-time structure dumps for future layout refinement
local function census(page)
    if censusDone or not Config.devMode then return end
    censusDone = true
    pcall(function()
        local root = page:GetRootWidget()
        if not (root and root:IsValid()) then return end
        Log("[palpedia] census root: " .. root:GetClass():GetFullName())
        local n = 0
        pcall(function() n = root:GetChildrenCount() end)
        for i = 0, (n or 0) - 1 do
            local child = nil
            pcall(function() child = root:GetChildAt(i) end)
            if child and child:IsValid() then
                Log(string.format("[palpedia] census child %d: %s",
                    i, child:GetClass():GetFullName()))
            end
        end
    end)
end

-- viewport rectangle of a live widget (SlateBlueprintLibrary; out-params
-- as tables, the proven CalcAdditionalWidgetPosition call style)
local function rectOf(w)
    local rect = nil
    pcall(function()
        if not (w and w:IsValid() and pageRef and pageRef:IsValid()) then return end
        local slate = StaticFindObject("/Script/UMG.Default__SlateBlueprintLibrary")
        if not (slate and slate:IsValid()) then return end
        local geo = w:GetCachedGeometry()
        local size = slate:GetLocalSize(geo)
        local outPixel, outViewport = {}, {}
        slate:LocalToViewport(pageRef, geo, { X = 0, Y = 0 }, outPixel, outViewport)
        if type(outViewport.X) == "number" and size and type(size.X) == "number"
            and size.X > 0 then
            rect = { x = outViewport.X, y = outViewport.Y, w = size.X, h = size.Y }
        end
    end)
    return rect
end

local function mouseViewportPos()
    local pos = nil
    pcall(function()
        local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        if not (layout and layout:IsValid() and pageRef and pageRef:IsValid()) then return end
        local p = layout:GetMousePositionOnViewport(pageRef)
        if p and type(p.X) == "number" then pos = p end
    end)
    return pos
end

local function mouseDown()
    local down = false
    pcall(function()
        local pc = Role.getLocalPlayerController()
        if pc and pc:IsValid() then
            down = pc:IsInputKeyDown({ KeyName = FName("LeftMouseButton") }) == true
        end
    end)
    return down
end

-- clickable rectangle of the overlay tab: measured geometry when it
-- resolves, else the placed position plus the widget's desired size (an
-- overlay's cached geometry can lag its placement - the coordinates we
-- placed it at are still truth). A dead widget yields NO rect: rectOf
-- returns nil for freed widgets too, and the fallback must not become the
-- path that touches one (a UFunction call on a freed UObject faults past
-- pcall - the click closure is deferred and can outlive the tab).
local function overlayTabRect()
    local alive = false
    pcall(function() alive = ourTab and ourTab:IsValid() end)
    if not alive then return nil end
    local r = rectOf(ourTab)
    if r then return r end
    local c = cfg()
    local w, h = 240, 36
    pcall(function()
        if not ourTab:IsValid() then return end
        local d = ourTab:GetDesiredSize()
        if d and type(d.X) == "number" and type(d.Y) == "number" and d.X > 0 then
            w, h = d.X, d.Y
        end
    end)
    return { x = tonumber(c.tabX) or 1560, y = tonumber(c.tabY) or 118, w = w, h = h }
end

-- one click, resolved on the game thread: the tab first (opens the
-- panel), then the game's own tabs (Stats/Habitat close it - real tab
-- semantics). source names the detector in devMode logs ("bind" = the
-- raw UE4SS keybind, "poll" = the IsInputKeyDown edge - menus eat the
-- latter, which is why both exist).
local function processClick(source)
    if disabled or not watching then return end
    local m = mouseViewportPos()
    if not m then
        if Config.devMode then
            Log("[palpedia] click (" .. source .. "): no mouse position")
        end
        return
    end
    local function hit(r)
        return (r and m.X >= r.x and m.X <= r.x + r.w
            and m.Y >= r.y and m.Y <= r.y + r.h) == true
    end
    local tabRect = ourTab and overlayTabRect() or nil
    if Config.devMode then
        if tabRect then
            Log(string.format(
                "[palpedia] click (%s) at %.0f,%.0f - tab rect %.0f,%.0f %.0fx%.0f",
                source, m.X, m.Y, tabRect.x, tabRect.y, tabRect.w, tabRect.h))
        else
            Log(string.format("[palpedia] click (%s) at %.0f,%.0f - no tab rect",
                source, m.X, m.Y))
        end
    end
    if hit(tabRect) then
        if not panelShown then
            panelShown = true
            if Config.devMode then Log("[palpedia] tab clicked - panel ON") end
        end
    elseif panelShown then
        for _, t in ipairs(gameTabs) do
            if hit(rectOf(t)) then
                panelShown = false
                if Config.devMode then Log("[palpedia] game tab clicked - panel OFF") end
                break
            end
        end
    end
end

-- collect the game's own tab widgets for close-on-click hit-testing
local function collectGameTabs()
    gameTabs = {}
    pcall(function()
        for _, t in ipairs(FindAllOf(TAB_WBP_CLASS) or {}) do
            if t and t:IsValid() then table.insert(gameTabs, t) end
        end
    end)
end

-- create our Evolutions tab: an overlay label beside the game's own tabs
-- (a clone of them never renders - see the header note). Runs every watch
-- tick, so every path that does real work must be gated: the label-class
-- check comes BEFORE the object scan, else a session that opens the
-- Paldex before the radial wheel would re-scan GUObjectArray at 120ms for
-- as long as the page stays up (the exact stutter this file's header
-- forbids).
local function ensureTab(page)
    local ok = false
    pcall(function() ok = ourTab and ourTab:IsValid() end)
    if ok then
        -- the game can rebuild its tab widgets while reusing the page
        -- instance: a dead first entry means the whole list is stale and
        -- close-on-click would silently die (empty list stays empty until
        -- the page itself is rebuilt - never rescan per tick on nothing)
        local t = gameTabs[1]
        local tOk = false
        pcall(function() tOk = t and t:IsValid() end)
        if t and not tOk then collectGameTabs() end
        return
    end
    ourTab = nil -- clear a dead ref BEFORE any gate: the watch would still
                 -- placeOverlay it (a UFunction on a freed widget faults)
    if not labelClassReady() then return end
    local c = cfg()
    ourTab = makeLabel(page, "[ " .. I18n.msg("palpediaTabLabel")
        .. " (" .. tostring(c.toggleKey or "V") .. ") ]")
    if not ourTab then return end -- creation failed: no scan this tick
    collectGameTabs()
    placeOverlay(ourTab, tonumber(c.tabX) or 1560, tonumber(c.tabY) or 118)
    if Config.devMode then Log("[palpedia] Evolutions tab created") end
end

-- panel content: header, then per target a name line tagged with the kind
-- of change - "(Fire Adaptation)" / "(Evolution)" - plus an indented
-- requirements line, with a blank spacer line before each target so the
-- panel breathes. Blank entries still occupy a label SLOT (the y offset
-- advances) but never a SetText("") - see render.
-- Returns nil for an error-shaped describe failure (soft skip: the watch
-- retries and nothing is committed) and {} when the species legitimately
-- has no configured pairs (blank panel, committed).
local function panelLinesFor(id)
    local entries = nil
    local ok = pcall(function() entries = api.describeSpecies(id) end)
    if not ok or entries == nil then return nil end
    if #entries == 0 then return {} end
    local out = { I18n.msg("statusEvolveHeader") }
    for _, e in ipairs(entries) do
        local tag
        if e.kind == "adaptation" then
            local t = I18n.msg("adaptationTag")
            tag = e.element and (I18n.element(tostring(e.element)) .. " " .. t) or t
        else
            tag = I18n.msg("evolutionTag")
        end
        table.insert(out, "")
        table.insert(out, string.format("%s  (%s)", tostring(e.name), tag))
        table.insert(out, "    " .. tostring(e.reqs))
    end
    return out
end

-- returns true when the panel was painted or legitimately blanked; false
-- on a transient soft skip so the watch retries without committing its key
local function render(page, id)
    if disabled then return false end
    local lines
    if id and id ~= "" and id ~= "None" then
        lines = panelLinesFor(id)
        if lines == nil then return false end -- describe failed: retry, no commit
    else
        lines = {}
    end
    if #lines == 0 then
        hidePanelLabels()
        return true -- legitimate blank: no configured pairs for this id
    end
    local c = cfg()
    local maxLines = math.floor(tonumber(c.maxLines) or 19)
    local x = tonumber(c.x) or 700
    local y = tonumber(c.y) or 280
    local scale = tonumber(c.textScale) or 1
    if scale <= 0 then scale = 1 end
    lines = wrapPanelLines(lines, math.floor(tonumber(c.wrapChars) or 0))
    -- spacing follows the visual size: lineHeight is authored for unscaled
    -- text, so scaled labels sit proportionally tighter
    local lineH = (tonumber(c.lineHeight) or 30) * scale
    local shown = math.min(#lines, maxLines)
    if #lines > maxLines and shown >= 1 then
        lines[shown] = "..." -- visibly truncated, never silently
    end
    local needCreate = false
    for i = 1, shown do
        if lines[i] ~= "" then
            local w = labels[i]
            if not (w and w:IsValid()) then
                needCreate = true
                break
            end
        end
    end
    if needCreate and not labelClassReady() then return false end
    for i = 1, shown do
        if lines[i] == "" then
            -- spacer: draw nothing. A label already occupying the slot is
            -- collapsed rather than SetText("")-ed - an FText conversion
            -- failure there would silently keep the previous species' line
            if labels[i] then
                pcall(function()
                    if labels[i]:IsValid() then labels[i]:SetVisibility(1) end
                end)
            end
        else
            local w = labels[i]
            if not (w and w:IsValid()) then
                w = makeLabel(page, lines[i])
                if not w then
                    disabled = true
                    hidePanelLabels()
                    hideTab()
                    Log("[palpedia] label creation failed - Evolutions tab disabled this session")
                    return false
                end
                labels[i] = w
                if i > labelsMax then labelsMax = i end
            end
            -- confirmed application only: a failed set is a transient soft
            -- skip (no lastShownId commit), never a stale line
            if not setLabelText(w, lines[i]) then return false end
            if not placeOverlay(w, x, y + (i - 1) * lineH, scale) then
                disabled = true
                hidePanelLabels()
                hideTab()
                Log("[palpedia] overlay placement failed - Evolutions tab disabled this session")
                return false
            end
        end
    end
    for i = shown + 1, labelsMax do
        if labels[i] then
            pcall(function()
                if labels[i]:IsValid() then labels[i]:SetVisibility(1) end
            end)
        end
    end
    return true
end

-- current selection from the HUD service breadcrumb (plain CharacterID)
local lastLoggedId = nil
local function selectedSpecies()
    local ok = false
    pcall(function() ok = hudRef and hudRef:IsValid() end)
    if not ok then
        hudRef = nil
        pcall(function() hudRef = FindFirstOf("PalHUDService") end)
    end
    local id = nil
    pcall(function()
        if hudRef and hudRef:IsValid() then
            id = hudRef.TransientData.LastOpenedPaldexCharacter:ToString()
        end
    end)
    if Config.devMode and id ~= lastLoggedId then
        lastLoggedId = id
        Log("[palpedia] breadcrumb: " .. tostring(id))
    end
    return id
end

-- the Habitat tab's map widget: while visible, the panel steps aside
local function habitatVisible()
    local ok = false
    pcall(function() ok = mapRef and mapRef:IsValid() end)
    if not ok then return false end
    local vis = false
    pcall(function() vis = mapRef:IsVisible() == true end)
    return vis
end

local function findMapOnce()
    local ok = false
    pcall(function() ok = mapRef and mapRef:IsValid() end)
    if ok then return end
    mapRef = nil
    pcall(function()
        for _, w in ipairs(FindAllOf("WBP_Paldex_Map_C") or {}) do
            if w and w:IsValid() then
                mapRef = w
                break
            end
        end
    end)
end

-- watch: 120ms ticks ONLY while the stored page is on screen (click
-- detection needs the tighter cadence; every tick works on cached refs).
-- Generation token: a rapid close-and-reopen must never revive a stale loop.
local function armWatch()
    if watching or disabled then return end
    watching = true
    watchGen = watchGen + 1
    local myGen = watchGen
    if Config.devMode then
        Log(string.format("[palpedia] watch armed (gen %d)", myGen))
    end
    findMapOnce()
    LoopAsync(120, function()
        if disabled or watchGen ~= myGen or not watching then
            if watchGen == myGen then watching = false end
            return true
        end
        ExecuteInGameThread(function()
            if disabled or watchGen ~= myGen or not watching then return end
            local page = pageRef
            local alive = false
            if page then
                pcall(function()
                    alive = page:IsValid()
                        and ((page:IsInViewport() == true) or (page:IsVisible() == true))
                end)
            end
            if not alive then
                if Config.devMode then
                    Log(string.format("[palpedia] watch gen %d ending (page hidden/gone)", myGen))
                end
                watching = false
                lastShownId = nil
                lastWant = false
                mouseWasDown = false
                -- real tab semantics: the game reopens its Paldex on the
                -- Stats tab, so our panel must not come back pre-selected
                panelShown = false
                hidePanelLabels()
                hideTab()
                return
            end
            census(page)
            ensureTab(page)
            if ourTab then
                -- overlays do not travel with the page; re-assert placement
                local c = cfg()
                placeOverlay(ourTab, tonumber(c.tabX) or 1560, tonumber(c.tabY) or 118)
            end
            -- click handling, poll path: rising edge of the input-stack
            -- read (menus usually eat it; the raw keybind registered in
            -- init is the reliable detector - see processClick)
            local down = mouseDown()
            if down and not mouseWasDown then processClick("poll") end
            mouseWasDown = down
            -- panel visibility: selected, and not covering the Habitat map
            local wantPanel = panelShown and not habitatVisible()
            if wantPanel ~= lastWant then
                lastWant = wantPanel
                if wantPanel then
                    lastShownId = nil -- rising edge: force a repaint
                else
                    hidePanelLabels()
                end
            end
            if not wantPanel then return end
            -- a rebuild can kill our labels: force a repaint if so
            if lastShownId then
                local w = labels[1]
                local wOk = false
                pcall(function() wOk = w and w:IsValid() end)
                if not wOk then lastShownId = nil end
            end
            local id = selectedSpecies()
            if id and id ~= "" and id ~= "None" and id ~= lastShownId then
                local ok, done = pcall(render, page, id)
                if not ok then
                    disabled = true
                    hidePanelLabels()
                    hideTab()
                    Log("[palpedia] render FAIL (disabled this session): " .. tostring(done))
                elseif done then
                    lastShownId = id
                end
            end
        end)
        return watchGen ~= myGen or not watching
    end)
end

function Palpedia.init(evolutionApi)
    api = evolutionApi
    if (cfg()).enabled == false then return end
    if Role.isDedicated() then return end

    local registered = 0
    local openLogged, filterLogged = false, false

    -- OPEN/refresh: the post-hook self IS the live page; store it so the
    -- watch never has to search for it (radialmenu's proven menuRef pattern)
    if pcall(function()
        RegisterHook("/Script/Pal.PalUIPaldex:CreateDisplayInfo",
            function() end,
            function(self)
                pcall(function()
                    local page = self:get()
                    if not (page and page:IsValid()) then return end
                    if Config.devMode and not openLogged then
                        openLogged = true
                        Log("[palpedia] CreateDisplayInfo fired")
                    end
                    if page ~= pageRef then
                        dropAllLabels() -- fresh page instance: rebuild widgets
                        pageRef = page
                    end
                    lastShownId = nil
                    armWatch()
                end)
            end)
    end) then registered = registered + 1 end

    -- list rebuild (filter/sort): can fire liberally (BlueprintPure), so it
    -- only re-arms the watch - never resets state per fire
    if pcall(function()
        RegisterHook("/Script/Pal.PalUIPaldex:GetFilteredDisplayInfoArray",
            function() end,
            function(self, FilterInfo)
                pcall(function()
                    if Config.devMode and not filterLogged then
                        filterLogged = true
                        Log("[palpedia] GetFilteredDisplayInfoArray fired")
                    end
                    armWatch()
                end)
            end)
    end) then registered = registered + 1 end

    -- keyboard shortcut for the tab (acts only while the Palpedia is up).
    -- Same discipline as the click bind below: gate in pure Lua BEFORE the
    -- game-thread hop (this fires on every press anywhere in the game),
    -- and never fail registration silently - the summary line would still
    -- advertise the key.
    local keyName = tostring((cfg()).toggleKey or "V")
    local keyBindOk = pcall(function()
        RegisterKeyBind(Key[keyName], function()
            if disabled or not watching then return end
            ExecuteInGameThread(function()
                if disabled or not watching then return end
                panelShown = not panelShown
                if Config.devMode then
                    Log("[palpedia] panel toggled " .. (panelShown and "ON" or "OFF"))
                end
            end)
        end)
    end)
    if not keyBindOk then
        Log("Palpedia evolutions: toggle key '" .. keyName
            .. "' did not register - check palpediaEvolutions.toggleKey")
    end

    -- the click itself: menus run in UI input mode where Slate consumes
    -- LeftMouseButton before the player controller's input stack sees it,
    -- so the watch's IsInputKeyDown poll never fires there - a raw UE4SS
    -- keybind (the same layer that makes the toggle key work in menus)
    -- delivers the click. It fires on EVERY click in the game, combat
    -- included: the pure-Lua gate below keeps idle clicks off the game
    -- thread.
    local clickBindOk = pcall(function()
        RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
            if disabled or not watching then return end
            ExecuteInGameThread(function() processClick("bind") end)
        end)
    end)
    if not clickBindOk then
        Log("Palpedia evolutions: raw click bind unavailable - tab clicks rely on the input poll")
    end

    if registered > 0 then
        Log(string.format("Palpedia evolutions active (%d/2 hooks, tab + %s key)",
            registered, keyName))
    else
        Log("Palpedia evolutions: no hooks registered - feature inactive")
    end
end

return Palpedia
