-- fusepick.lua: the pick window before an altar fusion.
--
-- The player chooses up to four passives out of both Pals and the gender of the
-- fused Pal. It is the same browser widget the tree page uses (paldextree.lua),
-- with the same rules: JavaScript is dead in it, so every control is a fragment
-- link, the page is rebuilt on every click, and the mod reads the clicks off the
-- address bar.
--
--   #p/<n>   toggles passive n of the pool
--   #g/<1|2> picks male or female
--   #ok      confirms, #close cancels

local I18n = require("i18n")
local Role = require("role")
local GameLoop = require("gameloop")

local M = {}

local ORIGIN = "http://palvolve.local/fusion"
local MAX_PICKS = 4

local function Log(msg)
    print(string.format("[Palvolve] [fusepick] %s\n", tostring(msg)))
end

local window, browser = nil, nil
local state = nil       -- the open pick: info, picked, gender, onConfirm
local lastUrl = ""
local ticks = 0
local delivered = false
local driving = false    -- one loop drives the window at a time
local urlUnreadable = false
local page = ""

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local CSS = [[
*{box-sizing:border-box}
html,body{margin:0;height:100%;overflow:hidden}
body{--tc:#6f8ba638;background:radial-gradient(90% 60% at 72% 18%,var(--tc) 0%,transparent 60%),
  radial-gradient(120% 90% at 50% 0%,#1a2432 0%,#121a24 45%,#0d131b 100%);
  color:#e6edf6;font:16px/1.45 "Segoe UI",system-ui,sans-serif;display:flex;flex-direction:column;
  border:1px solid #3d5068;box-shadow:inset 0 0 0 2px #0c1119}
a{text-decoration:none;color:inherit;transition:background-color 140ms ease-out,border-color 140ms ease-out,color 140ms ease-out}
.ico{width:1em;height:1em;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex:none}
.top{display:flex;align-items:center;gap:14px;padding:12px 22px;
  background:linear-gradient(#1e2939,#161e2a);border-bottom:1px solid #2c3a4b}
.brand{font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#f2b33d;font-size:12px}
.title{font-weight:600;font-size:15px;color:#cfe0f0}

/* The equation is the page: two Pals going in, the one coming out larger and
   lit in its own element colour. */
.hero{display:flex;align-items:center;justify-content:center;gap:16px;padding:16px 24px 12px}
.pal{display:flex;flex-direction:column;align-items:center;gap:6px;min-width:0}
.disc{position:relative;width:var(--s);height:var(--s);border-radius:50%;overflow:hidden;
  background:radial-gradient(circle at 50% 38%,#24303f 0%,#151d28 100%);
  box-shadow:0 0 0 2px var(--tint)}
.disc img{width:100%;height:100%;object-fit:cover;display:block}
.disc .mono{display:flex;height:100%;align-items:center;justify-content:center;color:#8296ab}
.pname{font-size:15px;font-weight:600;color:#dce5f0;text-align:center}
.lv{font-size:12.5px;color:#8fa3b8;font-variant-numeric:tabular-nums;margin-top:-4px}
.in{--s:84px}
.out{--s:120px}
.out .disc{box-shadow:0 0 0 3px var(--tint),0 0 0 7px rgba(242,193,78,.18),0 12px 28px -10px rgba(0,0,0,.75)}
.out .pname{font-size:18px;color:#f5d27a}
.out .lv{color:#f2c14e}
.op{color:#6f8ba6;font-size:26px;display:flex;margin-bottom:30px}
.op.to{color:#b89a4a;font-size:32px}

/* few passives leave the content centred instead of a tall empty list */
.main{flex:1;min-height:0;display:flex;flex-direction:column;justify-content:center}
.body{flex:0 1 auto;min-height:0;display:flex;gap:22px;padding:4px 26px 22px;overflow:hidden}
.col{display:flex;flex-direction:column;gap:12px;min-height:0}
.left{flex:2 1 0;min-width:0}
.right{flex:1 1 0;min-width:220px}
.head{display:flex;align-items:center;gap:10px}
.head h2{margin:0;font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:#0e1620;
  background:linear-gradient(90deg,#9fb3c6,#7d92a7);padding:3px 12px;font-weight:700}
.slots{display:flex;gap:4px;align-items:center}
.slots i{width:14px;height:14px;border:1.5px solid #4a6078;display:block}
.slots i.on{background:#5fd0e6;border-color:#5fd0e6}
.list{flex:0 1 auto;min-height:0;overflow-y:auto;display:grid;align-content:start;
  grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:8px;padding-right:6px}
.list::-webkit-scrollbar{width:8px}
.list::-webkit-scrollbar-thumb{background:#2c3a4a;border-radius:4px}
.p{display:grid;grid-template-columns:auto 1fr auto auto;align-items:center;gap:10px;
  padding:10px 12px;border:1px solid #26344a;background:#141d29}
.p:hover{border-color:#6f8ba6;background:#172231}
.p .box{width:16px;height:16px;border:2px solid #6f8ba6;display:flex;align-items:center;justify-content:center;color:#0d131b}
.p .box .ico{width:12px;height:12px;stroke-width:3;opacity:0}
.p .nm{font-size:14.5px;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.p .rank{color:#f2b33d;font-size:12px;letter-spacing:1px}
.p .rank.low{color:#8fa3b8}
.p .src{display:flex;align-items:center;gap:3px}
.p .src img,.p .src .mono{width:20px;height:20px;border-radius:50%;object-fit:cover;box-shadow:0 0 0 1px var(--tint)}
.p .src .mono{display:flex;align-items:center;justify-content:center;font-size:9px;background:#24303f;color:#8fa3b8}
.p.on{border-color:#5fd0e6;background:#122c35}
.p.on .box{background:#5fd0e6;border-color:#5fd0e6}
.p.on .box .ico{opacity:1}
.p.full{opacity:.45}
.none{color:#8fa3b8;padding:14px 0}
.g{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.g a{display:flex;flex-direction:column;align-items:center;gap:8px;padding:16px 10px;
  border:1px solid #26344a;background:#141d29;color:#a9bccf;font-size:14px}
.g a .ico{width:28px;height:28px}
.g a:hover{border-color:#6f8ba6;color:#e6edf6}
.g a.on{border-color:#5fd0e6;background:#122c35;color:#e6edf6}
.g a.on .ico{color:#5fd0e6}
.cost{padding:12px 14px;border:1px solid #6b5a2c;background:#2b2415;color:#f2c14e;font-size:14px}
.foot{display:flex;align-items:center;gap:10px;padding:14px 22px;border-top:1px solid #26344a;background:#111821}
.warn{flex:1;font-size:13.5px;color:#c9b27a}
.btn{padding:10px 26px;border:1px solid #3d5068;color:#a9bccf}
.btn:hover{border-color:#6f8ba6;color:#e6edf6}
.btn.go{display:flex;align-items:center;gap:8px;background:#f2b33d;border-color:#f2b33d;color:#0d131b;font-weight:700}
.btn.go:hover{background:#ffc75a}
]]

-- Lucide icons (ISC license)
local function lucide(body)
    return '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true">' .. body .. '</svg>'
end
local ICON_MARS = lucide('<path d="M16 3h5v5"/><path d="m21 3-6.75 6.75"/><circle cx="10" cy="14" r="6"/>')
local ICON_VENUS = lucide('<path d="M12 15v7"/><path d="M9 19h6"/><circle cx="12" cy="9" r="6"/>')
local ICON_PLUS = lucide('<path d="M5 12h14"/><path d="M12 5v14"/>')
local ICON_ARROW = lucide('<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>')
local ICON_CHECK = lucide('<path d="M20 6 9 17l-5-5"/>')
local ICON_SPARKLES = lucide('<path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966'
    .. 'l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051'
    .. 'a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z"/><path d="M20 2v4"/><path d="M22 4h-4"/><circle cx="4" cy="20" r="2"/>')

local function pickedCount()
    local n = 0
    for _ in pairs(state.picked) do n = n + 1 end
    return n
end

--- Picture, element tint and name of a Pal, drawn the way the Palpedia tree
--- draws them. Falls back to the name's first letters without the tree module.
local lookCache = {}
local function look(id)
    if not id then return nil, "#6f8ba6" end
    if lookCache[id] then return lookCache[id][1], lookCache[id][2] end
    local img, tint = nil, "#6f8ba6"
    local ok, Tree = pcall(require, "treehtml")
    if ok and Tree and Tree.palLook then
        local okLook, i, t = pcall(Tree.palLook, id)
        if okLook then img, tint = i, t or tint
        else Log("[WARN] no portrait for " .. tostring(id) .. ": " .. tostring(i)) end
    else
        Log("[WARN] tree module unavailable for portraits: " .. tostring(Tree))
    end
    lookCache[id] = { img, tint }
    return img, tint
end

local function picture(id, name)
    local img = look(id)
    if img then return string.format('<img src="%s" alt="">', img) end
    return string.format('<span class="mono">%s</span>', esc(tostring(name or id):sub(1, 2)))
end

local function palBlock(cls, id, name, level)
    local _, tint = look(id)
    return string.format('<div class="pal %s" style="--tint:%s"><div class="disc">%s</div>'
        .. '<div class="pname">%s</div><div class="lv">Lv %s</div></div>',
        cls, tint, picture(id, name), esc(name), tostring(level or "?"))
end

local function buildPage()
    local info = state.info
    local picked = pickedCount()
    local _, tintC = look(info.idC)
    local parts = {
        '<!doctype html><html><head><meta charset="utf-8"><style>', CSS, '</style></head>',
        -- the game's browser predates color-mix(): the tint gets its alpha as hex
        string.format('<body style="--tc:%s">', tostring(tintC):match("^#%x%x%x%x%x%x$") and (tintC .. "38") or "#6f8ba638"),
        '<div class="top"><span class="brand">Palvolve</span><span class="title">',
        esc(I18n.msg("fusionAltarEntry")), '</span></div>',
        '<div class="main"><div class="hero">',
        palBlock("in", info.idA, info.nameA, info.levelA),
        '<span class="op">', ICON_PLUS, '</span>',
        palBlock("in", info.idB, info.nameB, info.levelB),
        '<span class="op to">', ICON_ARROW, '</span>',
        palBlock("out", info.idC, info.nameC, info.levelC),
        '</div><div class="body"><div class="col left"><div class="head"><h2>',
        esc(I18n.msg("fusePickPassives", picked, MAX_PICKS)), '</h2><div class="slots">',
    }
    for i = 1, MAX_PICKS do
        parts[#parts + 1] = i <= picked and '<i class="on"></i>' or '<i></i>'
    end
    parts[#parts + 1] = '</div></div>'
    if #info.pool == 0 then
        parts[#parts + 1] = '<div class="none">' .. esc(I18n.msg("fusePickNoPassives")) .. '</div>'
    else
        parts[#parts + 1] = '<div class="list">'
        local full = picked >= MAX_PICKS
        for i, id in ipairs(info.pool) do
            local on = state.picked[i]
            local cls = on and "p on" or (full and "p full" or "p")
            local rank = tonumber(info.ranks and info.ranks[i]) or 0
            local diamonds = rank > 0 and string.format('<span class="rank%s">%s</span>',
                rank < 2 and " low" or "", string.rep("&#9670;", math.min(4, rank))) or '<span></span>'
            local src = info.sources and info.sources[i] or ""
            local owners = {}
            if src:find("a", 1, true) then
                local _, t = look(info.idA)
                owners[#owners + 1] = string.format('<span style="--tint:%s">%s</span>', t, picture(info.idA, info.nameA))
            end
            if src:find("b", 1, true) then
                local _, t = look(info.idB)
                owners[#owners + 1] = string.format('<span style="--tint:%s">%s</span>', t, picture(info.idB, info.nameB))
            end
            parts[#parts + 1] = string.format(
                '<a class="%s" href="#p/%d/%d"><span class="box">%s</span><span class="nm">%s</span>%s'
                .. '<span class="src">%s</span></a>',
                cls, i, ticks, ICON_CHECK, esc(I18n.passiveName(id)), diamonds, table.concat(owners))
        end
        parts[#parts + 1] = '</div>'
    end
    parts[#parts + 1] = '</div><div class="col right"><div class="head"><h2>'
        .. esc(I18n.msg("fusePickGender")) .. '</h2></div><div class="g">'
    parts[#parts + 1] = string.format('<a class="%s" href="#g/1/%d">%s%s</a>',
        state.gender == 1 and "on" or "", ticks, ICON_MARS, esc(I18n.msg("fusePickMale")))
    parts[#parts + 1] = string.format('<a class="%s" href="#g/2/%d">%s%s</a>',
        state.gender == 2 and "on" or "", ticks, ICON_VENUS, esc(I18n.msg("fusePickFemale")))
    parts[#parts + 1] = '</div>'
    if info.cost and info.cost ~= "" then
        parts[#parts + 1] = '<div class="cost">' .. esc(I18n.msg("fusePickCost", info.cost)) .. '</div>'
    end
    parts[#parts + 1] = '</div></div></div><div class="foot">'
    parts[#parts + 1] = '<span class="warn">' .. esc(I18n.msg("fusePickFinal", info.nameC)) .. '</span>'
    parts[#parts + 1] = '<a class="btn" href="#close">' .. esc(I18n.msg("fusePickCancel")) .. '</a>'
    parts[#parts + 1] = '<a class="btn go" href="#ok">' .. ICON_SPARKLES .. esc(I18n.msg("fusePickConfirm"))
        .. '</a></div></body></html>'
    return table.concat(parts)
end

--- The page for a given pick state, for previews outside the game window.
function M.render(info, picked, gender)
    local saved = state
    state = { info = info, picked = picked or {}, gender = gender or 1 }
    local ok, html = pcall(buildPage)
    state = saved
    if not ok then error(html) end
    return html
end

local function loadPage()
    local ok, err = pcall(function() browser:LoadString(page, ORIGIN) end)
    if not ok then Log("[WARN] the pick page did not load: " .. tostring(err)) end
end

local function show()
    page = buildPage()
    loadPage()
end

local function hide(reason)
    local s = state
    state = nil
    if window and window:IsValid() then pcall(function() window:SetVisibility(1) end) end
    local okTree, Tree = pcall(require, "paldextree")
    local pc = Role.getLocalPlayerController()
    if okTree and Tree.releaseInput and pc and pc:IsValid() then Tree.releaseInput(pc) end
    -- Opened over another menu (the altar's own, where the Pals go in): the
    -- game gets its input back, and the mouse stays for that menu. UI-only
    -- input here would leave the player unable to move once the menu closes.
    if s and s.cursorBefore and pc and pc:IsValid() then
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local okMode, modeErr = pcall(function()
            lib:SetInputMode_GameAndUIEx(pc, nil, 0, false, false)
            pc.bShowMouseCursor = true
        end)
        if not okMode then Log("[WARN] mouse not kept for the menu below: " .. tostring(modeErr)) end
    end
    Log("pick window closed: " .. reason .. ((s and s.cursorBefore) and " (mouse kept for the menu below)" or ""))
    return s
end

-- Game menus live in the layer stacks of the overall UI layout, not in the
-- viewport itself, so IsInViewport is false for every one of them.
local function overlayOpen(w) return w:IsActivated() and w:IsVisible() end

-- A menu is built from further overlay widgets (the altar menu holds the party
-- and box lists). Only the outermost one is closed; it takes its parts along.
local overlayClass = nil
local function nestedInOverlay(w)
    if not (overlayClass and overlayClass:IsValid()) then
        overlayClass = StaticFindObject("/Script/Pal.PalUserWidgetOverlayUI")
    end
    local o = w:GetOuter()
    for _ = 1, 12 do
        if not (o and o:IsValid()) then return false end
        if o:IsA(overlayClass) then return true end
        o = o:GetOuter()
    end
    return false
end
local function overlayName(w) return w:GetClass():GetFullName() end
local function overlayClose(w) w:Close() end

--- The game menus open right now, outermost only.
local function openMenus()
    local found = {}
    for _, w in ipairs(FindAllOf("PalUserWidgetOverlayUI") or {}) do
        local okOpen, open = pcall(overlayOpen, w)
        if not okOpen then Log("[WARN] menu state unreadable: " .. tostring(open)) end
        local okNested, nested = false, false
        if okOpen and open then
            okNested, nested = pcall(nestedInOverlay, w)
            if not okNested then Log("[WARN] menu nesting unreadable, counting it as open: " .. tostring(nested)) end
        end
        if okOpen and open and not (okNested and nested) then found[#found + 1] = w end
    end
    return found
end

--- A confirmed fusion plays as a scene, so the game menu the window was opened
--- over (the altar's, where the Pals go in) closes first.
local function closeMenusBelow()
    local closed = 0
    for _, w in ipairs(openMenus()) do
        local okName, name = pcall(overlayName, w)
        local okClose, closeErr = pcall(overlayClose, w)
        if okClose then
            closed = closed + 1
            Log("menu below closed: " .. tostring(okName and name or "?"))
        else
            Log("[WARN] menu below not closed: " .. tostring(closeErr))
        end
    end
    if closed == 0 then Log("no open menu below the pick window") end
    local pc = Role.getLocalPlayerController()
    local okTree, Tree = pcall(require, "paldextree")
    if okTree and Tree.releaseInput and pc and pc:IsValid() then Tree.releaseInput(pc) end
end

-- A click reaches the mod through the address bar, so the window is only as
-- quick to answer as it is polled: 40 ms keeps Cancel and every pick instant.
local TICK_MS = 40
local RETRY_TICKS = 120     -- about 5 s of re-offering the page to a slow browser
local RETRY_EVERY = 24      -- about once a second
local INPUT_EVERY = 24      -- the input grab is refreshed about once a second

local function tickGameThread()
    if not state then return end
    if not (browser and browser:IsValid()) then
        hide("the browser is gone")
        return
    end
    ticks = ticks + 1
    local url = ""
    local okUrl, errUrl = pcall(function() url = tostring(browser:GetUrl():ToString()) end)
    if not okUrl and not urlUnreadable then
        urlUnreadable = true
        Log("[WARN] the pick window url is unreadable: " .. tostring(errUrl))
    end
    if url == lastUrl then url = "" else lastUrl = url end

    if not delivered then
        if url:find("palvolve.local", 1, true) then
            delivered = true
        elseif ticks <= RETRY_TICKS and (ticks <= 2 or ticks % RETRY_EVERY == 0) then
            loadPage()
        elseif ticks == RETRY_TICKS + 1 then
            Log("[WARN] the browser never took the pick page - url [" .. url .. "]")
        end
    end
    if ticks % INPUT_EVERY == 0 then
        local okTree, Tree = pcall(require, "paldextree")
        local pc = Role.getLocalPlayerController()
        if okTree and Tree.grabInput and pc and pc:IsValid() then Tree.grabInput(pc) end
    end
    if url == "" then return end

    if url:find("#close", 1, true) then
        hide("cancelled")
        return
    end
    if url:find("#ok", 1, true) then
        local s = hide("confirmed")
        closeMenusBelow()
        local choice = { passives = {}, passiveIndexes = {}, gender = s.gender }
        for i, id in ipairs(s.info.pool) do
            if s.picked[i] then
                choice.passives[#choice.passives + 1] = id
                choice.passiveIndexes[#choice.passiveIndexes + 1] = i
            end
        end
        local ok, err = pcall(s.onConfirm, choice)
        if not ok then Log("[ERROR] fusion confirm failed: " .. tostring(err)) end
        return
    end
    local n = tonumber(url:match("#p/(%d+)"))
    if n and state.info.pool[n] then
        if state.picked[n] then
            state.picked[n] = nil
        elseif pickedCount() < MAX_PICKS then
            state.picked[n] = true
        end
        show()
        return
    end
    local g = tonumber(url:match("#g/(%d)"))
    if g == 1 or g == 2 then
        state.gender = g
        show()
    end
end

local function tick()
    if not state then
        driving = false
        return true
    end
    tickGameThread()
    return false
end
M._tick = tick -- held by the module so the scheduled callback is never collected

local function ensureWindow()
    if window and window:IsValid() and browser and browser:IsValid() then return true end
    local okTree, Tree = pcall(require, "paldextree")
    if not (okTree and Tree.loadWebClass) then
        Log("[ERROR] the browser page module did not load: " .. tostring(Tree))
        return false
    end
    local cls = Tree.loadWebClass()
    if not cls then return false end
    local pc = Role.getLocalPlayerController()
    if not (pc and pc:IsValid()) then
        Log("[WARN] no player controller, the pick window cannot open")
        return false
    end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local widget = nil
    pcall(function() widget = lib:Create(pc, cls, pc) end)
    if not (widget and widget:IsValid()) then
        Log("[ERROR] the pick window did not build")
        return false
    end
    local b = nil
    pcall(function() b = widget.Browser end)
    if not (b and b:IsValid()) then
        Log("[ERROR] the pick window has no Browser")
        return false
    end
    -- The same frame the tree window uses: a canvas of our own, so the window
    -- can be anchored by fractions and the world stays visible around it.
    local frame, canvas, slot = nil, nil, nil
    pcall(function() frame = lib:Create(pc, StaticFindObject("/Script/UMG.UserWidget"), pc) end)
    if frame and frame:IsValid() then
        pcall(function()
            canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"),
                frame, FName("PalvolveFusePick"))
            frame.WidgetTree.RootWidget = canvas
        end)
    end
    if canvas and canvas:IsValid() then pcall(function() slot = canvas:AddChildToCanvas(widget) end) end
    if slot and slot:IsValid() then
        pcall(function()
            slot:SetAnchors({ Minimum = { X = 0.2, Y = 0.12 }, Maximum = { X = 0.8, Y = 0.86 } })
            slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
            slot:SetAlignment({ X = 0, Y = 0 })
        end)
        pcall(function() frame:SetVisibility(4) end) -- SelfHitTestInvisible
        pcall(function() frame:AddToViewport(71) end)
        window = frame
    else
        pcall(function() widget:AddToViewport(71) end)
        window = widget
        Log("[WARN] no canvas slot, the pick window stays full screen")
    end
    browser = b
    return true
end

--- Opens the pick. info: nameA, nameB, nameC, pool (passive ids), ranks (per
--- pool entry), preset (pool indexes picked at the start), gender (1|2), cost
--- (text). onConfirm(choice) runs with { passives, passiveIndexes, gender }.
function M.open(info, onConfirm)
    if state and driving then
        Log("[WARN] a pick window is already open")
        return false
    end
    if state then hide("stale, nothing drove it") end
    -- read before the window takes the mouse: a menu below (the altar's) gets
    -- the mouse back on cancel and is closed on confirm
    local okMenus, menus = pcall(openMenus)
    if not okMenus then Log("[WARN] open menus unreadable at open: " .. tostring(menus)) end
    local menuBelow = okMenus and #menus > 0
    if not ensureWindow() then return false end
    state = { info = info, picked = {}, gender = (info.gender == 2) and 2 or 1, onConfirm = onConfirm }
    state.cursorBefore = menuBelow
    for _, i in ipairs(info.preset or {}) do
        if info.pool[i] and pickedCount() < MAX_PICKS then state.picked[i] = true end
    end
    ticks, delivered, urlUnreadable = 0, false, false
    local okUrl, errUrl = pcall(function() lastUrl = tostring(browser:GetUrl():ToString()) end)
    if not okUrl then Log("[WARN] the pick window url is unreadable at open: " .. tostring(errUrl)) end
    pcall(function() window:SetVisibility(4) end)
    local okTree, Tree = pcall(require, "paldextree")
    local pc = Role.getLocalPlayerController()
    if okTree and Tree.grabInput and pc and pc:IsValid() then Tree.grabInput(pc) end
    show()
    if not driving then
        driving = true
        GameLoop.start(TICK_MS, M._tick, "fusion window")
    end
    Log(string.format("pick window open: %s + %s = %s, %d passives", info.nameA, info.nameB, info.nameC, #info.pool))
    return true
end

--- Closes the window without a fusion (the player walked off, a world change).
function M.close(reason)
    if state then hide(reason or "closed") end
end

function M.isOpen()
    return state ~= nil
end

return M
