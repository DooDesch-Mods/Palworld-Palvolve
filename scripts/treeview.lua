-- The in-game evolution tree: a list of every Pal this world has a path for,
-- and for the selected one, where it comes from and where it can go.
--
-- Built from UMG widgets that Lua constructs at runtime. That is possible
-- because a CanvasPanel takes children from Lua and a UserWidget's WidgetTree
-- can be pointed at it (measured in-game 2026-08-10: 300 nodes in 9 ms). The
-- icons are Palworld's own textures, so nothing here ships art.
--
-- Deliberately one hop deep. A whole tree is 300 nodes and unreadable on a
-- screen; one Pal with its parents and its targets is never more than a dozen,
-- and a badge on a neighbour says how many further paths it has. Following one
-- means clicking it, which makes it the new centre.

local Config = require("config")

local M = {}

--- The localized species name, from the same place the wheel and the guide
--- pages take it. Required lazily: evolution.lua pulls in half the mod, and
--- this window is opened long after both are loaded.
local function palName(id)
    local ok, evo = pcall(require, "evolution")
    if ok and evo and evo.displayName then
        local okName, name = pcall(evo.displayName, id)
        if okName and name then return name end
    end
    return id
end

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- ---------------------------------------------------------------- geometry

local LIST_W = 296
local ROW_H = 44
local ICON = 30
local CARD = 68
local CARD_BIG = 104
local COL_GAP = 150

-- Element tints, the same ones the website uses, so a Pal is the same colour
-- in both places.
local ELEMENT_RGB = {
    Normal = { 0.60, 0.65, 0.71 }, Fire = { 1.00, 0.44, 0.26 },
    Water = { 0.31, 0.66, 0.96 }, Leaf = { 0.36, 0.76, 0.41 },
    Electricity = { 0.96, 0.82, 0.18 }, Ice = { 0.37, 0.84, 0.84 },
    Earth = { 0.75, 0.54, 0.29 }, Dark = { 0.63, 0.42, 0.84 },
    Dragon = { 0.78, 0.42, 0.69 },
}

local okElements, Elements = pcall(require, "elements_static")
if not okElements then Elements = {} end

local function tintOf(palId)
    local els = Elements[palId]
    local rgb = ELEMENT_RGB[els and els[1] or "Normal"] or ELEMENT_RGB.Normal
    return { R = rgb[1], G = rgb[2], B = rgb[3], A = 1.0 }
end

-- ------------------------------------------------------------- the model

--- Every Pal the loaded tree knows a step for, in paldex order where known.
--- Only these go in the list: a Pal without a path answers no question.
-- Built once and handed out again afterwards. Every page asks for this list
-- before anything else, so on a 613 pair tree the walk and the sort used to run
-- on every single click. The cached list is dropped when the names change
-- underneath it, which happens exactly once: the text system answers with raw
-- ids until a world is up, so the first list is sorted by id and every later
-- one by the name the player reads.
local listedCache = nil
local listedProbe = nil

local function listedPals()
    if listedCache and listedProbe and palName(listedProbe.id) == listedProbe.name then
        return listedCache
    end
    local seen, ids = {}, {}
    for _, p in ipairs(Config.map or {}) do
        if p.enabled then
            for _, id in ipairs({ p.from, p.to }) do
                if not seen[id] then
                    seen[id] = true
                    table.insert(ids, id)
                end
            end
        end
    end
    -- by the name the player reads, not by the internal id: nobody looking for
    -- Lamball is scanning for "SheepBall". The names are resolved once into a
    -- lookup instead of inside the comparator, which table.sort calls O(n log n)
    -- times: 279 lookups rather than the roughly 4600 that cost.
    local byName = {}
    for _, id in ipairs(ids) do byName[id] = palName(id) end
    table.sort(ids, function(a, b) return byName[a] < byName[b] end)
    listedCache = ids
    listedProbe = ids[1] and { id = ids[1], name = byName[ids[1]] } or nil
    return ids
end

--- One entry per neighbour, not per pair: a species reachable two ways is one
--- Pal with two rules under it, because the reader is looking for a target.
local function neighbours(palId, dir)
    local grouped, order = {}, {}
    for _, p in ipairs(Config.map or {}) do
        if p.enabled then
            local mine = (dir == "out" and p.from == palId) or (dir == "in" and p.to == palId)
            if mine then
                local other = dir == "out" and p.to or p.from
                if not grouped[other] then
                    grouped[other] = { id = other, steps = {} }
                    table.insert(order, grouped[other])
                end
                table.insert(grouped[other].steps, p)
            end
        end
    end
    return order
end

--- How many further steps a Pal has of its own, which is what a badge counts.
local function onwardCount(palId)
    local seen, n = {}, 0
    for _, p in ipairs(Config.map or {}) do
        if p.enabled and p.from == palId and not seen[p.to] then
            seen[p.to] = true
            n = n + 1
        end
    end
    return n
end

-- ---------------------------------------------------------- widget helpers

local CLS = {}
local function cls(path)
    if CLS[path] == nil then
        local c = nil
        pcall(function() c = StaticFindObject(path) end)
        CLS[path] = c
    end
    return CLS[path]
end

local widgetOuter = nil
local function outer()
    if widgetOuter and widgetOuter:IsValid() then return widgetOuter end
    for _, o in ipairs(FindAllOf("PalHUDInGame") or {}) do
        local n = ""
        pcall(function() n = tostring(o:GetFullName()) end)
        if o:IsValid() and not n:find("Default__") then
            widgetOuter = o
            return o
        end
    end
    return FindFirstOf("PalPlayerController")
end

local made = 0
local function construct(path, prefix)
    local c = cls(path)
    if not (c and c:IsValid()) then return nil end
    made = made + 1
    local obj = nil
    pcall(function() obj = StaticConstructObject(c, outer(), FName(prefix .. made)) end)
    if obj and obj:IsValid() then return obj end
    return nil
end

local function place(canvas, widget, x, y, w, h)
    local slot = nil
    pcall(function() slot = canvas:AddChildToCanvas(widget) end)
    if not (slot and slot:IsValid()) then return nil end
    pcall(function()
        slot:SetAutoSize(false)
        slot:SetPosition({ X = x + 0.0, Y = y + 0.0 })
        slot:SetSize({ X = w + 0.0, Y = h + 0.0 })
    end)
    return slot
end

--- A filled rectangle. An Image with no brush draws the engine's placeholder at
--- a size of its own, which is what put a grey wash over the whole screen on
--- the first run: the fill has to come from a real texture that is then tinted.
local whiteTex = nil
local function white()
    if whiteTex ~= nil then return whiteTex or nil end
    local path = "/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"
    local tex = nil
    pcall(function() tex = StaticFindObject(path) end)
    if not (tex and tex:IsValid()) then
        pcall(function() LoadAsset(path) end)
        pcall(function() tex = StaticFindObject(path) end)
    end
    whiteTex = (tex and tex:IsValid()) and tex or false
    return whiteTex or nil
end

local function solid(canvas, x, y, w, h, color)
    local img = construct("/Script/UMG.Image", "PvBox")
    if not img then return nil end
    local tex = white()
    if tex then
        pcall(function() img:SetBrushFromTexture(tex, false) end)
    end
    pcall(function() img:SetColorAndOpacity(color) end)
    place(canvas, img, x, y, w, h)
    return img
end

--- FText from a Lua string. The direct FText() resolves the engine converter
--- once per session, and a first call made before UE4SS finished initializing
--- stays broken for the rest of it, so the engine's own converter is the
--- fallback (same reason and same shape as radialmenu.lua).
local function toText(s)
    local okDirect, text = pcall(FText, s)
    if okDirect and text then return text end
    local okFallback, converted = pcall(function()
        local ktl = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        if not (ktl and ktl:IsValid()) then return nil end
        return ktl:Conv_StringToText(s)
    end)
    if okFallback and converted then return converted end
    return nil
end

local function label(canvas, text, x, y, w, size, color)
    local tb = construct("/Script/UMG.TextBlock", "PvText")
    if not tb then return nil end
    pcall(function()
        local t = toText(tostring(text))
        if t then tb:SetText(t) end
        tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
    end)
    -- Sizing the slot does not size the type. The font struct is read, changed
    -- and handed back, because writing into the property in place edits a copy.
    pcall(function()
        local f = tb.Font
        f.Size = size
        tb:SetFont(f)
    end)
    place(canvas, tb, x, y, w, size + 8)
    return tb
end

local ICON_PATH = "/Game/Pal/Texture/PalIcon/Normal/T_%s_icon_normal.T_%s_icon_normal"
local iconCache = {}
local function palIcon(palId)
    if iconCache[palId] ~= nil then return iconCache[palId] or nil end
    local path = string.format(ICON_PATH, palId, palId)
    local tex = nil
    pcall(function() tex = StaticFindObject(path) end)
    if not (tex and tex:IsValid()) then
        pcall(function() LoadAsset(path) end)
        pcall(function() tex = StaticFindObject(path) end)
    end
    iconCache[palId] = (tex and tex:IsValid()) and tex or false
    return iconCache[palId] or nil
end

local function palImage(canvas, palId, x, y, size)
    local img = construct("/Script/UMG.Image", "PvIcon")
    if not img then return nil end
    local tex = palIcon(palId)
    if tex then pcall(function() img:SetBrushFromTexture(tex, false) end) end
    place(canvas, img, x, y, size, size)
    return img
end

-- ------------------------------------------------------------------ state

local win = nil          -- the root UserWidget on the viewport
local canvas = nil       -- everything is drawn onto this
local pals = {}          -- ids in the list
local selected = 1       -- index into pals
local listTop = 1        -- first visible row
local rowsVisible = 12

local WHITE = { R = 0.92, G = 0.94, B = 0.97, A = 1.0 }
local DIM = { R = 0.62, G = 0.69, B = 0.76, A = 1.0 }
local GOLD = { R = 0.94, G = 0.76, B = 0.29, A = 1.0 }
local PANEL = { R = 0.106, G = 0.141, B = 0.188, A = 0.97 }
local PANEL2 = { R = 0.094, G = 0.129, B = 0.173, A = 1.0 }
local SEL = { R = 0.173, G = 0.239, B = 0.318, A = 1.0 }

--- Draws the whole window from scratch. Cheap enough to redraw on every move:
--- the measured cost of a few hundred widgets is single-digit milliseconds, and
--- rebuilding beats keeping a diff of what changed.
local function redraw(screenW, screenH)
    if not (canvas and canvas:IsValid()) then return end
    pcall(function() canvas:ClearChildren() end)

    local id = pals[selected]
    if not id then return end

    solid(canvas, 0, 0, screenW, screenH, PANEL)
    solid(canvas, 0, 0, LIST_W, screenH, PANEL2)
    solid(canvas, 0, 0, screenW, 46, PANEL2)
    label(canvas, "Palvolve", 18, 13, 120, 17, WHITE)
    label(canvas, string.format("%d Pals have a path in this world", #pals), 120, 16, 340, 12, DIM)
    label(canvas, "arrow keys to move  -  ESC closes", screenW - 300, 16, 280, 12, DIM)

    -- the list, only the slice that fits on screen
    rowsVisible = math.max(4, math.floor((screenH - 80) / ROW_H))
    if selected < listTop then listTop = selected end
    if selected > listTop + rowsVisible - 1 then listTop = selected - rowsVisible + 1 end
    for i = 0, rowsVisible - 1 do
        local idx = listTop + i
        local pid = pals[idx]
        if pid then
            local y = 58 + i * ROW_H
            if idx == selected then solid(canvas, 8, y - 3, LIST_W - 16, ROW_H - 4, SEL) end
            palImage(canvas, pid, 16, y, ICON)
            label(canvas, palName(pid), 16 + ICON + 10, y + 6, 180, 13, WHITE)
            solid(canvas, LIST_W - 22, y + 12, 7, 7, tintOf(pid))
        end
    end

    -- the selected Pal, and one hop in each direction
    local cx = LIST_W + (screenW - LIST_W) / 2
    local cy = screenH / 2
    palImage(canvas, id, cx - CARD_BIG / 2, cy - CARD_BIG / 2, CARD_BIG)
    label(canvas, palName(id), cx - 90, cy + CARD_BIG / 2 + 8, 180, 15, WHITE)
    label(canvas, "SELECTED", cx - 40, cy - CARD_BIG / 2 - 22, 100, 10, DIM)

    local function drawSide(list, dir)
        local sign = dir == "out" and 1 or -1
        local x = cx + sign * (CARD_BIG / 2 + COL_GAP)
        local total = #list
        for i, n in ipairs(list) do
            local y = cy + (i - (total + 1) / 2) * 120
            palImage(canvas, n.id, x - CARD / 2, y - CARD / 2, CARD)
            label(canvas, palName(n.id), x - 56, y + CARD / 2 + 6, 112, 12, WHITE)
            -- the rule under the connector, so stacked conditions grow downward
            local ry = y + 4
            for _, p in ipairs(n.steps) do
                local stone = p.stone == "adaptation" and "Adaptation" or "Evolution"
                label(canvas, string.format("Lv %d - %s Stone", p.minLevel or 0, stone),
                    x - sign * (COL_GAP / 2) - 70, ry, 150, 10, DIM)
                ry = ry + 13
                if p.conditions and #p.conditions > 0 then
                    label(canvas, table.concat(p.conditions, ", "),
                        x - sign * (COL_GAP / 2) - 70, ry, 150, 10, GOLD)
                    ry = ry + 13
                end
            end
            local badge = onwardCount(n.id) - (dir == "in" and 1 or 0)
            if badge > 0 then
                solid(canvas, x + CARD / 2 - 12, y - CARD / 2 - 6, 20, 20, GOLD)
                label(canvas, tostring(badge), x + CARD / 2 - 6, y - CARD / 2 - 4, 20, 11, PANEL2)
            end
        end
        if total == 0 then
            label(canvas, dir == "in" and "nothing evolves into this one" or "this is the end of the line",
                x - 90, cy - 6, 180, 11, DIM)
        end
    end

    drawSide(neighbours(id, "in"), "in")
    drawSide(neighbours(id, "out"), "out")
end

-- ------------------------------------------------------------------ opening

local function screenSize()
    local w, h = 1920, 1080
    local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local pc = FindFirstOf("PalPlayerController")
    if lib and pc then
        pcall(function()
            local v = lib:GetViewportSize(pc)
            if v and v.X and v.X > 0 then w, h = v.X, v.Y end
        end)
    end
    return w, h
end

-- The model is the same whoever draws it. The window below is one reader; the
-- widgets in the pak are another, and they get it through here rather than
-- rebuilding the same three walks over Config.map.
--- Active and total pairs, counted the way the configurator counts them, so the
--- header in the game and the line on the website say the same thing about the
--- same config. The Pal count alone was read as the number of evolutions twice
--- in one hour by two different people.
local function stepCount()
    local active, total = 0, 0
    for _, p in ipairs(Config.map or {}) do
        total = total + 1
        if p.enabled then active = active + 1 end
    end
    return active, total
end

M.stepCount = stepCount
M.listedPals = listedPals
M.neighbours = neighbours
M.onwardCount = onwardCount
M.palName = palName

function M.close()
    local pc = FindFirstOf("PalPlayerController")
    if pc and pc:IsValid() then
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        pcall(function() lib:SetInputMode_GameOnly(pc, true) end)
        pcall(function() pc.bShowMouseCursor = false end)
    end
    if win and win:IsValid() then pcall(function() win:RemoveFromParent() end) end
    win, canvas = nil, nil
end

function M.isOpen()
    return win ~= nil and win:IsValid()
end

function M.open()
    if M.isOpen() then
        M.close()
        return
    end
    local pc = FindFirstOf("PalPlayerController")
    if not (pc and pc:IsValid()) then
        Log("[tree] no player controller")
        return
    end

    pals = listedPals()
    if #pals == 0 then
        Log("[tree] this world has no configured evolutions")
        return
    end
    selected, listTop = 1, 1

    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local root = nil
    pcall(function() root = lib:Create(pc, cls("/Script/UMG.UserWidget"), pc) end)
    if not (root and root:IsValid()) then
        Log("[tree] could not create the window")
        return
    end

    canvas = construct("/Script/UMG.CanvasPanel", "PvCanvas")
    if not canvas then
        Log("[tree] could not create the canvas")
        return
    end

    -- A UserWidget made without a Blueprint arrives with an empty tree; pointing
    -- its root at our canvas is what puts anything on screen at all.
    local attached = false
    pcall(function()
        root.WidgetTree.RootWidget = canvas
        attached = true
    end)
    if not attached then
        Log("[tree] could not attach the canvas to the window")
        return
    end

    win = root
    local w, h = screenSize()
    redraw(w, h)
    pcall(function() win:AddToViewport(60) end)

    -- The cursor is shown but the game keeps focus handling: pinning focus to
    -- the outer widget takes clicks away from anything inside it.
    pcall(function() lib:SetInputMode_UIOnlyEx(pc, nil, 0, false) end)
    pcall(function() pc.bShowMouseCursor = true end)

    Log(string.format("[tree] open: %d Pals, showing %s", #pals, pals[selected]))
end

--- Keyboard navigation. Clicks are the goal, but binding a UMG button delegate
--- from Lua is untested in this project, and the window has to be usable either
--- way. Up and down walk the list, left and right step to a neighbour.
function M.move(delta)
    if not M.isOpen() then return end
    selected = math.max(1, math.min(#pals, selected + delta))
    local w, h = screenSize()
    redraw(w, h)
end

function M.step(dir)
    if not M.isOpen() then return end
    local list = neighbours(pals[selected], dir)
    if #list == 0 then return end
    local target = list[1].id
    for i, id in ipairs(pals) do
        if id == target then
            selected = i
            local w, h = screenSize()
            redraw(w, h)
            Log("[tree] centred on " .. target)
            return
        end
    end
end

return M
