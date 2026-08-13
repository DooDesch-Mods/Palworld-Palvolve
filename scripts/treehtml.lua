-- The tree view as a web page.
--
-- The window is a browser widget from the pak, and this builds what it shows.
-- Drawing it as HTML is what makes it look like the website instead of like a
-- pile of engine widgets: the same layout, the same icons, real type, hover.
--
-- The one rule to remember: JavaScript is dead in this widget, measured in both
-- origins. Nothing here may depend on script. A click is a link, the page is
-- rebuilt for every click, and the reader never notices because a click
-- re-centres the tree anyway. It is also why there is no search box: a box that
-- cannot filter is a lie.
--
-- Links are fragments (#pick/<id>). A made-up scheme or an address the host
-- does not serve leaves Chromium's error page behind; a fragment leaves the
-- page standing while still changing the address the mod reads.

local Config = require("config")
local Elements = require("elements_static")
local Conditions = require("conditions")
local I18n = require("i18n")

--- Every line the window shows goes through the catalog, so the page speaks the
--- language the rest of the mod does. A missing key falls back to English on
--- its own, and to the key itself if even that is gone.
local function t(key, ...)
    return I18n.msg(key, ...)
end

local okPaldex, Paldex = pcall(require, "paldex_static")
if not okPaldex then Paldex = {} end

local M = {}

local view = nil
local function model()
    if view == nil then
        local ok, m = pcall(require, "treeview")
        view = (ok and m) or false
    end
    return view or nil
end

-- ------------------------------------------------------------------ icons

-- The same pictures the website uses. They are read off disk once and kept as
-- text, because every redraw pastes them into the page again: re-reading and
-- re-encoding 30 files per click would be the only slow part of this window.
local iconCache = {}
local iconRoot = nil

-- Relative to the process working directory, which is the Win64 folder. These
-- only ever covered the manual install: the game's own loader puts the mod four
-- levels deeper, under Mods\NativeMods\UE4SS\Mods\, and every player who
-- installed from the Workshop got a tree with no portraits in it at all.
local ICON_ROOTS = {
    "Mods/Palvolve/scripts/icons/",
    "ue4ss/Mods/Palvolve/scripts/icons/",
    "Mods/NativeMods/UE4SS/Mods/Palvolve/Scripts/icons/",
    "Pal/Binaries/Win64/ue4ss/Mods/Palvolve/scripts/icons/",
    "Pal/Binaries/Win64/Mods/NativeMods/UE4SS/Mods/Palvolve/Scripts/icons/",
}

--- Where this very file was loaded from, which is the only answer that holds
--- for every install layout there is or will be. The list above stays as the
--- fallback for the case where the loader hands out no usable path.
local function scriptIconRoot()
    local path = nil
    pcall(function() path = package.searchpath("treehtml", package.path) end)
    if not path then
        pcall(function()
            local src = debug.getinfo(1, "S").source or ""
            path = src:match("^@(.+)$")
        end)
    end
    if not path then return nil end
    local dir = path:match("^(.*[/\\])[^/\\]*$")
    if not dir then return nil end
    return dir .. "icons/"
end

local function findIconRoot()
    if iconRoot ~= nil then return iconRoot or nil end
    local own = scriptIconRoot()
    local roots = {}
    if own then roots[#roots + 1] = own end
    for _, r in ipairs(ICON_ROOTS) do roots[#roots + 1] = r end
    for _, root in ipairs(roots) do
        local f = io.open(root .. "SheepBall.webp", "rb")
        if f then
            f:close()
            iconRoot = root
            print(string.format("[Palvolve] tree icons found under %s\n", root))
            return root
        end
    end
    iconRoot = false
    print("[Palvolve] no tree icons found, the page stays text only\n")
    return nil
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Base64 without a bit library, which is not guaranteed on this build.
--
-- Speed matters more here than anywhere else in the file: a portrait is 5 KB,
-- 287 of them ship with the mod, and the first page a player opens used to take
-- seconds because every byte went through four string.sub calls that each
-- allocate a one-character string. The tables below turn the inner loop into
-- lookups: CHAR maps a 6-bit value to its character, and PAIR maps a whole
-- 12-bit value to the two characters it produces, so three input bytes cost two
-- table reads instead of four calls plus three concatenations.
local CHAR = {}
for i = 1, 64 do CHAR[i - 1] = B64:sub(i, i) end
local PAIR = {}
for hi = 0, 63 do
    local c = CHAR[hi]
    local base = hi * 64
    for lo = 0, 63 do PAIR[base + lo] = c .. CHAR[lo] end
end

local function base64(data)
    local out = {}
    local n = #data
    local i = 1
    local k = 0
    -- Chunked so the out table stays small: table.concat over a few hundred
    -- entries beats one over tens of thousands.
    while i + 2 <= n do
        local a, b, c = data:byte(i, i + 2)
        k = k + 1
        out[k] = PAIR[a * 16 + math.floor(b / 16)] .. PAIR[(b % 16) * 256 + c]
        i = i + 3
    end
    local left = n - i + 1
    if left == 1 then
        local a = data:byte(i)
        out[k + 1] = PAIR[a * 16] .. "=="
    elseif left == 2 then
        local a, b = data:byte(i, i + 1)
        out[k + 1] = PAIR[a * 16 + math.floor(b / 16)] .. CHAR[(b % 16) * 4] .. "="
    end
    return table.concat(out)
end

local function icon(palId)
    if iconCache[palId] ~= nil then return iconCache[palId] or nil end
    local root = findIconRoot()
    if not root then
        iconCache[palId] = false
        return nil
    end
    local f = io.open(root .. palId .. ".webp", "rb")
    if not f then
        -- An adaptation is a recolour of its base form, and for a few of them
        -- no art exists anywhere. The base portrait is the wrong colour but it
        -- is the right Pal, which beats the empty box players were reporting.
        local base = tostring(palId):match("^(.+)_[^_]+$")
        if base then f = io.open(root .. base .. ".webp", "rb") end
    end
    if not f then
        iconCache[palId] = false
        return nil
    end
    local data = f:read("*a")
    f:close()
    iconCache[palId] = "data:image/webp;base64," .. base64(data)
    return iconCache[palId]
end

-- ------------------------------------------------------------------ pieces

local ELEMENT_HEX = {
    Normal = "#c9d3de", Fire = "#ff7a45", Water = "#4aa8ff", Electricity = "#ffd23f",
    Leaf = "#5fd35f", Dark = "#a97bd6", Dragon = "#7f6bff", Ice = "#7fe3e0",
    Earth = "#c8a165",
}

local function elementOf(palId)
    local els = Elements[palId]
    return els and els[1] or "Normal"
end

local function tintOf(palId)
    return ELEMENT_HEX[elementOf(palId)] or ELEMENT_HEX.Normal
end

--- Text that lands in the page has to survive being HTML. Pal names come from
--- the game's own tables and a config can carry anything at all, so nothing is
--- pasted in raw.
local function esc(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    s = s:gsub('"', "&quot;"):gsub("'", "&#39;")
    return s
end

local function nameOf(id)
    local m = model()
    if m and m.palName then
        local ok, n = pcall(m.palName, id)
        if ok and n then return n end
    end
    return id
end

--- A round portrait in the element's colour, the shape the mock uses. The ring
--- is a shadow rather than a border so the picture keeps its full size.
local function portrait(id, sizeVar, extra, badge, asLink)
    local img = icon(id)
    local pic = img
        and string.format('<img src="%s" alt="">', img)
        or string.format('<span class="mono">%s</span>', esc(nameOf(id):sub(1, 2)))
    local badgeHtml = (badge and badge > 0)
        and string.format('<span class="badge">%d</span>', badge) or ""
    -- The picture is cropped by an inner mask, not by the disc itself: the badge
    -- sits in the disc too, and clipping there would cut the number in half.
    -- Inside a card the portrait is not its own link: the card is. Two nested
    -- links are not valid HTML, and a picture that reacts while the frame
    -- around it does not is exactly the confusion this avoids.
    if asLink == false then
        return string.format(
            '<span class="pal %s" style="--tint:%s;--size:%s">'
            .. '<span class="disc"><span class="cut">%s</span>%s</span>'
            .. '<span class="pname">%s</span></span>',
            extra or "", tintOf(id), sizeVar, pic, badgeHtml, esc(nameOf(id)))
    end
    return string.format(
        '<a class="pal %s" href="#pick/%s" style="--tint:%s;--size:%s">'
        .. '<span class="disc"><span class="cut">%s</span>%s</span>'
        .. '<span class="pname">%s</span></a>',
        extra or "", esc(id), tintOf(id), sizeVar, pic, badgeHtml, esc(nameOf(id)))
end

local function ruleText(step)
    local bits = {}
    if step.minLevel and step.minLevel > 0 then
        bits[#bits + 1] = t("treeLevel", step.minLevel)
    end
    bits[#bits + 1] = (step.stone == "adaptation")
        and t("treeAdaptationStone") or t("treeEvolutionStone")
    return table.concat(bits, " &middot; ")
end

--- One chip per condition, in the reader's language. The guide pages and the
--- wheel already say "at night" rather than "!day", and a window with a second
--- vocabulary would be one to learn twice.
---
--- Conditions can be folded away, and "auto" means: shown where there is room,
--- folded where the block is crowded. Twenty-two cards with six chips each is a
--- wall of text when all the reader wants is "who does this become" - and the
--- unequal card heights are what tore the grid apart in the first place. The
--- switch lives in the header and, like everything else here, is a link that
--- makes the mod draw the page again; it overrides the guess either way.
local conditionMode = "auto"
local showConditions = true

--- Reads the fold switch out of the address. Returns true when the page has to
--- be drawn again.
function M.toggleFrom(url)
    if type(url) ~= "string" then return false end
    if url:find("#conditions/off", 1, true) and conditionMode ~= "off" then
        conditionMode = "off"
        return true
    end
    if url:find("#conditions/on", 1, true) and conditionMode ~= "on" then
        conditionMode = "on"
        return true
    end
    return false
end

local function conditionChips(step)
    if not showConditions then return "" end
    if not (step.conditions and #step.conditions > 0) then return "" end
    local chips = {}
    for _, id in ipairs(step.conditions) do
        local ok, label = pcall(Conditions.label, id)
        chips[#chips + 1] = string.format('<span class="chip">%s</span>',
            esc((ok and label) or id))
    end
    return string.format('<div class="chips">%s</div>', table.concat(chips))
end

--- The connector: a line with the rules under it. Under, not over - conditions
--- stack, and above the line they would push the whole row apart. Two ways to
--- the same Pal are separated by "or", because that is what they are.
--- Two steps that differ only in the level they need are one step to the
--- reader: if Lv 1 already works, the Lv 2 line is noise. It also read as a
--- second condition, which it never was.
local function usefulSteps(entry)
    local best, order = {}, {}
    for _, step in ipairs(entry.steps) do
        local conds = {}
        for _, c in ipairs(step.conditions or {}) do conds[#conds + 1] = tostring(c) end
        table.sort(conds)
        local key = (step.stone or "evolution") .. "|" .. table.concat(conds, ",")
        local lv = step.minLevel or 0
        if best[key] == nil then
            best[key] = step
            order[#order + 1] = key
        elseif lv < (best[key].minLevel or 0) then
            best[key] = step
        end
    end
    local out = {}
    for _, key in ipairs(order) do out[#out + 1] = best[key] end
    return out
end

local function connector(entry)
    local rules, seen = {}, {}
    for _, step in ipairs(usefulSteps(entry)) do
        local hidden = ""
        if not showConditions and step.conditions and #step.conditions > 0 then
            hidden = string.format('<span class="folded">%s</span>',
                t(#step.conditions == 1 and "treeConditionOne" or "treeConditionMany",
                  #step.conditions))
        end
        local block = string.format('<div class="rule">%s%s%s</div>',
            string.format('<span class="req">%s</span>', ruleText(step)),
            hidden, conditionChips(step))
        -- Two rules that read the same are one rule to the reader; a config can
        -- carry both, and printing it twice only looks like a bug.
        if not seen[block] then
            seen[block] = true
            rules[#rules + 1] = block
        end
    end
    return string.format('<div class="link"><div class="line"></div>%s</div>',
        table.concat(rules, '<div class="orword">or</div>'))
end

local CSS = [[
*{box-sizing:border-box}
/* Nothing here jumps. Every state change that a player can cause - hover, the
   fold switch, a new selection - eases instead of snapping, which is the whole
   difference between "a page" and "a screen in a game". */
a,.item,.row,.pal,.disc,.switch,.keys,.chip{transition:background-color 140ms ease-out,
     border-color 140ms ease-out,color 140ms ease-out,box-shadow 180ms ease-out,
     transform 140ms ease-out}
html,body{margin:0;height:100%;overflow:hidden}

/* The design was drawn at 1280 wide; the game hands the page a window half as
   wide again, and in fixed pixels everything then keeps its size and the page
   thins out - same drawing, lost in the space. So the sizes that carry the
   composition live here and grow with the window. */
:root{--pal:80px;--hub:130px;--list:296px;--arm:160px;--base:15px;--small:12.5px}
.dense{--pal:50px;--arm:120px}
@media (min-width:1500px){
  :root{--pal:96px;--hub:158px;--list:330px;--arm:176px;--base:16px;--small:13px}
  .dense{--pal:58px;--arm:136px}
}
@media (min-width:1800px){
  :root{--pal:112px;--hub:184px;--list:360px;--arm:196px;--base:17.5px;--small:14px}
  .dense{--pal:66px;--arm:150px}
}
/* The game's panels are not flat: a cool dark blue that lifts towards the
   middle, an amber accent, and a thin light edge on top. The page copies that
   so the window sits next to the wheel and the guide pages instead of looking
   like a browser someone left open. */
/* Measured off the game's own Palpedia (ref/palpedia-1.0.png): near-black
   panels, cyan for the selected row, amber for values, square corners with
   little angle marks, and section headers as filled bars. The one thing that
   cannot be copied is the translucency - CEF paints opaque, so the world can
   only show around the window, never through it. */
body{background:
       radial-gradient(120% 90% at 50% 0%, #1a2432 0%, #121a24 45%, #0d131b 100%);
     color:#e6edf6;font:var(--base)/1.45 "Segoe UI",system-ui,sans-serif;
     display:flex;flex-direction:column;
     border:1px solid #3d5068;box-shadow:inset 0 0 0 2px #0c1119;position:relative}
/* the angle marks the game draws in every panel corner */
body::before,body::after{content:"";position:absolute;width:18px;height:18px;
     border:2px solid #6f8ba6;pointer-events:none}
body::before{top:5px;left:5px;border-right:0;border-bottom:0}
body::after{bottom:5px;right:5px;border-left:0;border-top:0}
a{text-decoration:none;color:inherit}

/* The game's own panels are dark blue-grey with a thin lighter edge and amber
   for anything that wants attention. The page borrows that rather than
   inventing a third look next to the wheel and the guide pages. */
.top{height:54px;flex:0 0 54px;display:flex;align-items:center;gap:14px;padding:0 20px;
     background:linear-gradient(#1e2939,#161e2a);border-bottom:1px solid #2c3a4b;
     box-shadow:inset 0 1px 0 #33455a, 0 2px 12px -6px #000}
.spacer{margin-left:auto}
.top .brand{font-weight:650;font-size:calc(var(--base) + 2px);letter-spacing:.01em}
.top .meta{color:#8296ab;font-size:calc(var(--base) - 1.5px)}
.top .keys{margin-left:10px;display:flex;align-items:center;gap:8px;
            font-size:var(--small);color:#a9bccf;padding:4px 8px}
.top .keys:hover{color:#fff;background:#22303f}
.top .keys:hover .key{background:#fff}
.key{display:inline-block;min-width:22px;text-align:center;padding:2px 7px;
     background:#e8eef5;color:#131c26;font-weight:700;font-size:calc(var(--small) - 0.5px)}
/* A key badge means "press this key". The fold switch is clicked, not pressed,
   so it looks like what it is. */
.switch{margin-left:auto;font-size:var(--small);color:#a9bccf;padding:5px 11px;
     background:#192431;border:1px solid #35485b}
.switch:hover{color:#fff;background:#22303f;border-color:#60778e}

.body{flex:1;display:flex;min-height:0}

.side{width:var(--list);flex:0 0 var(--list);background:#131a24;border-right:1px solid #24303e;
      height:100%;overflow-y:auto;padding:8px 12px 20px}
/* Every scrolling box gets the same bar, the crowded card grid included - it
   was the one that kept the browser's own. */
.stage::-webkit-scrollbar,.col.dense::-webkit-scrollbar{width:8px}
.stage::-webkit-scrollbar-track,.col.dense::-webkit-scrollbar-track{background:transparent}
.stage::-webkit-scrollbar-thumb,.col.dense::-webkit-scrollbar-thumb{
     background:#2c3a4a;border-radius:4px;border:2px solid transparent;
     background-clip:content-box}
.stage::-webkit-scrollbar-thumb:hover,.col.dense::-webkit-scrollbar-thumb:hover{
     background:#3f5470;background-clip:content-box}
.col.dense::-webkit-scrollbar-button{display:none}
.side::-webkit-scrollbar{width:9px}
.side::-webkit-scrollbar-track{background:#111821}
.side::-webkit-scrollbar-thumb{background:#2a3745;border-radius:5px}
.side::-webkit-scrollbar-thumb:hover{background:#3a4c62}
.side h2{font-size:var(--small);letter-spacing:.14em;text-transform:uppercase;color:#0e1620;
         margin:6px 0 8px;padding:4px 10px;font-weight:700;
         background:linear-gradient(90deg,#9fb3c6,#7d92a7)}
.item{display:flex;align-items:center;gap:11px;padding:7px 12px;margin:1px 0;
      scroll-margin-block:96px;
      border:1px solid transparent;border-left:3px solid transparent}
.item img{width:calc(var(--pal) * 0.34);height:calc(var(--pal) * 0.34);object-fit:contain}
.item .nm{font-size:calc(var(--base) - 0.5px)}
.item .num{margin-left:auto;font-size:var(--small);color:#6f8296;font-variant-numeric:tabular-nums}
.item .dot{width:7px;height:7px;border-radius:50%;background:var(--tint);flex:0 0 7px}
.item:hover{background:#18222e;border-color:#26333f}
.item.on{background:linear-gradient(90deg,#1478b4,#12699e);border-color:#3ea6e0;
         border-left-color:#7fd4ff}
.item.on .nm{color:#fff;font-weight:600}
.item.on .num{color:#d6ecff}

/* Centred as one row, with a floor under each side. Forcing the two sides to
   equal width does put the selected Pal in the exact middle, but a Pal with
   twenty ways out then runs off the right edge - so the sides keep their own
   width and only a minimum stops a lone neighbour from leaving half the screen
   blank. */
@keyframes settle{from{opacity:0;transform:translateY(7px)}to{opacity:1;transform:none}}
@keyframes bloom{from{opacity:0;transform:scale(.94)}to{opacity:1;transform:none}}
.wing,.hub{animation:settle 200ms ease-out backwards}
.hub{animation:bloom 260ms ease-out backwards}
.col.dense .row{animation:settle 220ms ease-out backwards;
     animation-delay:calc(var(--i, 0) * 16ms)}
.stage{flex:1;display:flex;align-items:stretch;justify-content:center;gap:22px;
       padding:14px 26px 10px;overflow-x:hidden;overflow-y:auto;min-height:0}
/* Each side takes its half of the stage, so the header sits in the middle of
   the lane the reader sees. Sized to its content instead, the box was narrower
   than the lane and the label drifted towards the centre with it. */
.wing{display:flex;flex-direction:column;align-items:center;flex:1 1 auto;
      min-width:calc(var(--pal) * 2.6);min-height:0}
/* A crowded side gets the room, a quiet one only what it needs. Split evenly,
   twenty-two cards were squeezed into two columns while a single incoming Pal
   sat in half the window. */
.wing.dense{flex:5 1 0;min-width:0}
/* ... but never below what one card and its arm need, or the quiet side is
   squeezed until its portrait hangs over the edge of the window. */
.wing:not(.dense){flex:1 1 0;min-width:calc(var(--pal) + var(--arm) + 28px)}
.wing-head{font-size:var(--small);letter-spacing:.14em;text-transform:uppercase;color:#0e1620;
           margin-bottom:12px;white-space:nowrap;padding:3px 16px;font-weight:700;
           background:linear-gradient(90deg,#9fb3c6,#7d92a7)}
/* A lane for the selected Pal, so the eye reads three zones and not one field -
   and a head on each dividing line, pointing the way the whole screen runs:
   into the middle from the left, out of it to the right. In the crowded case
   these are the only arrows left, and they are the two that cannot mislead. */
.hub{display:flex;flex-direction:column;align-items:center;justify-content:center;
     flex:0 0 auto;padding:0 26px 18px;position:relative;
     background:radial-gradient(60% 50% at 50% 45%, rgba(120,160,210,.10), transparent 70%);
     border-left:1px solid #24313f;border-right:1px solid #24313f}
.hub::before,.hub::after{content:"";position:absolute;top:50%;margin-top:-10px;
     border:10px solid transparent;border-right:0;pointer-events:none}
.hub::before{left:0;border-left-color:#8296ab}
.hub::after{right:-10px;border-left-color:#b89a4a}
.hub .sel{font-size:var(--small);letter-spacing:.16em;text-transform:uppercase;color:#7e91a6;
          margin-bottom:10px}

/* One grid per side with a fixed number of rows: it grows sideways on its own
   when a Pal has twenty ways out. A wrapping flexbox was tried first and keeps
   the width of a single column, so the extra ones spill over the centre. */
.col{display:grid;grid-auto-flow:column;gap:14px 10px;align-content:center;
     justify-items:start;align-items:start;flex:1;min-height:0}
/* Crowded, the neighbours are cut into independent stacks instead of sharing
   grid rows. A grid row is as tall as its tallest cell across every column, so
   one card with six chips left holes under all its neighbours; a stack only
   ever pushes its own column. */
/* One row band per row, and every card stretches to fill it. The tall card in
   a row sets the height and its neighbours match, which is what the eye wants
   - the earlier version left that difference as bare space next to a short
   card, and bare space reads as "something is missing here". */
/* The number of columns is the browser's to decide, not the mod's. Counted in
   Lua from the number of cards it was a guess at the width, and a guess that
   was wrong pushed the last column past the right edge - which is exactly what
   twenty-two ways out did. auto-fill takes as many columns as fit and the rest
   wrap under them. */
.col.dense{display:grid;grid-auto-flow:row;
     grid-template-columns:repeat(auto-fill,minmax(132px,1fr));
     gap:10px;align-items:stretch;align-content:start;
     flex:1 1 auto;width:100%;min-height:0;
     overflow-y:auto;overflow-x:hidden;padding-right:14px}
.col.dense .row{height:100%}
.empty{display:flex;align-items:center;color:#63748a;font-size:12px;font-style:italic;
       max-width:150px;text-align:center;flex:1}
.row{display:flex;align-items:center}

.pal{display:flex;flex-direction:column;align-items:center;gap:7px;
     width:calc(var(--size) + 30px)}
.disc{position:relative;width:var(--size);height:var(--size);border-radius:50%;
      display:flex;align-items:center;justify-content:center;
      background:radial-gradient(circle at 50% 38%, #24303f 0%, #151d28 100%);
      box-shadow:0 0 0 2px var(--tint),0 0 20px -6px var(--tint)}
/* The mask is what makes it a portrait: the art is bigger than the circle and
   has to be cut by it, otherwise the Pal hangs over the ring. It sits inside
   the disc rather than on it because the badge lives in the disc too and would
   be cut in half. */
.cut{position:absolute;inset:0;border-radius:50%;overflow:hidden;
     display:flex;align-items:center;justify-content:center}
.cut img{width:100%;height:100%;object-fit:cover}
.pal .mono{color:#8296ab;font-size:13px}
.pal .pname{font-size:calc(var(--base) - 2px);color:#dce5f0;text-align:center;line-height:1.25}
.pal:hover .disc,.row:hover .disc{box-shadow:0 0 0 2px var(--tint),0 0 26px -2px var(--tint)}
.col.dense .row:hover .pname{color:#fff}
.pal.center .disc{box-shadow:0 0 0 3px var(--tint),0 0 46px -6px var(--tint),
                  0 0 90px -20px var(--tint)}
.pal.center .pname{font-size:calc(var(--base) + 2px);font-weight:600;margin-top:2px}

.badge{position:absolute;top:-2px;right:-4px;min-width:22px;height:22px;border-radius:2px;
       background:#f2c14e;color:#141a22;font-size:11.5px;font-weight:700;
       display:flex;align-items:center;justify-content:center;padding:0 6px;
       border:2px solid #0f151d}

.link{width:var(--arm);display:flex;flex-direction:column;align-items:center;gap:2px;padding:0 8px}
/* Both sides read left to right, so the head sits on the right end either way:
   on an incoming step it points at the selected Pal, on an outgoing one at
   where that Pal goes. */
/* The two sides are not the same thing, and the drawing said so: what leads
   here is cool and quiet, what leads onward is the warm accent the game uses
   for anything you can still do. Painting both amber lost that. */
.link .line{width:100%;height:1.5px;position:relative;border:0}
.link .line::after{content:"";position:absolute;top:-3.5px;right:-1px;
       border:4.5px solid transparent;border-right:0}
.col.in .link .line{background:linear-gradient(90deg,
      rgba(90,109,130,0) 0%, #5a6d82 38%, #8296ab 100%)}
.col.in .link .line::after{border-left-color:#8296ab}
.col.out .link .line{background:linear-gradient(90deg,
      rgba(138,116,52,0) 0%, #8a7434 38%, #b89a4a 100%)}
.col.out .link .line::after{border-left-color:#b89a4a}
.rule{text-align:center;margin-top:4px}
.rule .req{display:block;font-size:var(--small);color:#b6c6d6}
.chips{display:flex;flex-wrap:wrap;gap:4px;justify-content:center;margin-top:4px}
.chip{font-size:var(--small);background:#26313f;border:1px solid #46596f;
      color:#cfe0f0;padding:1px 8px}
.orword{font-size:calc(var(--small) - 1.5px);color:#63748a;margin:5px 0 1px}
.folded{display:inline-block;margin-top:4px;font-size:var(--small);
     color:#e0c274;background:#2b2415;border:1px solid #6b5a2c;padding:1px 7px}

/* The game puts the screen's name in the bottom-left corner, where nothing else
   lives. Here the list lives there, so it moves to the first free spot: just
   right of the list, at the foot of the graph. */
/* Clear of the Pal list. Docked into the Paldex there is no list of ours, so
   the offset goes with it. */
.watermark{position:absolute;left:calc(var(--list) + 26px);bottom:52px;
           font-size:calc(var(--base) * 2.8);letter-spacing:.22em;color:#ffffff;
           opacity:.06;font-weight:300;pointer-events:none;text-transform:uppercase}
body.docked .watermark{left:26px}
.foot{height:42px;flex:0 0 42px;display:flex;align-items:center;gap:16px;padding:0 20px;
      background:#131a24;border-top:1px solid #24303e;font-size:calc(var(--base) - 2px);color:#8296ab}
.foot .hint{margin-left:auto;color:#7e91a6}
.foot b{color:#cfe0f0;font-weight:600}

/* Crowded, the arrows lie. Three wrapped columns put an unrelated Pal to the
   right of every card, and a horizontal arrow between them reads as a chain -
   "Lamball becomes Kingpaca becomes Eikthyrdeer", when all three are separate
   evolutions of the selected Pal. So above the threshold each card carries its
   own rule underneath and no arrow points at a neighbour. */
/* A caption without a box belongs to nobody. Two defects came out of that:
   an empty band under a short card read as "something is missing here", and a
   two-line rule under one card drifted close enough to the next card to look
   like its rule. A visible container ends both - everything inside the frame
   belongs to the Pal in it, and the gap between frames is obviously a gap. */
.col.dense .row{flex-direction:column;gap:1px;justify-content:flex-start;
     width:100%;padding:7px 6px 7px;
     background-color:#161f2b;border:1px solid #2b3a4a;
     box-shadow:inset 0 1px 0 rgba(255,255,255,.04)}
.col.dense .row:hover{border-color:#4a6180;background-color:#1e2937;
     transform:translateY(-2px)}
.col.dense .link{width:100%;max-width:none;padding:0}
.col.dense .link .line{display:none}
.col.dense .rule{margin-top:4px;padding-top:4px;border-top:1px solid #2b3a4a;
     width:100%;min-height:36px}


.col.dense .rule .req{font-size:calc(var(--small) - 1px)}
.col.dense .chip{font-size:calc(var(--small) - 2px);padding:0 6px}
.col.dense .pal .pname{font-size:calc(var(--base) - 2px);line-height:1.2}
]]

-- ----------------------------------------------------------------- the page

--- The whole window for one selected Pal. Rebuilt from scratch on every click:
--- there is no script to patch a page in place, and at this size the rebuild is
--- a few milliseconds plus the icons, which are already cached as text.
-- Docked, the page is a panel inside the Paldex rather than a window over it,
-- so picking a Pal is that screen's own job on the left and the list goes. The
-- close control stays either way: switching tabs closes the tree as well, but
-- a way out that is visible beats one the reader has to know about.
local docked = false

-- Reading a line means clicking back and forth between the same handful of
-- Pals, and a finished page does not change while the world runs: same tree,
-- same language, same layout. Keeping the last few turns every step back into
-- a paste instead of a rebuild, which is where most of the wait went. A page
-- carries its portraits as text, so the number is kept small on purpose.
-- A docked page is small, but the free-standing window carries the whole side
-- list, which is every portrait in the tree as text. Counting entries alone
-- would let sixteen of those add up to tens of megabytes, so the bytes are
-- capped as well and the oldest entries go first.
local PAGE_CACHE_MAX = 16
local PAGE_CACHE_BYTES = 8 * 1024 * 1024
local pageCache = {}
local pageOrder = {}
local pageBytes = 0

local function dropPages()
    pageCache = {}
    pageOrder = {}
    pageBytes = 0
end

-- Lower-case id -> the spelling this world's tree uses. The Paldex row hands
-- out "SheepBall" while the config says "Sheepball", and a key that is off by
-- one capital finds nothing: the Pal then shows as a dead end with every one of
-- its twenty-two ways out missing. Built once per list rather than scanned
-- twice per click, which on a 279 Pal tree is two full passes before the page
-- cache is even consulted.
local canonList = nil
local canonMap = nil

local function canonicalOf(pals)
    if canonMap and canonList == pals then return canonMap end
    local map = {}
    for _, id in ipairs(pals) do map[id:lower()] = id end
    canonList, canonMap = pals, map
    return map
end

local function rememberPage(key, html)
    if pageCache[key] == nil then
        pageOrder[#pageOrder + 1] = key
    else
        pageBytes = pageBytes - #pageCache[key]
    end
    pageCache[key] = html
    pageBytes = pageBytes + #html
    while #pageOrder > PAGE_CACHE_MAX
        or (pageBytes > PAGE_CACHE_BYTES and #pageOrder > 1) do
        local oldest = table.remove(pageOrder, 1)
        local gone = pageCache[oldest]
        if gone then pageBytes = pageBytes - #gone end
        pageCache[oldest] = nil
    end
end

--- Everything derived from the tree goes when the tree does: the finished
--- pages and the spelling map both describe a map that no longer applies.
function M.invalidate()
    dropPages()
    canonList, canonMap = nil, nil
end

function M.setDocked(on)
    local want = on == true
    -- the two layouts differ, so the cached pages of the other one are wrong
    if want ~= docked then dropPages() end
    docked = want
end

function M.page(centerId)
    local m = model()
    if not m then return "<html><body>tree model unavailable</body></html>" end

    local pals = m.listedPals()

    -- The same Pal, spelled the way this world's tree spells it. The Paldex row
    -- hands out "SheepBall", the config says "Sheepball", and a key that is only
    -- off by a capital letter finds nothing - the Pal then shows as a dead end
    -- with every one of its twenty-two ways out missing.
    if centerId then
        local canon = canonicalOf(pals)[tostring(centerId):lower()]
        if canon then centerId = canon end
    end

    if #pals == 0 then
        return '<!doctype html><html><head><meta charset="utf-8"><style>' .. CSS
            .. '</style></head><body><div class="top"><span class="brand">Palvolve</span>'
            .. '</div><div class="body"><div class="stage">'
            .. t("treeEmpty") .. "</div></div></body></html>"
    end
    if not centerId then centerId = pals[1] end

    -- After the spelling is settled, so both spellings of a Pal share one entry.
    -- The fold switch and the language are part of the key because both change
    -- every rule on the page: keyed by the Pal alone, clicking the switch on a
    -- page that had been built once handed back the same page, and a language
    -- that only resolves after the first page would have left that one English.
    -- The same two numbers the configurator prints under a shared tree, so a
    -- player comparing the website with the game reads one answer, not two.
    local stepActive, stepTotal = 0, 0
    if m.stepCount then
        local okSteps, a, b = pcall(m.stepCount)
        if okSteps then stepActive, stepTotal = a or 0, b or 0 end
    end

    local cacheKey = tostring(centerId) .. "|" .. conditionMode .. "|" .. I18n.lang()
    local ready = pageCache[cacheKey]
    if ready then return ready end

    -- By paldex number, not by name: the number is what the game prints next to
    -- every Pal, and a player looking for #020 does not want to know that it is
    -- called Melpaca first. The strings are zero padded, so plain text order is
    -- numeric order, and a variant lands right behind its base form ("#111"
    -- before "#111B"). Anything without a number goes last rather than to the
    -- front, where an empty string would otherwise sort it.
    -- A copy: the model hands out one and the same list to every caller now, so
    -- sorting it in place leaves its own list in paldex order - and the widget
    -- window that reads it draws its Pals by name.
    local ordered = {}
    for i = 1, #pals do ordered[i] = pals[i] end
    table.sort(ordered, function(a, b)
        local na, nb = Paldex[a], Paldex[b]
        if na and nb and na ~= nb then return na < nb end
        if na and not nb then return true end
        if nb and not na then return false end
        return nameOf(a) < nameOf(b)
    end)

    -- Skipped entirely when docked, not just hidden: the list is 289 portraits
    -- in base64 and by far the largest part of the page.
    local list = {}
    for _, id in ipairs(docked and {} or ordered) do
        local img = icon(id)
        list[#list + 1] = string.format(
            '<a class="item%s" id="pick/%s" href="#pick/%s" style="--tint:%s">%s'
            .. '<span class="nm">%s</span><span class="num">%s</span><span class="dot"></span></a>',
            id == centerId and " on" or "", esc(id), esc(id), tintOf(id),
            img and string.format('<img src="%s" alt="">', img) or "",
            esc(nameOf(id)), esc(Paldex[id] or ""))
    end

    local incoming, outgoing = m.neighbours(centerId, "in"), m.neighbours(centerId, "out")

    --- Twenty-two neighbours in config order look shuffled, because that order
    --- means nothing to the reader. Sorted: the plain steps first and by level,
    --- so the block reads as a progression, and the ones with conditions last -
    --- those carry chips, are twice as tall, and would otherwise stretch a row
    --- band somewhere in the middle of the grid.
    local function sortNeighbours(list)
        local function lowestLevel(e)
            local best = math.huge
            for _, step in ipairs(e.steps) do
                local lv = step.minLevel or 0
                if lv < best then best = lv end
            end
            return best == math.huge and 0 or best
        end
        local function hasConditions(e)
            for _, step in ipairs(e.steps) do
                if step.conditions and #step.conditions > 0 then return true end
            end
            return false
        end
        -- By level first, always. Sorting the conditional ones to the back
        -- looked tidy but broke the progression: a Lv 1 step appeared after a
        -- Lv 12 one just because it carried a condition.
        table.sort(list, function(a, b)
            local la, lb = lowestLevel(a), lowestLevel(b)
            if la ~= lb then return la < lb end
            local ca, cb = hasConditions(a), hasConditions(b)
            if ca ~= cb then return cb end
            return nameOf(a.id) < nameOf(b.id)
        end)
        return list
    end
    sortNeighbours(incoming)
    sortNeighbours(outgoing)
    -- Above this many on either side the portraits shrink, which is what keeps
    -- a Pal with twenty ways out on one screen instead of scrolling off it, and
    -- the conditions fold away with them.
    -- The same number the wings switch layout at. Left at six, a side with
    -- exactly six entries drew dense cards and kept the condition chips that
    -- density is supposed to fold away.
    local crowded = #incoming > 5 or #outgoing > 5
    showConditions = (conditionMode == "on")
        or (conditionMode == "auto" and not crowded)


    local function wing(entries, dir, title, emptyText)
        if #entries == 0 then
            return string.format(
                '<div class="wing"><div class="wing-head">%s &middot; 0</div>'
                .. '<div class="empty">%s</div></div>', title, emptyText)
        end
        -- The count belongs in the header. Twenty-two cards in five columns do
        -- not say "twenty-two" by themselves, and the number is the first thing
        -- a reader wants from this side of the screen.
        title = string.format("%s &middot; %d", title, #entries)

        -- Each side decides its own density: one crowded wing used to shrink
        -- the quiet one too, which made a lone neighbour look unimportant.
        -- Six was one too many: six roomy cards are wider than the space beside
        -- the hub, so the column was pushed out of the frame and the portraits
        -- on the left were cut in half. Five is what fits.
        local crowded = #entries > 5

        if crowded then
            -- Read left to right: the grid fills a row before it starts the
            -- next one, so the last few Pals never end up alone in a short
            -- column on the right, which looked like cards were missing.
            local cards = {}
            for _, e in ipairs(entries) do
                local badge = m.onwardCount(e.id) - (dir == "in" and 1 or 0)
                -- inside a card the portrait is not its own link: the card is
                local pal = portrait(e.id, "var(--pal)", "", badge, false)
                local body = pal .. connector(e)
                -- the index rides along so the cards can arrive in order
                -- rather than all at once, which reads as one movement
                cards[#cards + 1] = string.format(
                    '<a class="row" href="#pick/%s" style="--i:%d">%s</a>',
                    esc(e.id), math.min(#cards, 14), body)
            end
            return string.format(
                '<div class="wing dense"><div class="wing-head">%s</div>'
                .. '<div class="col %s dense">%s</div></div>',
                title, dir, table.concat(cards))
        end

        local parts = {}
        for _, e in ipairs(entries) do
            -- one of an incoming neighbour's own steps leads here, and that step
            -- is already on screen, so it does not deserve a badge
            local badge = m.onwardCount(e.id) - (dir == "in" and 1 or 0)
            local pal = portrait(e.id, "var(--pal)", "", badge)
            parts[#parts + 1] = dir == "in"
                and string.format('<div class="row">%s%s</div>', pal, connector(e))
                or string.format('<div class="row">%s%s</div>', connector(e), pal)
        end

        local rows = math.min(#entries, 5)
        return string.format(
            '<div class="wing"><div class="wing-head">%s</div>'
            .. '<div class="col %s" style="grid-template-rows:repeat(%d,auto)">%s</div></div>',
            title, dir, rows, table.concat(parts))
    end

    local html = table.concat({
        '<!doctype html><html><head><meta charset="utf-8"><style>', CSS,
        '</style></head><body', docked and ' class="docked"' or '', '>',
        '<div class="top"><span class="brand">Palvolve</span>',
        string.format('<span class="meta">%s</span><span class="spacer"></span>',
            t("treeCount", #pals, stepActive, stepTotal)),
        string.format('<a class="switch" href="#conditions/%s">%s</a>',
            showConditions and "off" or "on",
            t(showConditions and "treeHideConditions" or "treeShowConditions")),
        -- A page of the Palpedia closes the way that screen does; the control is
        -- only offered where it is the only way out, or where the config asks.
        (docked and Config.treeCloseButton ~= true) and "</div>"
            or string.format(
                '<a class="keys" href="#close"><span class="key">ESC</span>%s</a></div>',
                t("treeClose")),
        '<div class="body">',
        docked and ""
            or ('<div class="side"><h2>' .. t("treeSideTitle") .. '</h2>'
                .. table.concat(list) .. '</div>'),
        '<div class="stage">',
        wing(incoming, "in", t("treeEvolvesFrom"), t("treeNoIncoming")),
        string.format('<div class="hub"><div class="sel">%s</div>%s</div>',
            t("treeSelected"),
            portrait(centerId, "var(--hub)", "center", nil)),
        wing(outgoing, "out", t("treeEvolvesInto"), t("treeNoOutgoing")),
        '</div></div>',
        '<div class="watermark">Palvolve</div>',
        string.format('<div class="foot"><span><b>%s</b> %s &middot; %s</span>'
            .. '<span class="hint">%s</span></div>',
            esc(nameOf(centerId)),
            esc(Paldex[centerId] or ""),
            t("treeSummary", #incoming, #outgoing),
            esc(t("treeBadgeHint"))),
        '</body></html>',
    })
    rememberPage(cacheKey, html)
    return html
end

--- Fills the icon cache. This runs off the game thread, so the pace is about
--- not hogging a core rather than about frames: a batch stops at whichever
--- comes first, the count or the time budget, so a slow disk cannot turn one
--- call into a long one. Returns false when there is nothing left to do.
local warmIndex = 1

--- How many portraits are cached and how many there are in total, for the line
--- the loader prints when it is done. A support log that says "48 of 61" tells
--- the difference between a slow warm-up and portraits that do not exist.
function M.warmProgress()
    local m = model()
    if not m then return 0, 0 end
    local okIds, ids = pcall(m.listedPals)
    if not (okIds and ids) then return 0, 0 end
    return math.min(warmIndex - 1, #ids), #ids
end

function M.warmIcons(count, budgetSeconds)
    local m = model()
    if not m then return false end
    local okIds, ids = pcall(m.listedPals)
    if not (okIds and ids) then return false end
    -- Measured, twice, and the second measurement is the one that counts.
    -- One portrait costs 5 to 10 ms, and while the game loads this loop is only
    -- given a turn every 2.4 seconds, so a bigger batch does finish sooner: 221
    -- portraits in 113 s instead of several minutes. It also made the game
    -- stutter, because those are CPU seconds and file reads taken while the
    -- engine is streaming its own assets. Being early is worth less than being
    -- quiet, so the batch stays small: the cache only has to be warm before
    -- someone opens the Palpedia, and a page builds its own missing portraits
    -- anyway.
    local budget = budgetSeconds or 0.012
    local started = os.clock()
    local done = 0
    while warmIndex <= #ids and done < (count or 4) do
        icon(ids[warmIndex])
        warmIndex = warmIndex + 1
        done = done + 1
        if (os.clock() - started) >= budget then break end
    end
    if Config.devMode and done > 0 then
        print(string.format("[Palvolve] [warm] %d portraits in %d ms (%d of %d done)\n",
            done, math.floor((os.clock() - started) * 1000), warmIndex - 1, #ids))
    end
    return warmIndex <= #ids
end

--- Which Pal a fragment asks for, or nil. The address is all that comes back
--- from the browser, so this is the whole input channel.
function M.pickFrom(url)
    if type(url) ~= "string" then return nil end
    return url:match("#pick/([%w_%-%.]+)")
end

--- Did the reader click the close control. Same channel as a Pal click: there
--- is no other way for the page to say anything.
function M.isClose(url)
    return type(url) == "string" and url:find("#close", 1, true) ~= nil
end

return M
