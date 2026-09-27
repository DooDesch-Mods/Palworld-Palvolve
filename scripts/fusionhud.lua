-- fusionhud.lua: how long the battle fusion has left.
--
-- A small panel at the bottom left, above the party panel's summoned Pal: the
-- fused Pal's icon and name, the seconds left and a bar that runs down. Under
-- ten seconds the bar turns amber. It takes no input; clicks go through it.
--
-- The host shows it for its own player and sends the others their state
-- (fusion.lua, netchannel.lua); a dedicated server draws nothing.

local Role = require("role")
local GameLoop = require("gameloop")

local M = {}

local TICK_MS = 250
local WARN_BELOW_S = 10
local REBUILD_EVERY_S = 1.0

-- Layout units are the viewport's DPI-scaled units, anchored bottom left.
local BOX_X, BOX_BOTTOM = 36, 335
local BOX_W, BOX_H = 290, 52
-- the Fusion Shard first, so the panel reads as the fusion's at a glance,
-- then the fused Pal
local SHARD_X, SHARD = 6, 34
local ICON_X, ICON = 44, 40
local BAR_X, BAR_Y, BAR_W, BAR_H = 92, 36, 186, 8
-- the texture PalSchema builds from Palvolve's fusionshard.png
local SHARD_TEXTURE = "/Engine/Transient.PalSchema/Resources/Palvolve/fusionshard"

local PANEL = { R = 0.067, G = 0.094, B = 0.129, A = 0.82 }
local TRACK = { R = 0.18, G = 0.24, B = 0.31, A = 1.0 }
local FILL = { R = 0.37, G = 0.82, B = 0.90, A = 1.0 }
local FILL_WARN = { R = 0.95, G = 0.70, B = 0.24, A = 1.0 }
local WHITE = { R = 0.92, G = 0.94, B = 0.97, A = 1.0 }
local AMBER = { R = 0.95, G = 0.76, B = 0.29, A = 1.0 }

local function Log(msg)
    print(string.format("[Palvolve] [fusionhud] %s\n", tostring(msg)))
end

-- Named functions for the calls made on every tick, so the tick allocates no
-- closure (UE4SS-LESSONS.md, section 1).
local function isValidUnsafe(obj)
    return obj:IsValid()
end

local function isLive(obj)
    if obj == nil then return false end
    local ok, valid = pcall(isValidUnsafe, obj)
    return ok and valid == true
end

local function setFillWidthUnsafe(bar, width, height)
    bar.Slot:SetSize({ X = width, Y = height })
end

local function setColorUnsafe(widget, color)
    widget:SetColorAndOpacity(color)
end

-- A widget call that fails fails again on the next tick; log it once per
-- distinct message.
local lastTickError = nil

local function warnTick(what, err)
    local reason = what .. ": " .. tostring(err)
    if reason == lastTickError then return end
    lastTickError = reason
    Log("[WARN] " .. reason)
end

local current = nil      -- { target, endsAt, duration }
local win, fill, seconds = nil, nil, nil
local shownSeconds, warned = nil, false
local running = false
local nextBuildAt = 0

local function widgets()
    local ok, TreeView = pcall(require, "treeview")
    if ok and TreeView and TreeView.widgets then return TreeView.widgets end
    Log("[ERROR] the widget helpers did not load: " .. tostring(TreeView))
    return nil
end

local function palName(id)
    local ok, evo = pcall(require, "evolution")
    if not (ok and evo and evo.displayName) then
        Log("[WARN] Pal names unavailable, the countdown shows the id: " .. tostring(evo))
        return id
    end
    local okName, name = pcall(evo.displayName, id)
    if not okName then Log("[WARN] name of " .. tostring(id) .. " unreadable: " .. tostring(name)) end
    if okName and name then return name end
    return id
end

local function removeWindow()
    if isLive(win) then
        local ok, err = pcall(function() win:RemoveFromParent() end)
        if not ok then Log("[WARN] countdown not removed: " .. tostring(err)) end
    end
    win, fill, seconds = nil, nil, nil
    shownSeconds, warned = nil, false
end

local function build()
    local W = widgets()
    if not W then return false end
    local pc = Role.getLocalPlayerController()
    if not isLive(pc) then return false end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not isLive(lib) then
        Log("[WARN] WidgetBlueprintLibrary not found, no countdown")
        return false
    end
    local root = nil
    local okRoot, rootErr = pcall(function() root = lib:Create(pc, W.cls("/Script/UMG.UserWidget"), pc) end)
    if not (okRoot and isLive(root)) then
        Log("[WARN] countdown window not created: " .. tostring(rootErr))
        return false
    end
    local canvas = W.construct("/Script/UMG.CanvasPanel", "PvFuseHudRoot")
    local box = W.construct("/Script/UMG.CanvasPanel", "PvFuseHudBox")
    if not (canvas and box) then
        Log("[WARN] countdown canvas not created")
        return false
    end
    local okAttach, attachErr = pcall(function()
        root.WidgetTree.RootWidget = canvas
        local slot = canvas:AddChildToCanvas(box)
        slot:SetAnchors({ Minimum = { X = 0, Y = 1 }, Maximum = { X = 0, Y = 1 } })
        slot:SetAlignment({ X = 0, Y = 1 })
        slot:SetAutoSize(false)
        slot:SetPosition({ X = BOX_X + 0.0, Y = -BOX_BOTTOM + 0.0 })
        slot:SetSize({ X = BOX_W + 0.0, Y = BOX_H + 0.0 })
    end)
    if not okAttach then
        Log("[WARN] countdown layout failed: " .. tostring(attachErr))
        return false
    end
    W.solid(box, 0, 0, BOX_W, BOX_H, PANEL)
    local shardTex = StaticFindObject(SHARD_TEXTURE)
    if isLive(shardTex) then
        local shard = W.construct("/Script/UMG.Image", "PvFuseHudShard")
        if shard then
            local okBrush, brushErr = pcall(function() shard:SetBrushFromTexture(shardTex, false) end)
            if not okBrush then Log("[WARN] Fusion Shard icon not set: " .. tostring(brushErr)) end
            W.place(box, shard, SHARD_X, (BOX_H - SHARD) / 2, SHARD, SHARD)
        end
    else
        Log("[WARN] Fusion Shard texture not found, the countdown shows without it: " .. SHARD_TEXTURE)
    end
    W.palImage(box, current.target, ICON_X, 6, ICON)
    W.label(box, palName(current.target), BAR_X, 6, 140, 15, WHITE)
    seconds = W.label(box, "", BAR_X + 146, 4, 40, 17, WHITE)
    W.solid(box, BAR_X, BAR_Y, BAR_W, BAR_H, TRACK)
    fill = W.solid(box, BAR_X, BAR_Y, BAR_W, BAR_H, FILL)
    -- HitTestInvisible: the panel and everything in it lets clicks through
    local okVis, visErr = pcall(function() root:SetVisibility(3) end)
    if not okVis then Log("[WARN] countdown visibility not set, it may catch clicks: " .. tostring(visErr)) end
    local okShow, showErr = pcall(function() root:AddToViewport(5) end)
    if not okShow then
        Log("[WARN] countdown not added to the screen: " .. tostring(showErr))
        return false
    end
    win = root
    Log(string.format("countdown shown for %s", tostring(current.target)))
    return true
end

local function setSeconds(n, warn)
    if not isLive(seconds) then return end
    local W = widgets()
    if not W then return end
    local ok, err = pcall(function()
        local t = W.toText(tostring(n))
        if t then seconds:SetText(t) end
        seconds:SetColorAndOpacity({ SpecifiedColor = warn and AMBER or WHITE, ColorUseRule = 0 })
    end)
    if not ok then warnTick("countdown seconds not updated", err) end
end

local function tick()
    if not current then
        removeWindow()
        running = false
        return true
    end
    local left = current.endsAt - os.clock()
    if left <= 0 then
        current = nil
        removeWindow()
        running = false
        return true
    end
    if not isLive(win) then
        -- a loading screen or a menu change can take the widget off the screen
        if os.clock() < nextBuildAt then return false end
        nextBuildAt = os.clock() + REBUILD_EVERY_S
        removeWindow()
        if not build() then return false end
    end
    local n = math.ceil(left)
    local warn = left <= WARN_BELOW_S
    if n ~= shownSeconds then
        shownSeconds = n
        setSeconds(n, warn)
    end
    if isLive(fill) then
        local share = math.max(0, math.min(1, left / math.max(1, current.duration)))
        local okSize, sizeErr = pcall(setFillWidthUnsafe, fill, BAR_W * share, BAR_H + 0.0)
        if not okSize then warnTick("countdown bar not resized", sizeErr) end
        if warn ~= warned then
            warned = warn
            local okColor, colorErr = pcall(setColorUnsafe, fill, warn and FILL_WARN or FILL)
            if not okColor then warnTick("countdown bar color not set", colorErr) end
        end
    end
    return false
end
M._tick = tick -- held by the module so the scheduled callback is never collected

--- Shows the countdown for a fusion into target with `remaining` of
--- `duration` seconds left. A second call updates it.
function M.show(target, remaining, duration)
    if Role.isDedicated() then return end
    remaining, duration = tonumber(remaining), tonumber(duration)
    if not (target and remaining and duration) or remaining <= 0 then
        Log(string.format("[WARN] countdown not shown: target=%s remaining=%s duration=%s",
            tostring(target), tostring(remaining), tostring(duration)))
        return
    end
    local sameTarget = current and current.target == target
    current = { target = target, endsAt = os.clock() + remaining, duration = duration }
    if not sameTarget then
        removeWindow()
        nextBuildAt = 0
    end
    if not running then
        running = true
        if not GameLoop.start(TICK_MS, M._tick, "fusion countdown") then running = false end
    end
end

--- Takes the countdown off the screen.
function M.hide()
    if current then Log(string.format("countdown ended for %s", tostring(current.target))) end
    current = nil
    removeWindow()
end

return M
