-- moveslot4.lua: draws the fourth active move, which the game grants and then
-- never shows.
--
-- The mod can hand a Pal a fourth active move (evolutionBonusSlot /
-- prestigeBonusSlot, palslots.lua). The grant works and says so in the log. The
-- status screen does not: it is built with three slot widgets, so the fourth
-- move is invisible. And because the game compacts EquipWaza when a move is
-- removed, a player who edits the loadout loses the fourth slot for good
-- without ever having seen it.
--
-- The layout of build 25094871, which no dump carries, so it is written out
-- here (INGAME-TREE.md has the full table):
--   * the three slots hang on a CanvasPanel at x=8, y=12/56/100, size 508x32
--   * ActiveSkillPanelArray holds those three and CAN be extended from Lua
--   * after UpdateActiveSkill_Binded the fourth entry SURVIVES, and the game
--     fills it: BindedWazaID 43/44/45 on the named three, 46 on the new one
-- So the fill is array-driven. The count three lives only in the three widgets
-- authored in the WidgetTree.
--
-- Which Pals get the row: every Pal that carries four moves, and a Pal that
-- carries three but has earned the slot, so a slot emptied by removing a move
-- stays there as "Free slot" instead of vanishing. Earned means the matching
-- setting is on and the Pal has been through the step that grants it: at least
-- one evolution for evolutionBonusSlot, at least one prestige for
-- prestigeBonusSlot. Both are read off the Pal's own Evolved and Prestige
-- passives, so nothing new is stored.
--
-- The game does the editing itself. Its fill empties a row beyond the move
-- count ("Free slot", BindedWazaID 0), OpenChangeActiveSkillList opens the swap
-- list for any row it is handed, and picking a move there replaces the row's
-- move by value or, on an empty row, adds it as the fourth. What the extra row
-- lacks is the wiring: the screen bound OnClicked, OnHovered and OnUnhovered on
-- its three authored rows only, and Lua cannot bind a delegate. So the row's own
-- button handlers are hooked, and for the extra row this module calls the
-- screen's function the binding would have called. On Palworld 1.0.5:
--   BndEvt ..._0_... -> OpenChangeActiveSkillList
--   BndEvt ..._4_... -> OnHoveredActiveSkillButtonEvent
--   BndEvt ..._5_... -> OnUnhoveredActiveSkillButtonEvent
--
-- Client only. The status screen does not exist on a dedicated server, and a
-- retry poll for a class that never loads is the shape that "wuerfelt bis zum
-- Tod" in UE4SS-LESSONS.md.

local Config = require("config")
local Role = require("role")
local PalPassives = require("palpassives")
local WazaInherit = require("wazainherit")

local MoveSlot4 = {}

local MOD_NAME = "Palvolve"
local SCREEN_CLASS = "WBP_MainMenu_Pal_00_C"
local SCREEN_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Pal/WBP_MainMenu_Pal_00.WBP_MainMenu_Pal_00_C:"
local UPDATE_FN = SCREEN_PATH .. "UpdateActiveSkill_Binded"
local ROW_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Pal/WBP_MainMenu_Pal_Skill_Active."
    .. "WBP_MainMenu_Pal_Skill_Active_C:BndEvt__WBP_MainMenu_Pal_Skill_Active_WBP_PalInvisibleButton_K2Node_"
local ROW_CLICK_FN = ROW_PATH .. "ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"
local ROW_HOVER_FN = ROW_PATH .. "ComponentBoundEvent_4_CommonButtonBaseClicked__DelegateSignature"
local ROW_UNHOVER_FN = ROW_PATH .. "ComponentBoundEvent_5_CommonButtonBaseClicked__DelegateSignature"

-- geometry of the authored rows, read back at runtime rather than assumed;
-- these are only the fallback if the read fails
local FALLBACK_X, FALLBACK_Y, FALLBACK_STEP = 8.0, 12.0, 44.0
local FALLBACK_W, FALLBACK_H = 508.0, 32.0

local hooked = false
-- The extra row, and the screen it belongs to BY NAME. Not a table keyed on the
-- screen object: UE4SS hands out a fresh userdata for the same UObject on every
-- lookup, so such a key never matches itself and every fill built another
-- widget. The full name is stable for the life of the screen.
local extraWidget = nil
local extraScreenName = nil
-- The screen object itself, to call its handlers for the extra row, and the
-- row's full name, to recognise it inside the row class's hooks.
local extraScreen = nil
local extraWidgetName = nil

local function Log(message)
    print(string.format("[%s] [slot4] %s\n", MOD_NAME, tostring(message)))
end

-- The fill below runs once per selected Pal, so a standing fault would write
-- a line per click. One line per session is enough to tell it apart from a
-- hook that never ran.
local warned = {}
local function warnOnce(message)
    if warned[message] then return end
    warned[message] = true
    Log("[WARN] " .. message)
end

local function canvasSlotOf(widget)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    if not (lib and lib:IsValid()) then return nil end
    local slot = nil
    pcall(function() slot = lib:SlotAsCanvasSlot(widget) end)
    if slot and slot:IsValid() then return slot end
    return nil
end

--- Where the fourth row goes, derived from the authored ones so a layout change
--- in a game patch carries over instead of being baked in here.
local function fourthRowGeometry(screen)
    local second = canvasSlotOf(screen.WBP_MainMenu_Pal_Skill_Active_1)
    local third = canvasSlotOf(screen.WBP_MainMenu_Pal_Skill_Active_2)
    local x, y, w, h = FALLBACK_X, FALLBACK_Y + 3 * FALLBACK_STEP, FALLBACK_W, FALLBACK_H
    if second and third then
        local p2, p3, s3 = nil, nil, nil
        pcall(function() p2 = second:GetPosition() end)
        pcall(function() p3 = third:GetPosition() end)
        pcall(function() s3 = third:GetSize() end)
        if p2 and p3 then
            x = p3.X
            y = p3.Y + (p3.Y - p2.Y)
        end
        if s3 then w, h = s3.X, s3.Y end
    end
    return x, y, w, h
end

--- Identity of a screen as a string. The widget belongs to one screen and the
--- name is what ties it there.
local function screenName(screen)
    local n = ""
    pcall(function() n = tostring(screen:GetFullName()) end)
    return n
end

--- Builds the fourth widget once per screen and hangs it beside the third.
local function ensureExtra(screen)
    local existing = nil
    if extraWidget and extraWidget:IsValid() and extraScreenName == screenName(screen) then
        existing = extraWidget
    end
    if existing then
        -- It is taken off the panel whenever a Pal shows three moves, so being
        -- here again means it has to go back on.
        local parent = nil
        pcall(function() parent = existing:GetParent() end)
        if parent and parent:IsValid() then return existing end
        local host = nil
        pcall(function() host = screen.WBP_MainMenu_Pal_Skill_Active_2:GetParent() end)
        if host and host:IsValid() then
            local okBack = pcall(function() host:AddChildToCanvas(existing) end)
            if okBack then
                local bx, by, bw, bh = fourthRowGeometry(screen)
                local back = canvasSlotOf(existing)
                if back then
                    pcall(function() back:SetAutoSize(false) end)
                    pcall(function() back:SetPosition({ X = bx, Y = by }) end)
                    pcall(function() back:SetSize({ X = bw, Y = bh }) end)
                end
                return existing
            end
            Log("[WARN] the fourth slot could not be put back on the row")
        end
        return nil
    end

    local third = nil
    pcall(function() third = screen.WBP_MainMenu_Pal_Skill_Active_2 end)
    if not (third and third:IsValid()) then
        Log("[WARN] the third slot is not there, so no fourth was added")
        return nil
    end
    local canvas = nil
    pcall(function() canvas = third:GetParent() end)
    if not (canvas and canvas:IsValid()) then
        Log("[WARN] the slot row has no parent panel, so no fourth was added")
        return nil
    end
    local pc = nil
    pcall(function() pc = Role.localPlayerCtx() end)
    pc = pc and pc.pc or nil
    if not (pc and pc:IsValid()) then
        Log("[WARN] no local player controller, so no fourth slot was built")
        return nil
    end

    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not (lib and lib:IsValid()) then
        Log("[WARN] WidgetBlueprintLibrary is not there, so no fourth slot was built")
        return nil
    end

    local widget = nil
    local ok, err = pcall(function() widget = lib:Create(pc, third:GetClass(), pc) end)
    if not (ok and widget and widget:IsValid()) then
        Log("[WARN] the fourth slot widget could not be created: " .. tostring(err))
        return nil
    end

    local okAdd, errAdd = pcall(function() canvas:AddChildToCanvas(widget) end)
    if not okAdd then
        Log("[WARN] the fourth slot could not be hung on the row: " .. tostring(errAdd))
        return nil
    end

    local x, y, w, h = fourthRowGeometry(screen)
    local slot = canvasSlotOf(widget)
    if slot then
        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() slot:SetPosition({ X = x, Y = y }) end)
        pcall(function() slot:SetSize({ X = w, Y = h }) end)
    else
        Log("[WARN] the fourth slot has no canvas slot, so it sits where the panel put it")
    end

    extraWidget = widget
    extraScreenName = screenName(screen)
    extraScreen = screen
    extraWidgetName = nil
    local okName, errName = pcall(function() extraWidgetName = tostring(widget:GetFullName()) end)
    if not okName then
        Log("[WARN] the fourth slot has no readable name, so clicks on it are not forwarded: "
            .. tostring(errName))
    end
    if Config.devMode then
        Log(string.format("fourth slot built at (%s, %s)", tostring(x), tostring(y)))
    end
    return widget
end

--- The Pal the screen shows. BindFromHandle stores the handle before it fills
--- the rows, so it is already the new Pal when the fill reaches onUpdate.
local function screenParam(screen)
    local ok, param = pcall(function()
        return screen.CachedIndividualHandle:TryGetIndividualParameter()
    end)
    if not ok then
        warnOnce("the Pal on the status screen could not be read: " .. tostring(param))
        return nil
    end
    if param and param:IsValid() then return param end
    return nil
end

--- Clears the empty MasteredWaza entries older evolutions left behind.
--- The swap list reads that array, and each empty entry shows up there as
--- ACTION_SKILL_None with 999 power. The fill runs before the list can open, so
--- a Pal is repaired the first time its status screen shows it.
local function repairMoves(param)
    local ok, removed, detail = WazaInherit.repair(param)
    if not ok then
        warnOnce("empty move entries could not be removed, the swap list may show ACTION_SKILL_None: "
            .. tostring(detail))
    elseif removed > 0 then
        Log(string.format("removed %d empty move entr(ies) from the Pal on the status screen [%s]",
            removed, tostring(detail)))
    end
end

--- Whether this Pal has earned a fourth slot, so an empty one is still shown.
local function hasEarnedFourth(param)
    if not (param and param:IsValid()) then return false end
    local evoOn = Config.evolutionBonusSlot == "active"
    local prestigeOn = Config.prestigeBonusSlot == "active"
    if not (evoOn or prestigeOn) then return false end
    local ok, stages, resolveErr = pcall(PalPassives.resolve, param)
    if not ok or type(stages) ~= "table" then
        warnOnce("the Pal's evolution stages could not be read, so an empty fourth slot is not shown: "
            .. tostring(ok and resolveErr or stages))
        return false
    end
    local evolved = tonumber(stages.evolved and stages.evolved.stage) or 0
    local prestiged = tonumber(stages.prestige and stages.prestige.stage) or 0
    return (evoOn and evolved >= 1) or (prestigeOn and prestiged >= 1)
end

--- Runs before the screen fills its rows. Four moves coming in means the array
--- needs a fourth entry. Three mean the same for a Pal that has earned the slot,
--- which the fill then shows as "Free slot"; any other Pal loses the extra row,
--- so it never shows a slot it cannot have.
local function onUpdate(screen, skills)
    local wanted = 0
    local okList = pcall(function() wanted = #skills:get() end)
    if wanted == 0 then
        local okDirect = pcall(function() wanted = #skills end)
        okList = okList or okDirect
    end
    if not okList then
        -- Neither read worked, so wanted stays 0 and the branch below takes
        -- the row away again, which is the right answer for a count nobody
        -- knows. Without this line a Pal with four moves shows three and
        -- nothing anywhere says why.
        warnOnce("the move list could not be read, so the fourth slot stays off")
    end

    local arr = nil
    pcall(function() arr = screen.ActiveSkillPanelArray end)
    if not arr then
        warnOnce("the screen has no ActiveSkillPanelArray, so no fourth slot is drawn")
        return
    end

    local have = 0
    pcall(function() have = #arr end)

    local param = screenParam(screen)
    if param then repairMoves(param) end
    local earnedEmpty = wanted == 3 and hasEarnedFourth(param)

    if wanted <= 3 and not earnedEmpty then
        local extra = nil
        if extraWidget and extraWidget:IsValid() and extraScreenName == screenName(screen) then
            extra = extraWidget
        end
        if extra then
            -- Unparented, not hidden and not destroyed. Visibility loses this
            -- argument: the row is filled after this runs and the fill resets
            -- it, so a collapsed slot came back as an empty fourth row on every
            -- ordinary Pal. Off the panel it cannot be drawn whatever the fill
            -- does, and the object survives for the next Pal in the list -
            -- rebuilding per selection is what makes a list stutter.
            pcall(function() extra:RemoveFromParent() end)
        end
        return
    end

    local extra = ensureExtra(screen)
    if not extra then return end
    if have < 4 then
        local okSet, errSet = pcall(function() arr[4] = extra end)
        if not okSet then
            Log("[WARN] the fourth slot could not be added to the row list: " .. tostring(errSet))
            return
        end
        -- The row was built during this very fill, so the pass that is about to
        -- run took its widget list before the fourth entry existed. Setting the
        -- move here is what stops the first look at a Pal from showing an empty
        -- fourth slot; every later fill finds the entry already in place.
        local id = nil
        pcall(function() id = skills:get()[4] end)
        if id == nil then pcall(function() id = skills[4] end) end
        if id ~= nil then
            local okFill, errFill = pcall(function() extra:SetWazaID(id) end)
            if not okFill then
                Log("[WARN] the fourth move was not written on the first look: " .. tostring(errFill))
            end
        end
    end
end

--- True when the row a hook fired for is the extra row. Compared by full name:
--- the userdata for the same widget differs from lookup to lookup.
local function isExtraRow(rowParam)
    if not extraWidgetName then return false end
    local row = nil
    local okRow, errRow = pcall(function() row = rowParam:get() end)
    if not okRow then
        warnOnce("a move row event carried no readable row: " .. tostring(errRow))
        return false
    end
    if not (row and row:IsValid()) then return false end
    local n = nil
    local okName, errName = pcall(function() n = tostring(row:GetFullName()) end)
    if not okName then
        warnOnce("a move row's name could not be read, so it is not matched to the fourth slot: "
            .. tostring(errName))
        return false
    end
    return n == extraWidgetName, row
end

local function liveExtraScreen()
    if extraScreen and extraScreen:IsValid() and screenName(extraScreen) == extraScreenName then
        return extraScreen
    end
    return nil
end

local function forwardRowEvent(rowParam, screenFn, label)
    local mine, row = isExtraRow(rowParam)
    if not mine then return end
    local screen = liveExtraScreen()
    if not screen then
        Log("[WARN] the fourth slot was " .. label .. " but its screen is gone")
        return
    end
    local ok, err = pcall(function() screen[screenFn](screen, row) end)
    if not ok then
        Log("[WARN] the fourth slot " .. label .. " did not reach the screen: " .. tostring(err))
    elseif Config.devMode then
        Log("fourth slot " .. label)
    end
end

local function onRowClick(self)
    forwardRowEvent(self, "OpenChangeActiveSkillList", "clicked")
end

local function onRowHover(self)
    forwardRowEvent(self, "OnHoveredActiveSkillButtonEvent", "hovered")
end

local function onRowUnhover(self)
    forwardRowEvent(self, "OnUnhoveredActiveSkillButtonEvent", "left")
end

--- Registers the hook. Only ever called once a screen of that class exists:
--- the widget blueprint is not loaded at startup, and a Blueprint hook
--- registered while a world loads aborts the process (UE4SS-LESSONS.md 2).
local function hookNow()
    if hooked then return end
    local ok, err = pcall(function()
        RegisterHook(UPDATE_FN, function(self, skills)
            local screen = nil
            pcall(function() screen = self:get() end)
            if not (screen and screen:IsValid()) then return end
            local okRun, errRun = pcall(onUpdate, screen, skills)
            if not okRun then
                Log("[WARN] the fourth slot was not drawn this time: " .. tostring(errRun))
            end
        end)
    end)
    if not ok then
        Log("[WARN] the status screen could not be hooked, so the fourth move stays hidden: "
            .. tostring(err))
        return
    end
    hooked = true
    -- The rest only adds editing on top of the drawing, so each failure is
    -- reported and the row stays visible either way.
    local extras = {
        { ROW_CLICK_FN, onRowClick, "clicks, so the fourth slot cannot be swapped" },
        { ROW_HOVER_FN, onRowHover, "hover, so the fourth slot does not light up" },
        { ROW_UNHOVER_FN, onRowUnhover, "hover end on the fourth slot" },
    }
    for _, entry in ipairs(extras) do
        local okExtra, errExtra = pcall(RegisterHook, entry[1], entry[2])
        if not okExtra then
            Log("[WARN] could not hook " .. entry[3] .. ": " .. tostring(errExtra))
        end
    end
    Log("fourth move slot will be drawn when a Pal carries one or has earned it")
end

function MoveSlot4.init()
    if Role.isDedicated() then return end

    -- The notify only raises a flag; the loop does the work. Registering a hook
    -- inside the notify itself is the shape that has aborted the process here
    -- before, and the loop also gives an idle guard for free.
    local pending = false
    local ok, err = pcall(function()
        NotifyOnNewObject("/Script/UMG.UserWidget", function(object)
            if hooked or pending then return end
            local n = ""
            pcall(function() n = tostring(object:GetClass():GetFName():ToString()) end)
            if n == SCREEN_CLASS then pending = true end
        end)
    end)
    if not ok then
        Log("[WARN] could not watch for the status screen, so the fourth move stays hidden: "
            .. tostring(err))
        return
    end

    LoopAsync(1000, function()
        if hooked then return true end
        if pending then
            pending = false
            local okHook, errHook = pcall(hookNow)
            if not okHook then
                Log("[WARN] hooking the status screen failed: " .. tostring(errHook))
            end
        end
        return false
    end)
end

return MoveSlot4
