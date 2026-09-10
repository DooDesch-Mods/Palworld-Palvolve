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
-- Measured on build 25094871 before this was written, because the deciding
-- fact is not in any dump (INGAME-TREE.md carries the table):
--   * the three slots hang on a CanvasPanel at x=8, y=12/56/100, size 508x32
--   * ActiveSkillPanelArray holds those three and CAN be extended from Lua
--   * after UpdateActiveSkill_Binded the fourth entry SURVIVES, and the game
--     fills it: BindedWazaID 43/44/45 on the named three, 46 on the new one
-- So the fill is array-driven. The count three lives only in the three widgets
-- authored in the WidgetTree.
--
-- Data-driven on purpose: the extra widget follows how many moves actually
-- arrive, so a Pal with three moves shows three slots and no empty fourth.
--
-- NOT covered here, and both are written down in INGAME-TREE.md: a click on the
-- fourth slot does not open the swap list (Lua cannot bind OnClicked; the way in
-- is the BndEvt hook the Paldex tab uses), and hover does not highlight it. The
-- fourth move is shown, not yet edited.
--
-- Client only. The status screen does not exist on a dedicated server, and a
-- retry poll for a class that never loads is the shape that "wuerfelt bis zum
-- Tod" in UE4SS-LESSONS.md.

local Config = require("config")
local Role = require("role")

local MoveSlot4 = {}

local MOD_NAME = "Palvolve"
local SCREEN_CLASS = "WBP_MainMenu_Pal_00_C"
local SLOT_CLASS = "WBP_MainMenu_Pal_Skill_Active_C"
local UPDATE_FN =
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Pal/WBP_MainMenu_Pal_00."
    .. "WBP_MainMenu_Pal_00_C:UpdateActiveSkill_Binded"

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

local function Log(message)
    print(string.format("[%s] [slot4] %s\n", MOD_NAME, tostring(message)))
end

--- A live instance, never the cooked template: every widget blueprint keeps one
--- that answers to the same class, and taking it is what makes a mod act on a
--- screen that is not on the player's monitor.
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

--- Builds the fourth widget once per screen and hangs it beside the third.
local function screenName(screen)
    local n = ""
    pcall(function() n = tostring(screen:GetFullName()) end)
    return n
end

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
    if Config.devMode then
        Log(string.format("fourth slot built at (%s, %s)", tostring(x), tostring(y)))
    end
    return widget
end

--- Runs before the screen fills its rows. Four moves coming in means the array
--- needs a fourth entry; three means the extra row goes away again, so an
--- ordinary Pal never shows an empty slot it cannot have.
local function onUpdate(screen, skills)
    local wanted = 0
    pcall(function() wanted = #skills:get() end)
    if wanted == 0 then pcall(function() wanted = #skills end) end

    local arr = nil
    pcall(function() arr = screen.ActiveSkillPanelArray end)
    if not arr then return end

    local have = 0
    pcall(function() have = #arr end)

    if wanted <= 3 then
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
    Log("fourth move slot will be drawn when a Pal carries one")
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
