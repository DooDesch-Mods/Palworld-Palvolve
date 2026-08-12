-- The evolution tree as a page of the Palpedia.
--
-- Palworld's Palpedia switches between "Stats" and "Habitat" by visibility: the
-- two pages sit in one canvas and the one that is not shown is Collapsed. This
-- module adds a third tab to that screen and puts the mod's tree where the map
-- goes, so the screen behaves the way it always did and the tree is just
-- another page of it.
--
-- Two things about it are not obvious and were measured rather than assumed:
--
--   The tab has to go into the LIVE tab bar. Every widget blueprint also keeps
--   a cooked template of its tree that answers to the same class name; a tab
--   added there is copied into every Palpedia built afterwards and belongs to no
--   live tabset, so nothing can ever select it.
--
--   The page stays a viewport widget. Hung inside the Palpedia's own panel it
--   drew perfectly and took no clicks at any z-order, with no ancestor blocking
--   hit tests. On the viewport, over the rectangle the map occupies, it gets
--   its clicks and sits in the same place.
--
-- The browser itself comes from the mod's LogicMod pak: a bare UWebBrowser
-- built from Lua leaves CEF unstarted, while one placed in a WidgetBlueprint is
-- built by UMG and comes up alive.

local M = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

local function addName(s)
    local n = FName(s, EFindName.FNAME_Find)
    if n == NAME_None then n = FName(s, EFindName.FNAME_Add) end
    return n
end

--- Loads a class out of a mod pak. LoadAsset goes through the asset registry,
--- which is built when the game is cooked and has never heard of anything a mod
--- pak brings along. Handing FAssetData to the registry helper loads the
--- package by name instead, which is how the BP mod loader does it.
local function loadClass(pkg, assetName)
    local objPath = string.format("%s.%s", pkg, assetName)
    local c = nil
    pcall(function() c = StaticFindObject(objPath) end)
    if c and c:IsValid() then return c, "already resident" end

    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not (helpers and helpers:IsValid()) then return nil, "no asset registry helpers" end

    pcall(function()
        c = helpers:GetAsset({
            PackageName = addName(pkg),
            AssetName = addName(assetName),
        })
    end)
    if c and c:IsValid() then return c, "loaded from the pak" end

    -- the pre-5.1 shape of the same call, in case this build wants it
    c = nil
    pcall(function() c = helpers:GetAsset({ ObjectPath = addName(objPath) }) end)
    if c and c:IsValid() then return c, "loaded from the pak (legacy FAssetData)" end

    return nil, "not found"
end

--- While a free-standing window is up the player must not walk around behind
--- it, and the mouse has to belong to the page. Opened from the Palpedia this is
--- left alone: that screen brings its own input mode, and taking it over there
--- made the page answer while the rest of the Palpedia went deaf.
local function grabInput(pc)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    -- EMouseLockMode: 0 = DoNotLock, so the cursor can leave the window.
    pcall(function() lib:SetInputMode_UIOnlyEx(pc, nil, 0, false) end)
    pcall(function() pc.bShowMouseCursor = true end)
end

local function releaseInput(pc)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    pcall(function() lib:SetInputMode_GameOnly(pc, true) end)
    pcall(function() pc.bShowMouseCursor = false end)
end

-- ---------------------------------------------------------------------------
-- The tree as a web page inside our own browser widget.
--
-- The browser was never the problem. Constructing a bare UWebBrowser from Lua
-- leaves CEF unstarted, which is the spinner the first attempt produced; a
-- browser placed in a WidgetBlueprint is built by UMG and comes up alive. The
-- pak is what makes that possible, so this is the same discovery as the card
-- list, spent on the version that looks like the website.
--
-- The click channel is the address bar: fragments do not navigate, so the page
-- stays up, and the mod polls GetUrl to learn which Pal was clicked.
-- ---------------------------------------------------------------------------

local WEB_PKG, WEB_ASSET = "/Game/Palvolve/WBP_PalvolveWeb", "WBP_PalvolveWeb_C"
local TREE_ORIGIN = "http://palvolve.local/tree"

--- The one breakage a player cannot see from the game: without the pak the tab
--- opens onto an empty frame. Names the file and the folder it belongs in, so a
--- support log says what to fix instead of only which class was missing.
local function logMissingPak(how)
    Log(string.format("the tree page asset %s.%s did not load (%s)",
        WEB_PKG, WEB_ASSET, tostring(how)))
    Log("it ships in Palvolve.pak, which belongs in "
        .. "<install>\\Pal\\Content\\Paks\\LogicMods\\ - reinstall the mod if that file is gone")
end

local treeWebWidget = nil
local treeWebBrowser = nil
local treeWebStop = false
local treeWebOpen = false
local treeWebCurrent = nil
local treeWebPage = nil
local treeWebPageFor = nil  -- which Pal treeWebPage was built for
-- The page is rebuilt on every click, so the list starts at the top again and
-- the Pal that was just picked is somewhere out of sight. The fragment cannot
-- ride along in the load URL - tried, and the page then stops answering clicks
-- entirely. So the page is loaded first and the anchor steered afterwards: a
-- fragment change on the document that is already open scrolls, it does not
-- load. These two carry that second step across ticks.
local treeWebAnchor = nil
local treeWebAnchorAt = 0
-- Opened from the Paldex the window must not touch the input mode: the Paldex
-- is already running on UI input, and handing it back on close would leave that
-- screen open and deaf.
local treeWebKeepInput = false
-- Docked, the window is a panel inside the Paldex; free-standing it is a window
-- over the world. The slot is kept because the same window is reused for both.
local treeWebDocked = false
local treeWebSlot = nil
local treeWebLastUrl = nil
-- Which Pal the Paldex list stands on. Shared with the page: a Pal picked in
-- the tree counts as the same answer, or the two pull against each other and
-- every in-page click is dragged back to the list a tick later.
local paldexListPick = nil
-- Declared here, assigned further down. The watcher below closes the window,
-- and a name that is only declared later in the file is a global up here - and
-- a global nobody assigned is nil.
local closeTreeWeb

local function addrOf(o)
    if not (o and o:IsValid()) then return 0 end
    local a = 0
    pcall(function() a = o:GetAddress() end)
    return a
end
local treeWebGen = 0

--- Where the window sits. Free-standing it leaves a margin so the world stays
--- visible around it, the way the game's own screens do. Docked into the Paldex
--- it takes the rectangle that screen gives its own content - the same one the
--- habitat map fills - so it reads as a third tab rather than as a window that
--- happens to be in front.
local function placeTreeWeb()
    if not (treeWebSlot and treeWebSlot:IsValid()) then return end
    -- Docked, the window fills its frame and the frame is the one the Paldex
    -- gives the habitat map. A margin in here as well is a margin twice, which
    -- is what left the page sitting 56 pixels inside the map on every side.
    -- Free-standing, the frame covers the screen and the margin belongs here.
    local a = treeWebDocked
        and { X0 = 0.0, Y0 = 0.0, X1 = 1.0, Y1 = 1.0 }
        or { X0 = 0.07, Y0 = 0.08, X1 = 0.93, Y1 = 0.92 }
    local ok = pcall(function()
        treeWebSlot:SetAnchors({ Minimum = { X = a.X0, Y = a.Y0 },
                                 Maximum = { X = a.X1, Y = a.Y1 } })
        treeWebSlot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        treeWebSlot:SetAlignment({ X = 0, Y = 0 })
    end)
    Log(string.format("tree page placed %s at %.3f,%.3f-%.3f,%.3f (%s)",
        treeWebDocked and "docked" or "free", a.X0, a.Y0, a.X1, a.Y1, tostring(ok)))
end

--- Watches the address bar. Every control on the page is a link, so a click on
--- a Pal, on the fold switch and on close all arrive here.
local function startTreeWebWatcher(html, firstDelivery)
    treeWebStop = false
    pcall(function() treeWebLastUrl = tostring(treeWebBrowser:GetUrl():ToString()) end)
    -- Numbered, because a second watcher may be started while the first is
    -- still running - and two of them would answer every click twice.
    treeWebGen = treeWebGen + 1
    local myGen = treeWebGen
    local ticks = 0
    local delivered = not firstDelivery
    LoopAsync(120, function()
        if treeWebStop or myGen ~= treeWebGen
            or not (treeWebBrowser and treeWebBrowser:IsValid()) then
            return true
        end
        ticks = ticks + 1
        local url = ""
        pcall(function() url = tostring(treeWebBrowser:GetUrl():ToString()) end)

        -- Only a change in the address is an instruction. The browser keeps the
        -- last address it was on, so a window closed from its own close link
        -- still reads "#close" when it is opened again - and closed itself
        -- within a tenth of a second, which looked like the tab doing nothing.
        if url == treeWebLastUrl then url = "" else treeWebLastUrl = url end

        -- The input mode is re-asserted about once a second. The game puts it
        -- back to game-only whenever the window regains focus - after an
        -- alt-tab the page then still draws but swallows nothing, and every
        -- click goes to the world behind it.
        if ticks % 8 == 0 and not treeWebKeepInput then
            local pc2 = FindFirstOf("PalPlayerController")
            if pc2 and pc2:IsValid() then grabInput(pc2) end
        end

        -- Retried rather than sent once: how many frames UMG needs before the
        -- browser is real is not something the mod can ask about, so it keeps
        -- offering the page until the address says the page arrived.
        if not delivered then
            if url:find("palvolve.local", 1, true) then
                delivered = true
                Log("tree page delivered after " .. ticks .. " ticks")
            elseif ticks <= 40 then
                pcall(function() treeWebBrowser:LoadString(treeWebPage, TREE_ORIGIN) end)
            elseif ticks == 41 then
                Log("the browser never took the tree page - url [" .. url .. "]")
            end
        end

        if html.isClose(url) then
            Log("tree page closed from its own close link")
            -- The whole close, not just the window: docked, the habitat map has
            -- to come back or that page of the Palpedia stays empty.
            closeTreeWeb()
            return true
        end

        -- The fold switch is a link like every other control here, so it is read
        -- from the address and answered with a redraw of the same Pal.
        if html.toggleFrom(url) then
            treeWebPage = html.page(treeWebCurrent)
            pcall(function() treeWebBrowser:LoadString(treeWebPage, TREE_ORIGIN) end)
            Log("tree page conditions toggled")
        end

        local pick = html.pickFrom(url)
        if pick and pick ~= treeWebCurrent then
            treeWebCurrent = pick
            paldexListPick = pick
            local t = os.clock()
            treeWebPage = html.page(pick)
            pcall(function() treeWebBrowser:LoadString(treeWebPage, TREE_ORIGIN) end)
            treeWebAnchor, treeWebAnchorAt = pick, ticks + 3
            Log(string.format("tree page centred on %s (%d ms)",
                pick, math.floor((os.clock() - t) * 1000)))
        end

        -- ... and once that page is up, the same document is asked for its
        -- anchor, which brings the picked Pal back into view in the list.
        if treeWebAnchor and ticks >= treeWebAnchorAt then
            local target = treeWebAnchor
            treeWebAnchor = nil
            pcall(function()
                treeWebBrowser:LoadURL(TREE_ORIGIN .. "#pick/" .. target)
            end)
        end

        if ticks > 6000 then
            Log("tree page watcher stopped after twelve minutes")
            return true
        end
        return false
    end)
end

--- Building the window and starting its browser is what costs the seconds, so
--- it is built once and then kept for the rest of the session. Closing hides
--- it, opening shows it again, and the second open is immediate.
--- keepInput decides whether the window takes the input mode over. Left out, the
--- mode of the last opener stands - the page's own close button and the watcher
--- must not flip it.
function M.toggleTreeWindow(keepInput)
    if keepInput ~= nil then
        -- One decision, two consequences: the window that leaves the input mode
        -- alone is the one docked into the Paldex, the one that takes input over
        -- is the free-standing window from the chat command.
        treeWebKeepInput = keepInput == true
        treeWebDocked = treeWebKeepInput
        local okD, d = pcall(require, "treehtml")
        if okD and d then d.setDocked(treeWebDocked) end
        placeTreeWeb()
    end
    local okHtml, html = pcall(require, "treehtml")
    if not (okHtml and html) then
        Log("treehtml did not load: " .. tostring(html))
        return
    end

    -- open -> hidden
    if treeWebOpen and treeWebWidget and treeWebWidget:IsValid() then
        treeWebStop = true
        treeWebOpen = false
        local pc = FindFirstOf("PalPlayerController")
        if pc and pc:IsValid() and not treeWebKeepInput then releaseInput(pc) end
        -- Collapsed, not removed: off the viewport the browser would have to
        -- start over, and starting it is the expensive part.
        pcall(function() treeWebWidget:SetVisibility(1) end)
        Log("tree page closed")
        return
    end

    -- hidden -> shown again, nothing gets rebuilt
    if treeWebWidget and treeWebWidget:IsValid()
        and treeWebBrowser and treeWebBrowser:IsValid() then
        local t = os.clock()
        -- SelfHitTestInvisible, not Visible: the frame spans the screen, and
        -- shown as plain Visible it takes every click outside the window with
        -- it. That is why the Paldex went dead the second time it was opened.
        pcall(function() treeWebWidget:SetVisibility(4) end)
        treeWebPage = html.page(treeWebCurrent)
        pcall(function() treeWebBrowser:LoadString(treeWebPage, TREE_ORIGIN) end)
        local pc = FindFirstOf("PalPlayerController")
        if pc and pc:IsValid() and not treeWebKeepInput then grabInput(pc) end
        treeWebOpen = true
        startTreeWebWatcher(html, false)
        Log(string.format("tree page reopened in %d ms",
            math.floor((os.clock() - t) * 1000)))
        return
    end

    -- first open: everything is built, and every step reports what it cost
    local tOpen = os.clock()
    local cls, how = loadClass(WEB_PKG, WEB_ASSET)
    if not cls then
        logMissingPak(how)
        return
    end
    Log(string.format("tree page class ready (%s) after %d ms",
        how, math.floor((os.clock() - tOpen) * 1000)))

    local pc = FindFirstOf("PalPlayerController")
    if not (pc and pc:IsValid()) then
        Log("no player controller, the tree page cannot open")
        return
    end

    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local t1 = os.clock()
    local widget = nil
    pcall(function() widget = lib:Create(pc, cls, pc) end)
    if not (widget and widget:IsValid()) then
        Log("the tree window did not build")
        return
    end
    local browser = nil
    pcall(function() browser = widget.Browser end)
    if not (browser and browser:IsValid()) then
        Log("the tree window has no Browser - Is Variable is probably off")
        return
    end
    Log(string.format("tree window and browser in %d ms",
        math.floor((os.clock() - t1) * 1000)))

    -- Whatever the opener asked for stands. Cleared here, the first page always
    -- came up on the first Pal in the list while the log said it was opening on
    -- the one the Paldex was showing.
    -- Reused when the caller already built it off the game thread. Building it
    -- here costs seconds on a cold icon cache, and every one of them is a
    -- second the game stands still.
    local t2 = os.clock()
    if not (treeWebPage and treeWebPageFor == treeWebCurrent) then
        treeWebPage = html.page(treeWebCurrent)
        treeWebPageFor = treeWebCurrent
        Log(string.format("tree page %d KB in %d ms",
            math.floor(#treeWebPage / 1024), math.floor((os.clock() - t2) * 1000)))
    end

    -- A window, not a takeover: the game's own screens leave a margin so the
    -- world stays visible around them. It goes onto a canvas of our own rather
    -- than straight onto the viewport - what the viewport hands out is not a
    -- canvas slot, and there anchors are ignored while a pixel size pins the
    -- window to the top-left at half the intended scale.
    local t3 = os.clock()
    local frame, canvas, slot = nil, nil, nil
    pcall(function() frame = lib:Create(pc, StaticFindObject("/Script/UMG.UserWidget"), pc) end)
    if frame and frame:IsValid() then
        pcall(function()
            canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"),
                                           frame, FName("PalvolveFrame"))
            frame.WidgetTree.RootWidget = canvas
        end)
    end
    if canvas and canvas:IsValid() then
        pcall(function() slot = canvas:AddChildToCanvas(widget) end)
    end
    if slot and slot:IsValid() then
        treeWebSlot = slot
        placeTreeWeb()
        -- The frame spans the whole screen so the window can be placed by
        -- fractions. Left hit-testable it swallows every click outside the
        -- window too - which is what stopped "Werte" and "Habitat" from
        -- answering. Only its child takes the mouse.
        pcall(function() frame:SetVisibility(4) end)  -- SelfHitTestInvisible
        pcall(function() frame:AddToViewport(70) end)
        widget = frame
    else
        -- a full-screen window beats no window
        pcall(function() widget:AddToViewport(70) end)
        Log("no canvas slot - the tree window stays full screen")
    end
    Log(string.format("tree window on screen in %d ms",
        math.floor((os.clock() - t3) * 1000)))

    treeWebWidget, treeWebBrowser = widget, browser
    treeWebOpen = true
    if not treeWebKeepInput then grabInput(pc) end
    startTreeWebWatcher(html, true)
    Log(string.format("tree page open, %d ms in total",
        math.floor((os.clock() - tOpen) * 1000)))
end

-- ---------------------------------------------------------------------------
-- The tree as a page of the Paldex.
--
-- Measured off that screen: its content panel holds the model view, the floor
-- images, the habitat map and the canvas with the tab bar. The map is anchored
-- 0,0-1,1 with no offsets, so it covers the panel exactly, and switching pages
-- is nothing but visibility - the map collapsed while "Werte" shows, the model
-- pieces collapsed while "Habitat" does.
--
-- So the tree is added to that same panel with the map's rectangle, and takes
-- its turn the same way. It then has the screen's coordinates, clipping and
-- scale, instead of an imitation of them laid over the top.
-- ---------------------------------------------------------------------------

local paldexHidden = {}      -- what was folded away, and how it looked
local paldexHost = nil       -- the content panel our page lives in
local paldexMap = nil        -- the habitat map, while ours stands in for it

--- Puts the Paldex on its habitat page, through its own handler for that tab.
--- The screen then clears the model view and the whole panel of values on the
--- right by itself - work the mod has no business redoing, and could not do as
--- well, because half of it lives outside the panel the pages sit in.
local HABITAT_CLICKED =
    "BndEvt__WBP_Paldex_tabset_WBP_Paldex_tab_Distribution_K2Node_"
    .. "ComponentBoundEvent_0_OnClicked__DelegateSignature"

local function showHabitatPage(tabset)
    if not (tabset and tabset:IsValid()) then return false end
    local ok = pcall(function() tabset[HABITAT_CLICKED](tabset) end)
    Log("switched the Palpedia to its habitat page: " .. tostring(ok))
    return ok
end

--- Already put away, so its first look is the one that gets restored. Clicking
--- the tab that is already selected docks a second time, and without this the
--- map would be written down as Collapsed and stay collapsed after the close.
local function alreadyPutAway(w)
    for _, e in ipairs(paldexHidden) do
        if addrOf(e.widget) == addrOf(w) then return true end
    end
    return false
end

--- And with that page up, only the map has to go: the tree takes its place.
local function hidePaldexPages(host)
    if not (host and host:IsValid()) then return end
    local n = 0
    pcall(function() n = host:GetChildrenCount() end)
    if n > 40 then n = 40 end
    for i = 0, n - 1 do
        local c = nil
        pcall(function() c = host:GetChildAt(i) end)
        local cls = ""
        if c and c:IsValid() then
            pcall(function() cls = tostring(c:GetClass():GetFName():ToString()) end)
        end
        if cls == "WBP_Paldex_Map_C" then
            if not alreadyPutAway(c) then
                local vis = -1
                pcall(function() vis = c:GetVisibility() end)
                paldexHidden[#paldexHidden + 1] = { widget = c, visibility = vis }
            end
            paldexMap = c
            pcall(function() c:SetVisibility(1) end)  -- Collapsed
        end
    end
    Log(string.format("habitat map put away: %d", #paldexHidden))
end

--- And back exactly as they were. The game restores only what it hid itself.
local function showPaldexPages()
    local n = #paldexHidden
    for _, e in ipairs(paldexHidden) do
        if e.widget and e.widget:IsValid() then
            pcall(function() e.widget:SetVisibility(e.visibility) end)
        end
    end
    paldexHidden = {}
    paldexMap = nil
    if n > 0 then Log(string.format("gave %d Palpedia pages back", n)) end
end

--- Puts the window into the Paldex, where the habitat map sits.
local function dockIntoPaldex(barCanvas)
    if not (barCanvas and barCanvas:IsValid()
        and treeWebWidget and treeWebWidget:IsValid()) then
        Log("nothing to dock, or nowhere to dock it")
        return false
    end
    local host = nil
    pcall(function() host = barCanvas.Slot.Parent end)
    if not (host and host:IsValid()) then
        Log("the tab bar canvas has no panel around it")
        return false
    end

    -- The window stays on the viewport and is only moved onto the rectangle the
    -- Paldex gives its habitat map.
    --
    -- Hanging it into that screen was tried and measured: it drew perfectly and
    -- took no clicks at all, at any z-order, with the same input mode that works
    -- outside, and with no ancestor swallowing hit tests (0 / 4 / 4). A window
    -- on the viewport gets its clicks; that is worth more than being a child of
    -- the right panel, and the position is the same either way.
    --
    -- The numbers are the map, measured off the game: 630 to 1748 across and
    -- 172 to 945 down in a 1920 by 1080 window, as fractions so they hold when
    -- the window is another size. The page starts below the tab row, which ends
    -- at 160, so those tabs stay clickable.
    paldexHost = host
    if treeWebSlot and treeWebSlot:IsValid() then
        pcall(function()
            treeWebSlot:SetAnchors({ Minimum = { X = 0.328, Y = 0.159 },
                                     Maximum = { X = 0.910, Y = 0.875 } })
            treeWebSlot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
            treeWebSlot:SetAlignment({ X = 0, Y = 0 })
        end)
    end
    hidePaldexPages(host)

    -- The input mode is left alone. Setting it to UI-only here did make the
    -- page answer, and took the rest of the Paldex with it: that screen brings
    -- its own mode, the mouse already reaches every widget under it, and ours
    -- lies on the viewport above them. One mode for both, the game's.
    --
    -- The whole chain of ancestors is written down instead, because one of them
    -- at HitTestInvisible swallows the mouse for everything below it, no matter
    -- what the page or the input mode do. 0 Visible, 3 HitTestInvisible,
    -- 4 self only.
    local w = treeWebWidget
    local chain = {}
    for _ = 1, 8 do
        local name, vis = "?", -1
        pcall(function() name = tostring(w:GetFName():ToString()) end)
        pcall(function() vis = w:GetVisibility() end)
        chain[#chain + 1] = string.format("%s vis=%d", name, vis)
        local up = nil
        pcall(function() up = w.Slot.Parent end)
        if not (up and up:IsValid()) then break end
        w = up
    end
    Log("tree window sits under: " .. table.concat(chain, " < "))

    Log("tree page docked where the habitat map sits")
    return true
end

--- Out of the Paldex again, before that screen goes away and takes the window
--- with it. The game's own map comes back exactly as it was. The input mode is
--- not touched here: the Paldex brought its own and is still open.
local function undockTreeWeb()
    if not paldexHost then return end
    paldexHost = nil
    showPaldexPages()
end

--- Opens the window on a given Pal, or moves an open one onto it. Used by the
--- Paldex tab, which brings its own Pal and its own input mode.
local function openTreeWebFor(id, barCanvas)
    treeWebKeepInput = true
    treeWebDocked = true
    if id then treeWebCurrent = id end
    local okHtml, html = pcall(require, "treehtml")
    if not (okHtml and html) then return end
    html.setDocked(true)
    if not treeWebOpen then M.toggleTreeWindow() end
    -- Re-applied on every open: the window may have been free-standing before,
    -- and then it still carries that margin inside its frame.
    placeTreeWeb()
    -- Docking delivers the page itself, because re-parenting costs the browser
    -- the one it had.
    dockIntoPaldex(barCanvas)
end

closeTreeWeb = function()
    undockTreeWeb()
    if treeWebOpen then M.toggleTreeWindow() end
end

-- ---------------------------------------------------------------------------
-- A third tab in the game's own Palpedia.
--
-- The main menu bar could not take one: its tabs hang off a map keyed by a game
-- enum, and an enum cannot be extended from Lua. The Paldex switcher is built
-- differently - WBP_Paldex_tabset_C keeps its tabs as the children of
-- HorizontalBox_Tab, so a third child is a third tab.
--
-- The tab itself is an instance of the game's own WBP_Paldex_tab_C, not a
-- lookalike of ours: the tabset calls focus animations on whatever it finds in
-- that box, and a foreign widget would be asked for functions it does not have.
--
-- The function that switches tabs is not the tabset's own: it comes from
-- WBP_PanelWidgetChildrenSelectorBase_C, which the tabset derives from.
-- ---------------------------------------------------------------------------

local PALDEX_TAB = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Paldex/WBP_Paldex_tab.WBP_Paldex_tab_C"
local PALDEX_TABSET = "WBP_Paldex_tabset_C"
local PALDEX_SCREEN = "WBP_Paldex_C"
-- Everything that screen shows sits in one canvas, WBP_Paldex_C:WidgetTree.CanvasPanel_2,
-- with the tab bar as a 32 px strip along its top. It is reached through the
-- tabset's slot rather than by name.
-- Switching tabs does not live on the tabset but on WBP_PanelWidgetChildrenSelectorBase_C,
-- which it derives from - that is why a hook aimed at the tabset never took.
-- Which tab is current is read from that base class's NowFocusChildIndex rather
-- than hooked: the mod calls SelectByIndex itself, and a hooked function called
-- from a hook froze the game.
-- The tab's own click handler. Its delegate is bound per instance by the class
-- constructor, so our instance runs this function too - and a Blueprint
-- function can be hooked even though its delegate cannot be bound. This is how
-- a click on a tab nobody wired up still reaches us.
local TAB_CLICKED =
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Paldex/WBP_Paldex_tab.WBP_Paldex_tab_C:"
    .. "BndEvt__WBP_Paldex_tab_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_1_"
    .. "CommonButtonBaseClicked__DelegateSignature"

local paldexTab = nil        -- our tab widget, while it lives
local paldexIndex = -1       -- the index it was given
local paldexClickHooked = false
local paldexNativeHooked = false
local paldexStarted = false
local paldexWant = nil       -- "open" or "close", set by the click hook
local paldexLit = false      -- true while the highlight is ours, not the game's
local paldexBusy = false     -- true while the mod is inside a call to the game
local paldexPendingRowName = nil -- the button whose row was just clicked

--- A widget that is really on screen. Not just "not the default object": every
--- widget blueprint also keeps a cooked template of its whole tree, and that one
--- answers to the same class. Only what lives under /Engine/Transient was built
--- for the running game - taking the template for an open Paldex is what made
--- the mod inject its tab before the screen even existed.
local function liveOne(className)
    for _, o in ipairs(FindAllOf(className) or {}) do
        local n = ""
        pcall(function() n = tostring(o:GetFullName()) end)
        if o:IsValid() and n:find("/Engine/Transient", 1, true)
            and not n:find("Default__", 1, true) then
            return o
        end
    end
    return nil
end

local function textOf(str)
    local ktl = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    if ktl and ktl:IsValid() then return ktl:Conv_StringToText(str) end
    return nil
end

--- The panel a widget sits in.
local function parentPanelOf(w)
    if not (w and w:IsValid()) then return nil end
    local p = nil
    pcall(function() p = w.Slot.Parent end)
    if p and p:IsValid() then return p end
    return nil
end

--- A Paldex tabset that is on screen, with its tab bar. Anything whose name has
--- no /Engine/Transient in it is the cooked template, not a widget the player
--- can see.
local function liveTabsetWithBox()
    for _, ts in ipairs(FindAllOf(PALDEX_TABSET) or {}) do
        local n = ""
        pcall(function() n = tostring(ts:GetFullName()) end)
        local shown = false
        pcall(function() shown = ts:IsVisible() end)
        if ts:IsValid() and shown and n:find("/Engine/Transient", 1, true)
            and not n:find("Default__", 1, true) then
            local path = n:match("%s(.+)$") or n
            for _, o in ipairs(FindAllOf("HorizontalBox") or {}) do
                local m = ""
                pcall(function() m = tostring(o:GetFullName()) end)
                if o:IsValid() and m:find(path .. ".", 1, true)
                    and m:find("HorizontalBox_Tab", 1, true) then
                    return ts, o
                end
            end
            return ts, nil
        end
    end
    return nil, nil
end

--- The tabset that owns a given tab bar. Not "the first one of its class": the
--- live Paldex sits inside a display wrapper and more than one tabset is alive,
--- so the wrong one takes the index and the highlight never moves. The bar sits
--- in the tabset's own widget tree, so the owner is the one whose object path
--- the bar's path starts with.
local function selectorForBox(box)
    if not (box and box:IsValid()) then
        Log("no tab bar to match a tabset against")
        return nil
    end
    local boxName = ""
    pcall(function() boxName = tostring(box:GetFullName()) end)
    if boxName == "" then return nil end
    local seen = 0
    for _, ts in ipairs(FindAllOf(PALDEX_TABSET) or {}) do
        local n = ""
        pcall(function() n = tostring(ts:GetFullName()) end)
        if ts:IsValid() and not n:find("Default__", 1, true) then
            seen = seen + 1
            -- The bar lives in the tabset's own widget tree, so the tabset's
            -- path is the head of the bar's path. MyPanelWidget looked like the
            -- shorter way and matched nothing - it is not the bar.
            local path = n:match("%s(.+)$") or n
            if boxName:find(path .. ".", 1, true) then return ts end
        end
    end
    Log(string.format("none of %d tabsets owns %s", seen, boxName))
    return nil
end

--- Lights one tab and dims the rest. The lit look is an animation every tab
--- plays on itself, which makes it reachable even when the tabset will not
--- count a tab it did not build.
local function lightTab(box, selected)
    if not (box and box:IsValid()) then return false end
    local n = 0
    pcall(function() n = box:GetChildrenCount() end)
    local lit = false
    for i = 0, n - 1 do
        local c = nil
        pcall(function() c = box:GetChildAt(i) end)
        if c and c:IsValid() then
            if addrOf(c) == addrOf(selected) then
                lit = pcall(function() c:AnmEvent_Focus() end)
            else
                pcall(function() c:AnmEvent_Unfocus() end)
            end
        end
    end
    Log("lit the tab by hand: " .. tostring(lit))
    return lit
end

--- The tabset that owns our tab, whichever Paldex it belongs to.
local function paldexSelector()
    return selectorForBox(parentPanelOf(paldexTab))
end

--- Our tab already in the bar, if it survived a close. The game's own two are
--- named after their designer variables, ours carries the generated class name.
local function findOurTab(box)
    local n = 0
    pcall(function() n = box:GetChildrenCount() end)
    for i = 0, n - 1 do
        local c = nil
        pcall(function() c = box:GetChildAt(i) end)
        local name = ""
        if c and c:IsValid() then
            pcall(function() name = tostring(c:GetFName():ToString()) end)
        end
        if name:find("^WBP_Paldex_tab_C_") then return c, i end
    end
    return nil, -1
end

--- Puts the tab into the open Paldex. Returns true once it is in.
local function injectPaldexTab()
    if paldexTab and paldexTab:IsValid() then return true end

    -- The bar, taken from a tabset that is actually on screen.
    --
    -- Looking it up by cooked path found the class template instead: every
    -- widget blueprint keeps one, its name has no /Engine/Transient in it, and
    -- a tab added there is copied into every Paldex built afterwards. That is
    -- why the third tab appeared and yet belonged to no live tabset - and why
    -- the tabset would not select it.
    local tabset, box = liveTabsetWithBox()
    if not tabset then
        Log("no Palpedia tabset on screen")
        return false
    end
    if not box then
        Log("the live Palpedia tabset has no tab bar")
        return false
    end
    Log("the live Palpedia tab bar is there")

    -- What the screen is built from, read off the game rather than guessed from
    -- a screenshot: the tree has to take the rectangle the content below the bar
    -- gets, and switching between the two has to look the way the game does it.
    -- The bar outlives a closed Paldex, and so does our tab in it. Building a
    -- second one is how the bar ended up with two "Evolutions" side by side.
    local existing, at = findOurTab(box)
    if existing then
        paldexTab, paldexIndex = existing, at
        Log(string.format("the Evolutions tab is already in the bar at %d", at))
        return true
    end

    local before = 0
    pcall(function() before = box:GetChildrenCount() end)

    local cls = StaticFindObject(PALDEX_TAB)
    if not (cls and cls:IsValid()) then
        pcall(function() LoadAsset(PALDEX_TAB) end)
        cls = StaticFindObject(PALDEX_TAB)
    end
    if not (cls and cls:IsValid()) then
        Log("WBP_Paldex_tab_C is not loaded")
        return false
    end

    local pc = FindFirstOf("PalPlayerController")
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local tab = nil
    pcall(function() tab = lib:Create(pc, cls, pc) end)
    if not (tab and tab:IsValid()) then
        Log("the Evolutions tab did not build")
        return false
    end

    -- The label goes in directly. The game fills it from a message table via
    -- MsgID, which we have no row in - setting the text is the honest shortcut.
    pcall(function()
        local t = textOf("Evolutions")
        if t and tab.Text_Title and tab.Text_Title:IsValid() then
            tab.Text_Title:SetText(t)
        end
    end)

    -- The returned slot decides the width. Left on its own the tab shrinks to
    -- the text, while the game's two share the bar - so it gets the same fill
    -- rule they have.
    local slot = nil
    pcall(function() slot = box:AddChildToHorizontalBox(tab) end)
    if slot and slot:IsValid() then
        -- ESlateSizeRule: 0 = Automatic, 1 = Fill.
        -- The alignments are Fill = 0, not 3: 3 is Right and Bottom, which is
        -- what left the tab its designed width, pinned to the right edge of a
        -- third of the bar - the label hanging right and the tiny hit area were
        -- the same mistake seen twice.
        pcall(function() slot:SetSize({ Value = 1.0, SizeRule = 1 }) end)
        pcall(function() slot:SetHorizontalAlignment(0) end)  -- HAlign_Fill
        pcall(function() slot:SetVerticalAlignment(0) end)    -- VAlign_Fill
    else
        Log("no slot returned - the tab keeps its own width")
    end
    -- Re-registered so the tabset counts its children again; without this the
    -- new child is on screen but not part of the selection.
    pcall(function() tabset:RegisterPanelWidget(box) end)

    local after = 0
    pcall(function() after = box:GetChildrenCount() end)
    -- Matched to the game's own tabs, which are SelfHitTestInvisible: the tab
    -- takes no hits itself, the button inside it does. A tab set to Visible can
    -- swallow the click before it ever reaches that button.
    pcall(function() tab:SetVisibility(4) end)   -- ESlateVisibility::SelfHitTestInvisible
    -- The label is centred through the tab that owns it. Looking for it among
    -- every text block in the game, and asking each one who its owner is, hung
    -- the Lua thread for good - and a hung thread leaves no line behind.
    pcall(function() tab.Text_Title:SetJustification(2) end)  -- ETextJustify::Center

    paldexTab = tab
    paldexIndex = after - 1
    Log(string.format("Evolutions tab added: children %d -> %d, our index %d",
        before, after, paldexIndex))
    return true
end

--- Follows the Pal the Paldex is showing, so the tree can centre on it. There is
--- more than one WBP_Paldex_C alive - the screen sits inside a display wrapper -
--- so every instance is asked and the one holding a Pal wins.
local function paldexCharacter()
    for _, o in ipairs(FindAllOf(PALDEX_SCREEN) or {}) do
        local n = ""
        pcall(function() n = tostring(o:GetFullName()) end)
        if o:IsValid() and not n:find("Default__") then
            local id = nil
            pcall(function() id = tostring(o.nowRenderCharacterID:ToString()) end)
            if id and id ~= "" and id ~= "None" then return id end
        end
    end
    return nil
end

function M.start()
    if paldexStarted then
        Log("the Palpedia tree is already running")
        return
    end
    paldexStarted = true

    -- Which tab is selected: the tabset calls SelectByIndex on itself, and a
    -- Blueprint function can be hooked even though its delegate cannot be bound.
    -- It cannot be hooked at load time though - the Paldex blueprint is not in
    -- memory until the screen is opened once, and a hook needs the function to
    -- exist. So it is tried again from the watcher below.
    local function addressOf(o)
        local a = 0
        pcall(function() a = o:GetAddress() end)
        return a
    end

    local hookTries = 0
    local function hookSelect()
        if paldexClickHooked then return end
        -- Retried, not registered once: the hook needs the tab blueprint to be
        -- in memory, and one run had it fail on the first opening and then log
        -- nothing for the rest of the session.
        hookTries = hookTries + 1
        if hookTries > 20 then return end

        -- Every CommonUI button in the game reports through this one, so it says
        -- whether a click reaches our button at all - which no hook on the tab's
        -- own event can answer while that event never runs. Registered once even
        -- though the block is retried: stacking hooks on a function the whole
        -- game uses is how one session ended up with a hundred of them.
        if not paldexNativeHooked then
            paldexNativeHooked = pcall(function()
                RegisterHook("/Script/CommonUI.CommonButtonBase:HandleButtonClicked",
                    function(ctx)
                        if paldexBusy then return end
                        local obj = nil
                        pcall(function() obj = ctx:get() end)
                        local n = "?"
                        pcall(function() n = tostring(obj:GetFullName()) end)
                        -- A row of the Pal list on the left. The row itself is
                        -- the only thing that knows which Pal it stands for -
                        -- the screen keeps only nowRenderCharacterID, and that
                        -- one belongs to the model view and stands still while
                        -- the habitat page is up. Remembered here, asked later:
                        -- a Blueprint call from inside a hook freezes the game.
                        if n:find("Paldex", 1, true) then
                            Log("a Palpedia button was clicked: " .. n)
                        end
                        -- Only the name is taken here. Walking the owner chain
                        -- from inside a hook is a call into the engine at the
                        -- worst possible moment, and it left nothing behind
                        -- when it failed. The row itself is looked up later,
                        -- from this string.
                        if n:find("WBP_Paldex_List_C", 1, true) then
                            paldexPendingRowName = n
                        end
                    end)
            end)
            Log("CommonUI button hook: " .. tostring(paldexNativeHooked))
        end

        -- The hook only writes down what happened. Everything the click leads to
        -- runs a tick later from the loop below: calling a Blueprint function
        -- from inside a hook froze the game, and building the page there would
        -- block the click's own call stack for as long as it takes.
        local okTab = pcall(function()
            RegisterHook(TAB_CLICKED, function(ctx)
                local obj = nil
                pcall(function() obj = ctx:get() end)
                -- Compared by address, because two wrappers around the same
                -- object are not equal to each other.
                if paldexTab and addressOf(obj) == addressOf(paldexTab) then
                    paldexWant = "open"
                else
                    paldexWant = "close"
                end
            end)
        end)
        if okTab then
            paldexClickHooked = true
            Log("tab click hook registered")

        elseif hookTries == 20 then
            Log("the tab click hook never took")
        end
    end

    -- The Paldex only exists while it is open, so the tab is put in whenever it
    -- appears and forgotten when it goes away.
    -- The whole body is guarded: an error in here does not just skip a tick, it
    -- ends the loop, and the mod then goes quiet for the rest of the session
    -- with nothing in the log to say why.
    local tries = 0
    local loopFailed = false
    --- The Palpedia counts as open only while it is on screen. Closing the menu
    --- with ESC hides it and keeps the widget alive, so asking whether the
    --- screen exists answers yes long after the player has left: the tree page
    --- then stayed up over the world, and because "closed" never happened, the
    --- attempt counter never reset either - after eight tries the mod gave up
    --- and the tab was missing from every Palpedia afterwards.
    local function paldexOnScreen()
        -- The one that is showing, not the first one that exists. The game
        -- keeps more than one Palpedia alive - one of them inside its display
        -- wrapper - and asking the wrong one whether it is visible answers no
        -- for as long as the session lasts. The tab is then never put back.
        for _, o in ipairs(FindAllOf(PALDEX_SCREEN) or {}) do
            local n = ""
            pcall(function() n = tostring(o:GetFullName()) end)
            if o:IsValid() and n:find("/Engine/Transient", 1, true)
                and not n:find("Default__", 1, true) then
                local shown = false
                pcall(function() shown = o:IsVisible() end)
                if shown then return o end
            end
        end
        return nil
    end

    local function paldexTick()
        local screen = paldexOnScreen()
        if not screen then
            -- Closed, whichever way: a tab, the menu key, or the screen going
            -- away under us. A page of the Palpedia has to follow in every one of
            -- them - left behind, it hangs over the world with nothing to close
            -- it. A window that was never a page of it stays, because it has its
            -- own way out.
            if paldexTab or tries > 0 then
                paldexTab, paldexIndex, tries, paldexLit = nil, -1, 0, false
                Log("the Palpedia closed")
            end
            if treeWebOpen and treeWebDocked then paldexWant = "close" end
            return
        end
        hookSelect()
        -- A tab that is valid but hangs in a bar nobody shows any more is gone:
        -- leaving the Paldex and coming back builds the screen again, and the
        -- old tab kept the mod from ever putting a new one in.
        if paldexTab and paldexTab:IsValid() then
            local _, liveBox = liveTabsetWithBox()
            if addrOf(parentPanelOf(paldexTab)) ~= addrOf(liveBox) then
                paldexTab, paldexIndex, paldexLit = nil, -1, false
                Log("the tab belongs to a Palpedia that is gone")
            end
        end
        if not (paldexTab and paldexTab:IsValid()) then
            -- Leaving through the menu bar - Mission and back - rebuilds this
            -- screen without our tab while the page is still up. Without a tab
            -- there is nothing to switch away from, so the page goes too.
            if treeWebOpen and treeWebDocked then paldexWant = "close" end
            -- A handful of attempts per opening, not one per tick: the same
            -- failure twice a second buries everything else in the log. The
            -- count keeps running while the screen is up and starts over every
            -- time it goes away, so a run of failures can never be permanent.
            if tries < 8 then
                tries = tries + 1
                injectPaldexTab()
            end
        elseif treeWebOpen and paldexIndex >= 0 then
            -- Shoulder buttons and the gamepad switch tabs without ever
            -- clicking one, so the current index is watched as well.
            local ts = paldexSelector()
            local now = -1
            if ts then pcall(function() now = ts.NowFocusChildIndex end) end
            if now >= 0 and now ~= paldexIndex then
                paldexWant = "close"
            end
        end
        return false
    end

    LoopAsync(500, function()
        local ok, err = pcall(paldexTick)
        if not ok and not loopFailed then
            loopFailed = true
            Log("watching the Palpedia failed: " .. tostring(err))
        end
        return false
    end)

    -- What the click asked for, carried out off the hook and quickly enough to
    -- still feel like a click.
    local fastFailed = false
    local function paldexFastTick()
        -- Whether the Palpedia is still on screen, asked at this rate rather than
        -- the slower one, but only while our page is up. Half a second between
        -- the screen going away and the page following it is long enough to
        -- look like the page is stuck.
        if treeWebOpen and treeWebDocked and not paldexOnScreen() then
            paldexWant = "close"
        end

        -- Picking another Pal in the list builds the habitat page again, and
        -- the map comes back with it. While our page is the one on show, it is
        -- put away again as soon as it reappears.
        if treeWebOpen and paldexHost and paldexMap and paldexMap:IsValid() then
            local vis = -1
            pcall(function() vis = paldexMap:GetVisibility() end)
            if vis ~= 1 then pcall(function() paldexMap:SetVisibility(1) end) end
        end

        -- Which Pal the list was last put on, asked off the row that was
        -- clicked rather than off the screen.
        if paldexPendingRowName then
            local wanted = paldexPendingRowName
            paldexPendingRowName = nil

            -- Looked up right here. Reading names is read-only work and needs
            -- no detour over the game thread, and inside that detour a failure
            -- leaves nothing behind at all - which is exactly how this step
            -- went missing twice.
            local row = nil
            for _, o in ipairs(FindAllOf("WBP_Paldex_List_C") or {}) do
                local m = ""
                pcall(function() m = tostring(o:GetFullName()) end)
                local path = m:match("%s(.+)$") or m
                if path ~= "" and wanted:find(path .. ".", 1, true) then
                    row = o
                    break
                end
            end
            if row then
                -- Only the call into the game is deferred, and it says so when
                -- it fails.
                -- The row's own property, not its getter: GetCharacterID takes
                -- an out parameter and refuses a bare call. The name carries a
                -- typo in the game, and that typo is the property.
                local id = nil
                pcall(function()
                    id = tostring(row.ChachedBaseCharacterID:ToString())
                end)
                if id and id ~= "" and id ~= "None" then
                    paldexListPick = id
                    Log(string.format("the Palpedia list is on %s (showing %s)",
                        id, tostring(treeWebCurrent)))
                else
                    Log("the list row would not say its Pal")
                end
            else
                Log("no list row matches " .. wanted)
            end
        end

        -- Whatever the list was last put on wins. Written down by the step
        -- above and acted on here rather than there, so the page catching up
        -- does not depend on any one path through the click.
        -- Asked of the docked flag, not of the host panel: the host is cleared
        -- and set again on every switch, and a redraw missed in that gap never
        -- came back.
        if treeWebOpen and treeWebDocked and paldexListPick
            and paldexListPick ~= treeWebCurrent then
            local id = paldexListPick
            -- The page is built HERE, not on the game thread. It is string work
            -- and file reads, and on a cold icon cache it takes seconds - a
            -- player's log shows 7.4 s for one page. Done inside
            -- ExecuteInGameThread that time is spent with the game frozen, and
            -- switching Pals a few times in a row stacks those freezes until
            -- the game looks dead. Only the handover to the browser needs the
            -- game thread.
            local okHtml, html = pcall(require, "treehtml")
            if okHtml and html then
                local page = html.page(id)
                treeWebCurrent = id
                treeWebPage = page
                treeWebPageFor = id
                ExecuteInGameThread(function()
                    -- Several switches can be queued before the game thread
                    -- gets here; only the newest page is worth showing.
                    if treeWebPage ~= page then return end
                    if treeWebBrowser and treeWebBrowser:IsValid() then
                        pcall(function()
                            treeWebBrowser:LoadString(page, TREE_ORIGIN)
                        end)
                        Log("the tree follows to " .. id)
                    end
                end)
            end
        end

        local want = paldexWant
        if not want then return end
        paldexWant = nil

        -- Built before the handover, for the same reason the switch above is:
        -- on a cold cache this is seconds of work, and the game thread is the
        -- one place where those seconds are visible to the player.
        if want == "open" then
            local id = paldexListPick or paldexCharacter()
            local okHtml, html = pcall(require, "treehtml")
            if id and okHtml and html then
                html.setDocked(true)
                treeWebCurrent = id
                treeWebPage = html.page(id)
                treeWebPageFor = id
            end
        end

        ExecuteInGameThread(function()
            if want == "close" then
                closeTreeWeb()
                -- A highlight we drew by hand is ours to take back: the game
                -- unfocuses the tab it thinks was selected, which is not ours.
                if paldexLit and paldexTab and paldexTab:IsValid() then
                    pcall(function() paldexTab:AnmEvent_Unfocus() end)
                    paldexLit = false
                end
                return
            end

            -- The tabset is told as well, so the bar draws the selection on our
            -- tab. Its own two report to it through dispatchers bound in the
            -- editor; a tab built at runtime has nobody listening.
            local box = parentPanelOf(paldexTab)
            local ts = selectorForBox(box)
            if ts and paldexIndex >= 0 then
                -- The habitat page first, through the game's own handler: it
                -- clears the model view and the values panel the way it always
                -- does. Only then is the selection moved onto our tab, so the
                -- bar reads "Evolutions" while the screen is laid out for a map.
                -- Everything that calls into the game runs inside one guard,
                -- and the guard is lifted whatever happens in there: left
                -- standing it silences the mod's own hooks for good, and with
                -- them the list, the tab switch and the close.
                paldexBusy = true
                local okAll, errAll = pcall(function()
                    showHabitatPage(ts)
                    local before, after = -1, -1
                    pcall(function() before = ts.NowFocusChildIndex end)
                    local ok, err = pcall(function() ts:SelectByIndex(paldexIndex) end)
                    pcall(function() after = ts.NowFocusChildIndex end)
                    Log(string.format("tab selected %s (%s), focus %d -> %d of %d",
                        tostring(ok), tostring(err), before, after, paldexIndex))
                    -- Lit by hand as well. The tabset does take the index, but
                    -- what draws a tab as selected is an animation the tab
                    -- plays on itself, and the tabset plays it only on the two
                    -- it was built with.
                    paldexLit = lightTab(box, paldexTab)
                end)
                paldexBusy = false
                if not okAll then
                    Log("switching to the tree tab failed: " .. tostring(errAll))
                end
            else
                Log("no tabset owns our tab bar")
            end

            local id = paldexListPick or paldexCharacter()
            Log("opening the tree on " .. tostring(id))
            openTreeWebFor(id, parentPanelOf(ts))
        end)
    end

    -- Guarded like the slower loop: an error in here does not skip a beat, it
    -- ends the loop, and everything it drives goes quiet without a word.
    LoopAsync(60, function()
        local ok, err = pcall(paldexFastTick)
        if not ok and not fastFailed then
            fastFailed = true
            Log("watching the Palpedia clicks failed: " .. tostring(err))
        end
        return false
    end)

    Log("the Palpedia tree is ready")
end


-- Started on load: the tab has to be there the first time the player opens the
-- Palpedia, and there is no earlier moment to hook it than the mod starting.
-- Warms the icon cache in the background so the first page has nothing left to
-- encode. Every portrait is read off disk and turned into base64 in plain Lua,
-- which is cheap once and slow all at once: a player's log shows a first page
-- taking 7.4 seconds with a cold cache, against 30 ms with a warm one. Four
-- icons per tick is small enough not to be felt and done long before anyone
-- opens the Palpedia.
LoopAsync(400, function()
    local ok, html = pcall(require, "treehtml")
    if not (ok and html and html.warmIcons) then return true end
    local more = false
    local okWarm = pcall(function() more = html.warmIcons(4) end)
    if not okWarm then return true end
    if not more then
        Log("Pal portraits ready")
        -- Verdict on the pak while nobody is waiting on it, so a support log
        -- answers "is the page even installed" without anyone having to open a
        -- Palpedia first. Loading it here also takes the cost off the first open.
        ExecuteInGameThread(function()
            -- Guarded, so a load that throws instead of returning nil neither
            -- takes the game thread down nor gets reported as a missing file.
            local ok, cls, how = pcall(loadClass, WEB_PKG, WEB_ASSET)
            if not ok then
                Log("checking the tree page asset failed: " .. tostring(cls))
            elseif cls then
                Log(string.format("tree page asset ready (%s)", how))
            else
                logMissingPak(how)
            end
        end)
        return true
    end
    return false
end)

ExecuteInGameThread(function() M.start() end)

return M
