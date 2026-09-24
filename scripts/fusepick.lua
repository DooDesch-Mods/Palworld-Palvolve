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
local page = ""

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local CSS = [[
*{box-sizing:border-box}
html,body{margin:0;height:100%;overflow:hidden}
body{background:radial-gradient(120% 90% at 50% 0%,#1a2432 0%,#121a24 45%,#0d131b 100%);
  color:#e6edf6;font:16px/1.45 "Segoe UI",system-ui,sans-serif;display:flex;flex-direction:column;
  border:1px solid #3d5068;box-shadow:inset 0 0 0 2px #0c1119}
a{text-decoration:none;color:inherit;transition:background-color 140ms ease-out,border-color 140ms ease-out}
.top{display:flex;align-items:center;gap:16px;padding:14px 22px;border-bottom:1px solid #26344a}
.brand{font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:#f2b33d;font-size:13px}
.spacer{flex:1}
.close{border:1px solid #3d5068;padding:4px 12px;color:#9fb2c8}
.close:hover{border-color:#6f8ba6;color:#e6edf6}
.main{flex:1;overflow:auto;padding:22px 28px;display:flex;flex-direction:column;gap:22px}
h1{margin:0;font-size:26px;font-weight:600;text-wrap:balance}
h1 .to{color:#f2b33d}
.cost{color:#9fb2c8;font-size:14px}
h2{margin:0 0 10px;font-size:12px;letter-spacing:.1em;text-transform:uppercase;color:#0d131b;
  background:#6f8ba6;padding:3px 10px;display:inline-block}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:8px}
.p{display:flex;align-items:center;gap:10px;padding:10px 12px;border:1px solid #26344a;background:#141d29}
.p:hover{border-color:#6f8ba6}
.p .box{width:14px;height:14px;border:2px solid #6f8ba6;flex:none}
.p.on{border-color:#5fd0e6;background:#16303a}
.p.on .box{background:#5fd0e6;border-color:#5fd0e6}
.p.full{opacity:.45}
.p .rank{margin-left:auto;color:#f2b33d;font-size:13px}
.g{display:flex;gap:8px}
.g a{padding:8px 18px;border:1px solid #26344a;background:#141d29}
.g a.on{border-color:#5fd0e6;background:#16303a}
.none{color:#9fb2c8}
.foot{display:flex;justify-content:flex-end;gap:10px;padding:14px 22px;border-top:1px solid #26344a}
.btn{padding:10px 26px;border:1px solid #3d5068;color:#9fb2c8}
.btn:hover{border-color:#6f8ba6;color:#e6edf6}
.btn.go{background:#f2b33d;border-color:#f2b33d;color:#0d131b;font-weight:600}
.btn.go:hover{background:#ffc75a}
]]

local function pickedCount()
    local n = 0
    for _ in pairs(state.picked) do n = n + 1 end
    return n
end

local function buildPage()
    local info = state.info
    local parts = {
        '<!doctype html><html><head><meta charset="utf-8"><style>', CSS, '</style></head><body>',
        '<div class="top"><span class="brand">Palvolve</span><span class="spacer"></span>',
        '<a class="close" href="#close">', esc(I18n.msg("fusePickCancel")), '</a></div>',
        '<div class="main"><div><h1>',
        esc(info.nameA), ' + ', esc(info.nameB), ' = <span class="to">', esc(info.nameC), '</span></h1>',
    }
    if info.cost and info.cost ~= "" then
        parts[#parts + 1] = '<div class="cost">' .. esc(I18n.msg("fusePickCost", info.cost)) .. '</div>'
    end
    parts[#parts + 1] = '</div><section><h2>' .. esc(I18n.msg("fusePickPassives", pickedCount(), MAX_PICKS)) .. '</h2>'
    if #info.pool == 0 then
        parts[#parts + 1] = '<div class="none">' .. esc(I18n.msg("fusePickNoPassives")) .. '</div>'
    else
        parts[#parts + 1] = '<div class="grid">'
        local full = pickedCount() >= MAX_PICKS
        for i, id in ipairs(info.pool) do
            local on = state.picked[i]
            local cls = on and "p on" or (full and "p full" or "p")
            parts[#parts + 1] = string.format('<a class="%s" href="#p/%d/%d"><span class="box"></span>%s%s</a>',
                cls, i, ticks, esc(I18n.passiveName(id)),
                info.ranks[i] and ('<span class="rank">' .. string.rep("&#9670;", math.max(0, math.min(4, info.ranks[i]))) .. '</span>') or "")
        end
        parts[#parts + 1] = '</div>'
    end
    parts[#parts + 1] = '</section><section><h2>' .. esc(I18n.msg("fusePickGender")) .. '</h2><div class="g">'
    parts[#parts + 1] = string.format('<a class="%s" href="#g/1/%d">%s</a>', state.gender == 1 and "on" or "", ticks, esc(I18n.msg("fusePickMale")))
    parts[#parts + 1] = string.format('<a class="%s" href="#g/2/%d">%s</a>', state.gender == 2 and "on" or "", ticks, esc(I18n.msg("fusePickFemale")))
    parts[#parts + 1] = '</div></section></div><div class="foot">'
    parts[#parts + 1] = '<a class="btn" href="#close">' .. esc(I18n.msg("fusePickCancel")) .. '</a>'
    parts[#parts + 1] = '<a class="btn go" href="#ok">' .. esc(I18n.msg("fusePickConfirm")) .. '</a></div></body></html>'
    return table.concat(parts)
end

local function show()
    page = buildPage()
    pcall(function() browser:LoadString(page, ORIGIN) end)
end

local function hide(reason)
    local s = state
    state = nil
    if window and window:IsValid() then pcall(function() window:SetVisibility(1) end) end
    local okTree, Tree = pcall(require, "paldextree")
    local pc = FindFirstOf("PalPlayerController")
    if okTree and Tree.releaseInput and pc and pc:IsValid() then Tree.releaseInput(pc) end
    Log("pick window closed: " .. reason)
    return s
end

local function tickGameThread()
    if not state then return end
    if not (browser and browser:IsValid()) then
        hide("the browser is gone")
        return
    end
    ticks = ticks + 1
    local url = ""
    pcall(function() url = tostring(browser:GetUrl():ToString()) end)
    if url == lastUrl then url = "" else lastUrl = url end

    if not delivered then
        if url:find("palvolve.local", 1, true) then
            delivered = true
        elseif ticks <= 40 and (ticks <= 2 or ticks % 8 == 0) then
            pcall(function() browser:LoadString(page, ORIGIN) end)
        elseif ticks == 41 then
            Log("[WARN] the browser never took the pick page - url [" .. url .. "]")
        end
    end
    if ticks % 8 == 0 then
        local okTree, Tree = pcall(require, "paldextree")
        local pc = FindFirstOf("PalPlayerController")
        if okTree and Tree.grabInput and pc and pc:IsValid() then Tree.grabInput(pc) end
    end
    if url == "" then return end

    if url:find("#close", 1, true) then
        hide("cancelled")
        return
    end
    if url:find("#ok", 1, true) then
        local s = hide("confirmed")
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
    if not state then return true end
    ExecuteInGameThread(tickGameThread)
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
    local pc = FindFirstOf("PalPlayerController")
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
            slot:SetAnchors({ Minimum = { X = 0.24, Y = 0.16 }, Maximum = { X = 0.76, Y = 0.8 } })
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
    if state then
        Log("[WARN] a pick window is already open")
        return false
    end
    if not ensureWindow() then return false end
    state = { info = info, picked = {}, gender = (info.gender == 2) and 2 or 1, onConfirm = onConfirm }
    for _, i in ipairs(info.preset or {}) do
        if info.pool[i] and pickedCount() < MAX_PICKS then state.picked[i] = true end
    end
    ticks, delivered = 0, false
    pcall(function() lastUrl = tostring(browser:GetUrl():ToString()) end)
    pcall(function() window:SetVisibility(4) end)
    local okTree, Tree = pcall(require, "paldextree")
    local pc = FindFirstOf("PalPlayerController")
    if okTree and Tree.grabInput and pc and pc:IsValid() then Tree.grabInput(pc) end
    show()
    LoopAsync(120, M._tick)
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
