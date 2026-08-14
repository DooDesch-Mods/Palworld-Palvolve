-- Palvolve dev probes (devMode only, not part of the shipped packages).
-- Markers: [probe-speciesswap] [probe-vfx] [probe-overlay] [probe-ake]
--          [probe-freeze] [probe-giveexp] [probe-testkit] [probe-revert]
--          [probe-daynight] [probe-weather] [probe-loc] [probe-ctx]
--          [probe-waterstatus] [probe-wazaelem] [probe-hpscale] [cond]
--          [probe-finale-assets] [probe-finale-play] [probe-finale-duo]
--
-- Keybinds (test world "ModDev", own pal summoned) - all disarmed, see
-- PROBE_HOTKEYS below:
--   F5 = overlay glow on/off (M_Glow)     F6 = cycle visual effects
--   F7 = morph summoned pal through FX test bases (test world ONLY!)
--   F8 = fanfare (AKE_CampLevelUp)        F9 = freeze/unfreeze nearest pal
--   F10 = EXP to pals around (level-up smoke test)
--   F3 = revert own evolved pals          INSERT (fallback F4) = test kit
--   END = free-evolution toggle (no stone/material costs)
--   HOME = time/weather + evaluated conditions   PAGE_UP = location/context
--   PAGE_DOWN = pal raw readings (water, status sweep, waza elements, HP)
--   F1 = finale asset probe (verdicts + component capture check)
--   BACKSPACE = FULL evolution run, one press per element stage: the
--               summoned pal evolves into a random stage target
--   Chat commands for compact keyboards (devMode only): !palvolve free
--   (= END), !palvolve kit (= INSERT), !palvolve fx (standalone finale
--   cycle at the summoned pal)
--
local M = {}

-- Every keybind listed above is OFF. They fire during ordinary play, and two of
-- them change the world while they do: BACKSPACE runs a full evolution, F7
-- morphs the summoned pal's species. The chat commands stay - those only fire
-- when they are typed. Set this to true to arm the keys again.
local PROBE_HOTKEYS = false
local RegisterAnyKeyBind = RegisterKeyBind
local function RegisterKeyBind(key, fn)
    if PROBE_HOTKEYS then RegisterAnyKeyBind(key, fn) end
end

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- UE4SS keybinds fire twice (~35ms apart) -> debounce.
local lastFire = {}
local function Debounced(name, fn)
    return function()
        local now = os.clock()
        if lastFire[name] and (now - lastFire[name]) < 0.5 then return end
        lastFire[name] = now
        fn()
    end
end

-- No load-time hooks live here: a registration retry loop can register a
-- script hook twice when UE4SS has already queued a deferred registration
-- internally, and stacked script hooks on one BP function are a crash
-- risk when the function fires.

-- ---------------------------------------------------------------- helpers

local function firstOwnedMonster()
    -- Prefers the player's own (otomo) pal; otherwise the first spawned monster.
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    local all = FindAllOf("BP_MonsterBase_C") or {}
    if util and util:IsValid() then
        for _, pal in ipairs(all) do
            if pal:IsValid() then
                local isOtomo = false
                pcall(function() isOtomo = util:IsPlayersOtomo(pal) end)
                if isOtomo then return pal end
            end
        end
    end
    for _, pal in ipairs(all) do
        if pal:IsValid() then return pal end
    end
    return nil
end

-- ---------------------------------------------------------------- keybind probes

-- Arrow keys drive the evolution tree window while it is open, and do nothing
-- otherwise. Keys rather than clicks because a UMG button delegate has never
-- been proven to reach Lua in this project; when it is, the clicks join them
-- and these stay as the keyboard route.
local function treeKey(delta, dir)
    return function()
        ExecuteInGameThread(function()
            local ok, view = pcall(require, "treeview")
            if not (ok and view and view.isOpen and view.isOpen()) then return end
            if delta then view.move(delta) else view.step(dir) end
        end)
    end
end

-- UE4SS spells them DOWN_ARROW, not DOWN; the first attempt registered nothing
-- and the window simply did not answer.
if Key and Key.DOWN_ARROW then
    RegisterKeyBind(Key.DOWN_ARROW, Debounced("treedown", treeKey(1, nil)))
    RegisterKeyBind(Key.UP_ARROW, Debounced("treeup", treeKey(-1, nil)))
    RegisterKeyBind(Key.RIGHT_ARROW, Debounced("treeright", treeKey(nil, "out")))
    RegisterKeyBind(Key.LEFT_ARROW, Debounced("treeleft", treeKey(nil, "in")))
    Log(PROBE_HOTKEYS and "[tree] arrow keys registered" or "[tree] probe hotkeys are off")
else
    Log("[tree] arrow key constants missing in this UE4SS build")
end



-- F5: overlay fallback (M_Glow), restored after ~2s
RegisterKeyBind(Key.F5, Debounced("overlay", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local pal = firstOwnedMonster()
            if not pal then Log("[probe-overlay] no pal spawned") return end
            local glow = StaticFindObject("/Game/Pal/Effect/Material/M_Glow.M_Glow")
            if not glow or not glow:IsValid() then Log("[probe-overlay] M_Glow not found") return end
            local mesh = pal:GetMainMesh()
            mesh:SetOverlayMaterial(glow)
            -- one-shot LoopAsync instead of ExecuteWithDelay (callback GC
            -- trap, see UE4SS-LESSONS section 1)
            local restored = false
            LoopAsync(2000, function()
                if restored then return true end
                restored = true
                ExecuteInGameThread(function()
                    if pal:IsValid() and mesh:IsValid() then
                        mesh:SetOverlayMaterial(nil)
                        Log("[probe-overlay] restored")
                    end
                end)
                return true
            end)
            Log("[probe-overlay] set on " .. pal:GetFullName())
        end)
        if not suc then Log("[probe-overlay] FAIL: " .. tostring(e)) end
    end)
end))

-- F6: cycle through the game's own visual effects - each press plays the next.
-- 1=CaptureEmissive glows white and makes the pal VANISH (the dissolve side);
-- 2=SpawnFromBallEmissive is the appear side.
local VFX_IDS = {
    { id = 1,  name = "CaptureEmissive (glow + vanish)" },
    { id = 2,  name = "SpawnFromBallEmissive (appear with glow)" },
    { id = 41, name = "PalEnhancement" },
    { id = 27, name = "RarePal" },
    { id = 5,  name = "FadeIn" },
    { id = 4,  name = "FadeOut" },
}
local vfxIndex = 0
RegisterKeyBind(Key.F6, Debounced("vfx", function()
    ExecuteInGameThread(function()
        local pal = firstOwnedMonster()
        if not pal then Log("[probe-vfx] no pal spawned") return end
        vfxIndex = (vfxIndex % #VFX_IDS) + 1
        local entry = VFX_IDS[vfxIndex]
        local suc, e = pcall(function()
            local fx = pal.VisualEffectComponent:AddVisualEffect(entry.id, { FloatValues = {} })
            Log(string.format("[probe-vfx] %s -> %s", entry.name,
                fx and fx:IsValid() and fx:GetFullName() or "nil/invalid"))
        end)
        if not suc then Log(string.format("[probe-vfx] %s FAIL: %s", entry.name, tostring(e))) end
    end)
end))

-- F7: morph the summoned own pal through FX test bases (test world ONLY!)
-- Each press moves to the next species; resummon afterwards so the model
-- rebuilds. The list covers diverse element transitions for the staged
-- FX colors (dissolve = old element, reveal = target element).
local MORPH_CYCLE = {
    { id = "Penguin",        note = "Water/Ice evolution -> Penking" },
    { id = "AmaterasuWolf",  note = "Fire -> Dark adaptation" },
    { id = "CatMage",        note = "Dark -> Fire adaptation" },
    { id = "FairyDragon",    note = "Dragon -> Water adaptation" },
    { id = "GrassMammoth",   note = "Leaf -> Ice adaptation" },
    { id = "FlowerDinosaur", note = "Leaf -> Electric adaptation" },
    { id = "Gorilla",        note = "-> Earth adaptation" },
    { id = "CaptainPenguin", note = "-> Electric adaptation (Black)" },
    { id = "PinkRabbit",     note = "Normal -> Leaf adaptation (Grass)" },
    { id = "KingBahamut",    note = "Fire -> Dragon adaptation (Ryu)" },
    { id = "NegativeOctopus", note = "Dark -> Normal adaptation (Primo)" },
}
local morphIndex = 0
RegisterKeyBind(Key.F7, Debounced("speciesswap", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local pal = firstOwnedMonster()
            if not (pal and pal:IsValid()) then
                Log("[probe-speciesswap] no own pal summoned")
                return
            end
            local p = pal.CharacterParameterComponent:GetIndividualParameter()
            morphIndex = (morphIndex % #MORPH_CYCLE) + 1
            local target = MORPH_CYCLE[morphIndex]
            local before = p:GetCharacterID():ToString()
            p.SaveParameter.CharacterID = FName(target.id)
            p.SaveParameterMirror.CharacterID = FName(target.id)
            Log(string.format("[probe-speciesswap] %s -> %s (%s) - resummon for the model",
                before, target.id, target.note))
        end)
        if not suc then Log("[probe-speciesswap] FAIL: " .. tostring(e)) end
    end)
end))

-- END or chat "!palvolve free": free-evolution toggle for FX test sessions -
-- disables stone AND material costs at runtime (the resolve cache is
-- dropped so armed pairs reprice immediately). Exposed on M for the chat
-- command path: compact keyboards have no END key.
local savedCosts = nil
function M.toggleFreeMode()
    local suc, e = pcall(function()
        local cfg = require("config")
        local Costs = require("costs")
        if savedCosts == nil then
            savedCosts = { stone = cfg.requireStone, costs = cfg.costs.enabled }
            cfg.requireStone = false
            cfg.costs.enabled = false
            Log("[probe-costs] FREE MODE ON - evolutions cost nothing (END or !palvolve free toggles back)")
        else
            cfg.requireStone = savedCosts.stone
            cfg.costs.enabled = savedCosts.costs
            savedCosts = nil
            Log("[probe-costs] free mode off - normal costs apply again")
        end
        Costs.clearCache()
    end)
    if not suc then Log("[probe-costs] FAIL: " .. tostring(e)) end
end
RegisterKeyBind(Key.END, Debounced("costtoggle", function()
    ExecuteInGameThread(M.toggleFreeMode)
end))

-- Free mode ON regardless of current state (the full-run probe needs the
-- gates open, never closed).
function M.ensureFreeMode()
    if savedCosts == nil then M.toggleFreeMode() end
end

-- F3: revert for testing - takes all OWNED candidates and logs the raw owner
-- guid. The local host player's uid lives in the D component (...-0001).
local REVERT_PAIRS = {
    { from = "CaptainPenguin_Black", to = "Penguin" },  -- black Penking -> Pengullet
    { from = "CaptainPenguin", to = "Penguin" },        -- Penking -> Pengullet
    { from = "MopKing", to = "MopBaby" },               -- Sweepa -> Swee
    { from = "Yeti_Grass", to = "Yeti" },               -- Wumpo Botan -> Wumpo
    { from = "Yeti", to = "MopKing" },                  -- Wumpo -> Sweepa
}
local function ownerGuidString(p)
    local s = "unreadable"
    pcall(function()
        local g = p.SaveParameter.OwnerPlayerUId
        s = string.format("%08X-%08X-%08X-%08X", g.A, g.B, g.C, g.D)
    end)
    return s
end

local function hasOwner(p)
    local owned = false
    pcall(function()
        local g = p.SaveParameter.OwnerPlayerUId
        owned = (g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0)
    end)
    return owned
end

RegisterKeyBind(Key.F3, Debounced("revert", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local all = FindAllOf("PalIndividualCharacterParameter") or {}
            local count = 0
            for _, p in ipairs(all) do
                if p:IsValid() and hasOwner(p) then
                    local id = p:GetCharacterID():ToString()
                    for _, pair in ipairs(REVERT_PAIRS) do
                        if id == pair.from then
                            p.SaveParameter.CharacterID = FName(pair.to)
                            p.SaveParameterMirror.CharacterID = FName(pair.to)
                            count = count + 1
                            Log(string.format("[probe-revert] %s -> %s (owner guid %s)",
                                pair.from, pair.to, ownerGuidString(p)))
                            break
                        end
                    end
                end
            end
            if count == 0 then
                Log("[probe-revert] no revert candidates found")
            else
                Log(string.format("[probe-revert] %d pal(s) reverted - resummon for the model", count))
            end
        end)
        if not suc then Log("[probe-revert] FAIL: " .. tostring(e)) end
    end)
end))

-- F8: fanfare via Wwise
RegisterKeyBind(Key.F8, Debounced("ake", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local pal = firstOwnedMonster()
            local ake = StaticFindObject("/Game/Pal/Sound/Events/SE/UI/CampLevelUp/AKE_CampLevelUp.AKE_CampLevelUp")
            local aks = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics")
            if not (ake and ake:IsValid()) then Log("[probe-ake] AKE_CampLevelUp not found") return end
            if not (aks and aks:IsValid()) then Log("[probe-ake] AkGameplayStatics not found") return end
            local id = aks:PostEvent(ake, pal, 0, nil, false)
            Log("[probe-ake] PostEvent id=" .. tostring(id))
        end)
        if not suc then Log("[probe-ake] FAIL: " .. tostring(e)) end
    end)
end))

-- F9: freeze toggle (AI off + move lock)
local frozen = false
RegisterKeyBind(Key.F9, Debounced("freeze", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local pal = firstOwnedMonster()
            if not pal then Log("[probe-freeze] no pal spawned") return end
            frozen = not frozen
            local ctrl = pal:GetController()
            if ctrl and ctrl:IsValid() then ctrl:SetActiveAI(not frozen) end
            local util = StaticFindObject("/Script/Pal.Default__PalUtility")
            if util and util:IsValid() then
                util:SetMoveDisableFlag(pal, frozen, FName("EvoSeq"))
            end
            Log("[probe-freeze] frozen=" .. tostring(frozen) .. " on " .. pal:GetFullName())
        end)
        if not suc then Log("[probe-freeze] FAIL: " .. tostring(e)) end
    end)
end))

-- Test kit (INSERT, fallback F4): escalation chain, every step logs its result.
-- Finding: RequestAddItem_ForDebug and the Debug_Capture*_ToServer RPCs run
-- without errors but do NOTHING in the shipping build -> the authoritative
-- paths with return value checks are used instead.
local function giveItemsV2(inv)
    -- Authoritative path (single player = local authority): check the result enum
    local ok, err = pcall(function()
        local ret1 = inv:AddItem_ServerInternal(FName("PalSphere"), 20, false, 0.0, true)
        local ret2 = inv:AddItem_ServerInternal(FName("PalSphere_Mega"), 10, false, 0.0, true)
        -- Palvolve stones (exist only when PalSchema loaded the items)
        local ret3 = inv:AddItem_ServerInternal(FName("Palvolve_EvolutionStone"), 5, false, 0.0, true)
        local ret4 = inv:AddItem_ServerInternal(FName("Palvolve_AdaptionStone"), 5, false, 0.0, true)
        Log(string.format("[probe-testkit] AddItem PalSphere=%s Mega=%s EvoStone=%s AdaptStone=%s",
            tostring(ret1), tostring(ret2), tostring(ret3), tostring(ret4)))
        -- Material costs for the smoke pairs (Penguin line + crafting inputs)
        for _, mat in ipairs({ "IceOrgan", "PalFluid", "MeteorDrop", "Pal_crystal_S" }) do
            inv:AddItem_ServerInternal(FName(mat), 30, false, 0.0, true)
        end
    end)
    if not ok then Log("[probe-testkit] AddItem_ServerInternal FAIL: " .. tostring(err)) end
end

local function getCheatManager(pc)
    local cm = pc.CheatManager
    if cm and cm:IsValid() then return cm end
    -- shipping builds create the cheat manager only after EnableCheats
    pcall(function() pc:EnableCheats() end)
    cm = pc.CheatManager
    if cm and cm:IsValid() then return cm end
    return nil
end

local function givePalsV2(pc)
    -- All pal-give paths are confirmed dead in retail; SpawnMonster stays as the
    -- last candidate (result visible only in-world).
    local cm = getCheatManager(pc)
    if cm then
        local ok, err = pcall(function()
            cm:SpawnMonster(FName("Penguin"), 31)
        end)
        Log(string.format("[probe-testkit] cm:SpawnMonster ok=%s err=%s", tostring(ok), tostring(err)))
    else
        Log("[probe-testkit] no CheatManager (even after EnableCheats)")
    end
end

-- Time acceleration for the weather recording session. Weather follows the day
-- cycle and cannot be set directly, so running the clock faster is the only way
-- to see several weather states in one sitting. The retail build has no console
-- and the chat parser passes no arguments, so this cycles fixed rates instead
-- of taking one.
local TIME_SCALES = { 1.0, 20.0, 60.0 }
local timeScaleIdx = 1
function M.cycleTimeScale()
    local playerCtx = Role.localPlayerCtx()
    local pc = playerCtx and playerCtx.pc
    if not (pc and pc:IsValid()) then
        Log("[probe-time] no player controller")
        return nil
    end
    local cm = getCheatManager(pc)
    if not cm then
        Log("[probe-time] no CheatManager (even after EnableCheats)")
        return nil
    end
    timeScaleIdx = (timeScaleIdx % #TIME_SCALES) + 1
    local rate = TIME_SCALES[timeScaleIdx]
    local ok, err = pcall(function() cm:SetPalWorldTimeScale(rate) end)
    Log(string.format("[probe-time] SetPalWorldTimeScale(%.1f) ok=%s%s", rate, tostring(ok),
        ok and "" or (" err=" .. tostring(err))))
    return ok and rate or nil
end

-- Exposed on M for the chat command path ("!palvolve kit"): compact
-- keyboards have no INSERT key.
function M.giveTestKit()
    local suc, e = pcall(function()
        local pc = FindFirstOf("PalPlayerController")
        if not pc or not pc:IsValid() then Log("[probe-testkit] no PalPlayerController") return end
        local ps = pc:GetPalPlayerState()
        if not ps or not ps:IsValid() then Log("[probe-testkit] no PalPlayerState") return end
        local inv = ps:GetInventoryData()
        if inv and inv:IsValid() then
            giveItemsV2(inv)
        else
            Log("[probe-testkit] no InventoryData")
        end
        givePalsV2(pc)
    end)
    if not suc then Log("[probe-testkit] FAIL: " .. tostring(e)) end
end
local KIT_KEY = Key.INS or Key.F4
RegisterKeyBind(KIT_KEY, Debounced("testkit", function()
    ExecuteInGameThread(M.giveTestKit)
end))

-- F10 + NUM9: EXP lever to trigger level-ups reproducibly (NUM9 added since
-- F10 gets swallowed on some setups; numpad keys reliably reach the handlers)
local function giveExpAround()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local player = FindFirstOf("PalPlayerCharacter")
            if not player or not player:IsValid() then Log("[probe-giveexp] no player") return end
            local util = StaticFindObject("/Script/Pal.Default__PalUtility")
            -- GiveExpToAroundPlayerCharacter only hits PLAYERS ->
            -- GiveExpToAroundCharacter with CharacterClass=PalCharacter for pals
            -- (WorldContext, Center, Radius, Exp, CharacterClass, bCallDelegate)
            local center = player:K2_GetActorLocation()
            local palClass = StaticFindObject("/Script/Pal.PalCharacter")
            local okCall, err = pcall(function()
                util:GiveExpToAroundCharacter(player, center, 3000.0, 50000.0, palClass, true)
            end)
            if okCall then
                Log("[probe-giveexp] 50000 EXP given to pals around")
            else
                -- verbatim error: the game update may have changed the
                -- signature (AddStatus did exactly that)
                Log("[probe-giveexp] call FAIL: " .. tostring(err))
            end
        end)
        if not suc then Log("[probe-giveexp] FAIL: " .. tostring(e)) end
    end)
end
RegisterKeyBind(Key.F10, Debounced("giveexp", giveExpAround))
if Key.NUM_NINE then
    RegisterKeyBind(Key.NUM_NINE, Debounced("giveexp9", giveExpAround))
end

-- Radial menu dispatch probes ([probe-radial], wave E stage R1): log which
-- native functions fire while the hold-4 wheel is used, to map entries to
-- hook points. ARMED ON DEMAND via console `palvolve radial` - several of
-- these functions also fire during savegame load (otomo order restore, HUD
-- init), and hooks living through the load path are a crash risk.
-- Armed via F4 (the in-game console is not reliably available in 1.0).
-- A SECOND F4 press takes a full in-world object dump (DumpAllObjects) for
-- the widget analysis - do it right after the wheel was opened once so the
-- radial WBP instance is loaded.
local radialArmed = false
function M.armRadialProbes()
    if radialArmed then
        Log("[probe-radial] taking in-world object dump (this stalls the game for a moment)...")
        local ok, err = pcall(function() DumpAllObjects() end)
        Log(string.format("[probe-radial] DumpAllObjects ok=%s%s (look for UE4SS_ObjectDump.txt next to Win64)",
            tostring(ok), ok and "" or (" err=" .. tostring(err))))
        return
    end
    radialArmed = true

    -- identify the concrete radial WBP class as soon as an instance exists
    local found = false
    LoopAsync(1000, function()
        if found then return true end
        ExecuteInGameThread(function()
            if found then return end
            pcall(function()
                local widgets = FindAllOf("PalUIRadialMenuWidgetBase") or {}
                for _, w in ipairs(widgets) do
                    if w and w:IsValid() then
                        found = true
                        local cls, menuNum = "?", "?"
                        pcall(function() cls = w:GetClass():GetFullName() end)
                        pcall(function() menuNum = tostring(w.menuNum) end)
                        Log(string.format("[probe-radial] widget instance: class=%s menuNum=%s", cls, menuNum))
                    end
                end
            end)
        end)
        return found
    end)
    local function idx(self)
        local i = "?"
        pcall(function() i = tostring(self:get().nowSelectedIndex) end)
        return i
    end
    local ok, err = pcall(function()
        RegisterHook("/Script/Pal.PalUIPlayerRadialMenuBase:OpenOtomoFeedInventory", function(self)
            Log("[probe-radial] OpenOtomoFeedInventory fired")
        end)
        RegisterHook("/Script/Pal.PalUIPlayerRadialMenuBase:LaunchPhotoMode", function(self)
            Log("[probe-radial] LaunchPhotoMode fired")
        end)
        RegisterHook("/Script/Pal.PalUIRadialMenuWidgetBase:SetSelectedIndexForce", function(self, Index)
            local v = "?"
            pcall(function() v = tostring(Index:get()) end)
            Log(string.format("[probe-radial] SetSelectedIndexForce idx=%s now=%s", v, idx(self)))
        end)
        RegisterHook("/Script/Pal.PalUIRadialMenuWidgetBase:ClearSelectedIndex", function(self)
            Log(string.format("[probe-radial] ClearSelectedIndex now=%s", idx(self)))
        end)
        RegisterHook("/Script/Pal.PalOtomoHolderComponentBase:RequestSetOtomoOrder", function(self, OrderType)
            local v = "?"
            pcall(function() v = tostring(OrderType:get()) end)
            Log(string.format("[probe-radial] RequestSetOtomoOrder order=%s", v))
        end)
    end)
    Log(string.format("[probe-radial] hooks armed ok=%s%s", tostring(ok),
        ok and " - open the hold-4 wheel and select each entry" or (" err=" .. tostring(err))))
end

RegisterKeyBind(Key.F4, Debounced("radialarm", function()
    ExecuteInGameThread(function()
        M.armRadialProbes()
    end)
end))

-- ------------------------------------------------ condition probes (X/Y evos)
-- Markers: [probe-daynight] [probe-weather] on HOME
--          [probe-loc] [probe-ctx] on PAGE_UP
--          [probe-waterstatus] [probe-wazaelem] [probe-hpscale] on PAGE_DOWN
-- Their raw readings freeze the constants in conditions.lua (status ids,
-- region prefixes, stage type, waza elements, HP fixed-point scale) and
-- decide whether the Tier B conditions (weather, hp, hunger, trust, riding)
-- get unlocked in the web editor.

local Conditions = require("conditions")
local Role = require("role")

-- gate-shaped ctx: the summoned otomo of the LOCAL player (never FindFirstOf
-- on controllers - wrong player on a host with guests)
local function conditionCtx()
    local playerCtx = Role.localPlayerCtx()
    if not playerCtx then return nil, "no local player" end
    local holder = nil
    pcall(function()
        local cls = StaticFindObject("/Script/Pal.PalOtomoHolderComponentBase")
        if cls and playerCtx.pc and playerCtx.pc:IsValid() then
            local h = playerCtx.pc:GetComponentByClass(cls)
            if h and h:IsValid() then holder = h end
        end
    end)
    if not holder then return nil, "no otomo holder" end
    local actor = nil
    pcall(function() actor = holder:TryGetSpawnedOtomo() end)
    if not (actor and actor:IsValid()) then return nil, "no own pal summoned" end
    local param = nil
    pcall(function() param = actor.CharacterParameterComponent:GetIndividualParameter() end)
    if not (param and param:IsValid()) then return nil, "no individual parameter" end
    return { actor = actor, param = param, playerCtx = playerCtx, holder = holder }
end

local function bindProbeKey(keyName, name, fn)
    local key = Key[keyName]
    if not key then
        Log(string.format("[probe-cond] key %s unavailable - probe %s unbound", keyName, name))
        return
    end
    RegisterKeyBind(key, Debounced(name, function()
        ExecuteInGameThread(function()
            local suc, e = pcall(fn)
            if not suc then Log(string.format("[%s] FAIL: %s", name, tostring(e))) end
        end)
    end))
end

-- World state (time of day, weather) + the evaluated view of every
-- boolean condition for the summoned pal. Exported so the chat probe
-- (!palvolve xcond) can trigger it on keyboards without a nav cluster.
function M.worldProbe()
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    local playerCtx = Role.localPlayerCtx()
    local wc = playerCtx and playerCtx.pawn
    if not (util and util:IsValid() and wc and wc:IsValid()) then
        Log("[probe-daynight] no world context")
        return
    end
    pcall(function()
        local tm = util:GetTimeManager(wc)
        local gs = util:GetGameSetting(wc)
        Log(string.format("[probe-daynight] IsNight=%s type=%d hour=%d hoursF=%.2f nightWindow=%d..%d",
            tostring(util:IsNight(wc)), tm:GetCurrentDayTimeType(),
            tm:GetCurrentPalWorldTime_Hour(), tm:GetCurrentPalWorldHoursFloat(),
            gs.NightStartHour, gs.NightEndHour))
    end)
    local sky = FindFirstOf("PalSkyCreator")
    if sky and sky:IsValid() then
        pcall(function()
            local fx = sky.WeatherSettings.WeatherFXSettings
            local fog = sky.WeatherSettings.ExponentialHeightFogSettings
            Log(string.format("[probe-weather] rain=%.2f snow=%.2f lightning=%s fogDensity=%.4f timeOfDay=%.2f",
                fx.RainAmount, fx.SnowAmount, tostring(fx.EnableLightnings),
                fog.FogDensity, sky.TimeOfDay))
        end)
    else
        Log("[probe-weather] no PalSkyCreator instance")
    end
    local ctx, why = conditionCtx()
    if ctx then
        Conditions.debugDump(ctx)
    else
        Log("[probe-world] no condition ctx: " .. tostring(why))
    end
end

-- HOME: same world probe as a keybind
bindProbeKey("HOME", "probe-world", M.worldProbe)

-- PAGE_UP: player location (region/stage/sanctuary raw) + player context
-- (party slots, own base, combat, riding, gliding, level)
bindProbeKey("PAGE_UP", "probe-loc", function()
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    local playerCtx = Role.localPlayerCtx()
    local pawn = playerCtx and playerCtx.pawn
    if not (util and util:IsValid() and pawn and pawn:IsValid()) then
        Log("[probe-loc] no local player pawn")
        return
    end
    pcall(function()
        local ps = playerCtx.playerState
        local region = pawn.LastInsideRegionNameID:ToString()
        local inStage, inDungeon, insideStage = "?", "?", "?"
        pcall(function() inStage = tostring(ps:IsInStage()) end)
        pcall(function() inDungeon = tostring(ps:IsInStateByStageType(1)) end)
        pcall(function() insideStage = tostring(util:IsInsideStage(pawn)) end)
        local sanctuary = "?"
        pcall(function()
            local sub = util:GetWildlifeSanctuarySubsystem(pawn)
            local loc = pawn:K2_GetActorLocation()
            local area = sub:FindArea({ X = loc.X, Y = loc.Y, Z = loc.Z })
            sanctuary = tostring((area ~= nil) and area:IsValid())
        end)
        Log(string.format("[probe-loc] region=%q inStage=%s inDungeon=%s isInsideStage=%s sanctuary=%s",
            region, inStage, inDungeon, insideStage, sanctuary))
    end)
    pcall(function()
        local cls = StaticFindObject("/Script/Pal.PalOtomoHolderComponentBase")
        local holder = playerCtx.pc:GetComponentByClass(cls)
        if holder and holder:IsValid() then
            local n = holder:GetMaxOtomoNum()
            for i = 0, n - 1 do
                local h = holder:GetOtomoIndividualHandle(i)
                if h and h:IsValid() then
                    local id, spawned = "nil", false
                    pcall(function()
                        local p = h:TryGetIndividualParameter()
                        if p and p:IsValid() then id = p:GetCharacterID():ToString() end
                    end)
                    pcall(function()
                        local a = h:TryGetIndividualActor()
                        spawned = a and a:IsValid() or false
                    end)
                    Log(string.format("[probe-ctx] party slot=%d id=%s spawned=%s", i, id, tostring(spawned)))
                end
            end
        end
    end)
    pcall(function()
        local mgr = util:GetBaseCampManager(pawn)
        local loc = pawn:K2_GetActorLocation()
        local camp = mgr:GetInRangedBaseCamp({ X = loc.X, Y = loc.Y, Z = loc.Z }, 0.0)
        if camp and camp:IsValid() then
            local cg = camp:GetGroupIdBelongTo()
            local pg = pawn.CharacterParameterComponent:GetIndividualParameter():GetGroupId()
            Log(string.format("[probe-ctx] baseCamp inRange=true own=%s",
                tostring(cg.A == pg.A and cg.B == pg.B and cg.C == pg.C and cg.D == pg.D)))
        else
            Log("[probe-ctx] baseCamp inRange=false")
        end
    end)
    pcall(function()
        local bm = util:GetBattleManager(pawn)
        local out = {}
        local conflictOk, conflict = pcall(function() return bm:GetConflictEnemies(pawn, out, true) end)
        Log(string.format("[probe-ctx] combat callOk=%s conflict=%s anyPlayer=%s",
            tostring(conflictOk), tostring(conflict), tostring(bm:IsBattleModeAnyPlayer())))
    end)
    pcall(function()
        local mv = pawn:GetPalCharacterMovementComponent()
        Log(string.format("[probe-ctx] riding=%s ridingFly=%s gliding=%s jetpack=%s playerLevel=%d",
            tostring(playerCtx.pc:IsRiding()), tostring(playerCtx.pc:IsRidingFlyPal()),
            tostring(mv:IsGliding()), tostring(mv:IsJetpackGliding()),
            pawn.CharacterParameterComponent:GetIndividualParameter():GetLevel()))
    end)
end)

-- PAGE_DOWN: summoned pal raw readings (water, active status sweep, waza
-- elements, HP fixed-point scale, gender/stomach/trust)
bindProbeKey("PAGE_DOWN", "probe-pal", function()
    local ctx, why = conditionCtx()
    if not ctx then
        Log("[probe-waterstatus] no condition ctx: " .. tostring(why))
        return
    end
    pcall(function()
        local mv = ctx.actor:GetPalCharacterMovementComponent()
        Log(string.format("[probe-waterstatus] entered=%s swimming=%s rate=%.2f mode=%s",
            tostring(mv:IsEnteredWater()), tostring(mv:IsSwimming()),
            mv:GetInWaterRate(), tostring(mv.MovementMode)))
    end)
    pcall(function()
        local sc = ctx.actor.StatusComponent
        local active = {}
        for id = 1, 77 do
            pcall(function()
                local s = sc:GetExecutionStatus(id)
                if s ~= nil and s:IsValid() then table.insert(active, tostring(id)) end
            end)
        end
        Log(string.format("[probe-waterstatus] active status ids: %s",
            #active > 0 and table.concat(active, ",") or "none"))
    end)
    pcall(function()
        local util = StaticFindObject("/Script/Pal.Default__PalUtility")
        local db = util:GetWazaDatabase(ctx.actor)
        if not (db and db:IsValid()) then
            Log("[probe-wazaelem] no waza database")
            return
        end
        local function dump(kind, list)
            local ok = pcall(function()
                for i = 1, #list do
                    -- indexed TArray access yields RemoteUnrealParam wrappers
                    local v = list[i]
                    if type(v) == "userdata" then
                        pcall(function() v = v:get() end)
                    end
                    local out = {}
                    local hit = db:FindWazaForBP(v, out)
                    Log(string.format("[probe-wazaelem] %s waza=%s found=%s element=%s",
                        kind, tostring(v), tostring(hit), tostring(out.Element)))
                end
            end)
            if not ok then Log(string.format("[probe-wazaelem] %s list not indexable", kind)) end
        end
        dump("mastered", ctx.param:GetMasteredWaza())
        dump("equipped", ctx.param:GetEquipWaza())
    end)
    pcall(function()
        local fixedMax = "?"
        pcall(function() fixedMax = tostring(ctx.param.SaveParameter.MaxHP.Value) end)
        Log(string.format("[probe-hpscale] hpFixed=%d maxInt=%d maxFixed=%s",
            ctx.param:GetHP().Value, ctx.param:GetMaxHP(), fixedMax))
    end)
    pcall(function()
        Log(string.format("[probe-pal] gender=%s stomachRate=%.2f trustRank=%s condenserRank=%s",
            tostring(ctx.param:GetGenderType()), ctx.param:GetFullStomachRate(),
            tostring(ctx.param:GetFriendshipRank()), tostring(ctx.param:GetRank())))
    end)
end)

-- NUM_SEVEN: toggle day/night (authoritative in SP; night window is 23..3).
-- Replaces the PalDefender /settime dependency for condition tests.
bindProbeKey("NUM_SEVEN", "probe-settime", function()
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    local playerCtx = Role.localPlayerCtx()
    local wc = playerCtx and playerCtx.pawn
    if not (util and util:IsValid() and wc and wc:IsValid()) then
        Log("[probe-settime] no world context")
        return
    end
    local tm = util:GetTimeManager(wc)
    if not (tm and tm:IsValid()) then
        Log("[probe-settime] no time manager")
        return
    end
    local isNight = util:IsNight(wc)
    local targetHour = isNight and 12 or 1
    tm:SetGameTime_FixDay(targetHour)
    Log(string.format("[probe-settime] was %s -> set hour %d, now IsNight=%s",
        isNight and "night" or "day", targetHour, tostring(util:IsNight(wc))))
end)

-- NUM_EIGHT: cycle a status effect on the summoned pal (burn -> electrical ->
-- freeze -> poison -> clear). Authoritative in SP; replaces hunting wild pals
-- for the status condition tests.
local statusCycle = {
    { id = 19, name = "burn" },
    { id = 22, name = "electrical" },
    { id = 21, name = "freeze" },
    { id = 5, name = "poison" },
}
local statusCycleIdx = 0
bindProbeKey("NUM_EIGHT", "probe-status", function()
    local ctx, why = conditionCtx()
    if not ctx then
        Log("[probe-status] no ctx: " .. tostring(why))
        return
    end
    local sc = ctx.actor.StatusComponent
    if not (sc and sc:IsValid()) then
        Log("[probe-status] no status component")
        return
    end
    local function cycleActive(id)
        local active = false
        pcall(function()
            local s = sc:GetExecutionStatus(id)
            active = (s ~= nil) and s:IsValid()
        end)
        return active
    end
    statusCycleIdx = statusCycleIdx + 1
    if statusCycleIdx > #statusCycle then
        statusCycleIdx = 0
        local okClear = pcall(function() sc:RemoveAll() end)
        local remaining = {}
        for _, e in ipairs(statusCycle) do
            if cycleActive(e.id) then table.insert(remaining, e.name) end
        end
        Log(string.format("[probe-status] clear ok=%s remaining=%s",
            tostring(okClear), #remaining > 0 and table.concat(remaining, ",") or "none"))
        return
    end
    local entry = statusCycle[statusCycleIdx]
    -- isolate the tested status: drop the previously injected one first so
    -- the conditions never see two probe statuses at once
    local prev = statusCycle[statusCycleIdx - 1]
    if prev then pcall(function() sc:RemoveStatus(prev.id) end) end
    -- build 24181527 dropped the FStatusDynamicParameter argument: the live
    -- UFunction takes only the status id
    local okAdd, err = pcall(function() sc:AddStatus(entry.id) end)
    local prevGone = (prev == nil) or not cycleActive(prev.id)
    Log(string.format("[probe-status] AddStatus %s(%d) ok=%s active=%s prevCleared=%s err=%s (after %s a clear step follows)",
        entry.name, entry.id, tostring(okAdd), tostring(cycleActive(entry.id)),
        tostring(prevGone), okAdd and "-" or tostring(err), statusCycle[#statusCycle].name))
end)

-- F1: resolve every finale recipe slot for all elements and log a per-slot
-- verdict (OK / FALLBACK / MISSING), then check whether
-- SpawnSystemAtLocation's returned component marshals into a usable handle
-- (decides if looping specs are allowed at all). Save the log block right
-- away - UE4SS.log truncates on every process start.
-- (F1/BACKSPACE instead of numpad or nav-cluster keys: compact keyboards
-- have neither numpad nor DEL/HOME/END; F2-F10 are taken, F11 is the
-- game's fullscreen toggle, F12 fires the Steam screenshot.)
bindProbeKey("F1", "probe-finale-assets", function()
    local ctx, why = conditionCtx()
    if not ctx then
        Log("[probe-finale-assets] no ctx: " .. tostring(why))
        return
    end
    local loc = ctx.actor:K2_GetActorLocation()
    local r = require("finale").probeAll(ctx.holder, loc.X, loc.Y, loc.Z + 100)
    if r then
        Role.chat(ctx.playerCtx, string.format(
            "Palvolve finale assets: %d showy OK, %d fallback, %d candidate(s) missing, capture %s (details: UE4SS.log)",
            r.showyOk, r.fallback, r.missing, r.captureOk and "OK" or "FAIL"))
    end
end)

-- Chat "!palvolve fx": play the layered finale standalone at the summoned
-- pal - one call per stage, cycling the nine single elements and then
-- three dual-element samples. Quick per-element tuning without running an
-- evolution; the sample pal's capsule half feeds the same anchoring and
-- species scaling as a real sequence.
local FINALE_CYCLE = {
    { "Normal" }, { "Fire" }, { "Water" }, { "Leaf" }, { "Electricity" },
    { "Ice" }, { "Earth" }, { "Dark" }, { "Dragon" },
    { "Water", "Ice" }, { "Fire", "Dark" }, { "Dragon", "Leaf" },
}
local finaleCycleIdx = 0
function M.playFinaleSample()
    local ctx, why = conditionCtx()
    if not ctx then
        Log("[probe-finale-play] no ctx: " .. tostring(why))
        return
    end
    finaleCycleIdx = (finaleCycleIdx % #FINALE_CYCLE) + 1
    local elems = FINALE_CYCLE[finaleCycleIdx]
    local loc = ctx.actor:K2_GetActorLocation()
    -- scaled collision capsule = grounding measure; mesh half = body
    -- framing measure (GetSimpleCollisionHalfHeight is not a UFunction)
    local half, meshHalf = nil, nil
    pcall(function()
        local cap = ctx.actor.CapsuleComponent
        if cap and cap:IsValid() then half = cap:GetScaledCapsuleHalfHeight() end
    end)
    pcall(function()
        local spc = ctx.actor.StaticCharacterParameterComponent
        if spc and spc:IsValid() and spc.MeshCapsuleHalfHeight > 0 then
            meshHalf = spc.MeshCapsuleHalfHeight
        end
    end)
    Log(string.format("[probe-finale-play] %s (%d/%d, collHalf=%s meshHalf=%s)",
        table.concat(elems, "+"), finaleCycleIdx, #FINALE_CYCLE,
        tostring(half), tostring(meshHalf)))
    -- echo the stage into the in-game chat so the tester sees what plays
    -- without tailing the log
    local Finale = require("finale")
    Role.chat(ctx.playerCtx, string.format("Palvolve finale test %d/%d: %s (coll %.0f, mesh %.0f)",
        finaleCycleIdx, #FINALE_CYCLE, table.concat(elems, "+"), half or 0, meshHalf or 0))
    Role.chat(ctx.playerCtx, Finale.describeSchedule(elems))
    Finale.playStandalone(ctx.holder, loc.X, loc.Y, loc.Z, elems, half, meshHalf)
end

-- BACKSPACE: FULL evolution run with ONE press - the currently summoned
-- pal evolves into a RANDOM target of the next element stage via
-- Evolution.debugEvolveTo (dev entry, NO gates: level, alpha, conditions
-- and configured pairs are all bypassed; free mode is forced so costs stay
-- zero). The real sequence runs from dissolve to finale on the pal as it
-- stands - no morphing, no resummon. Stages cover all nine reveal elements
-- plus three true dual-element targets (sourced from elements_static.lua);
-- a failed start keeps the stage for a retry.
local FULL_CYCLE = {
    { note = "Normal",           targets = { "CubeTurtle_Neutral", "WhiteMoth_Neutral" } },
    { note = "Fire",             targets = { "Suzaku", "KingBahamut" } },
    { note = "Water",            targets = { "Suzaku_Water", "Horus_Water" } },
    { note = "Leaf",             targets = { "LilyQueen", "GrassPanda" } },
    { note = "Electricity",      targets = { "ElecPanda", "ThunderDog" } },
    { note = "Ice",              targets = { "WhiteTiger", "IceHorse" } },
    { note = "Earth",            targets = { "Gorilla_Ground", "DrillGame" } },
    { note = "Dark",             targets = { "BlackGriffon", "CatVampire" } },
    { note = "Dragon",           targets = { "FairyDragon", "SkyDragon" } },
    { note = "Water+Ice dual",   targets = { "CaptainPenguin" } },
    { note = "Dragon+Leaf dual", targets = { "SkyDragon_Grass" } },
    { note = "Fire+Dark dual",   targets = { "Manticore_Dark" } },
}
local fullRunIdx = 0
bindProbeKey("BACKSPACE", "probe-finale-run", function()
    local ctx, why = conditionCtx()
    if not ctx then
        Log("[probe-finale-run] no ctx: " .. tostring(why))
        return
    end
    local Evolution = require("evolution")
    local rawId = ctx.param:GetCharacterID():ToString()
    local nextIdx = (fullRunIdx % #FULL_CYCLE) + 1
    local st = FULL_CYCLE[nextIdx]
    local pool = {}
    for _, t in ipairs(st.targets) do
        if t ~= rawId then pool[#pool + 1] = t end
    end
    if #pool == 0 then pool = st.targets end
    local target = pool[math.random(#pool)]
    M.ensureFreeMode()
    Log(string.format("[probe-finale-run] %d/%d %s: %s -> %s",
        nextIdx, #FULL_CYCLE, st.note, rawId, target))
    Role.chat(ctx.playerCtx, string.format("Palvolve full run %d/%d (%s): evolving %s -> %s",
        nextIdx, #FULL_CYCLE, st.note, rawId, target))
    pcall(function()
        local elemsTo = require("elements").of(target, ctx.holder)
        if elemsTo then
            Role.chat(ctx.playerCtx, require("finale").describeSchedule(elemsTo))
        end
    end)
    local ok, msg = Evolution.debugEvolveTo(target)
    if ok then
        fullRunIdx = nextIdx
    else
        Role.chat(ctx.playerCtx, "Palvolve full run: " .. tostring(msg))
        Log(string.format("[probe-finale-run] FAIL: %s", tostring(msg)))
    end
end)


-- Spike for the configurable workbench unlock level. The stage lives in the
-- PalSchema building JSON as Technology.LevelCap, which a Workshop update
-- overwrites, so the goal is to set it at runtime from config_user.lua instead.
-- PalTechnologyDataTableRowBase carries LevelCap as a plain IntProperty and both
-- technology tables exist as objects; what is unknown is whether Lua can reach a
-- row at all. This reports what is reachable rather than assuming, once per
-- session after the tables have had time to load.
local function probeTechnologyTable()
    local PATHS = {
        "/Game/Pal/DataTable/Technology/DT_TechnologyRecipeUnlock.DT_TechnologyRecipeUnlock",
        "/Game/Pal/DataTable/Technology/DT_TechnologyRecipeUnlock_Common.DT_TechnologyRecipeUnlock_Common",
    }
    for _, path in ipairs(PATHS) do
        local dt = nil
        pcall(function() dt = StaticFindObject(path) end)
        if not (dt and dt:IsValid()) then
            Log("[probe-tech] not found: " .. path)
        else
            local cls = "?"
            pcall(function() cls = dt:GetClass():GetFName():ToString() end)
            Log(string.format("[probe-tech] found %s (class %s)", path, cls))

            -- RowMap is TMap<FName, uint8*>; UE4SS Lua may refuse the raw value
            local ok, err = pcall(function()
                local rm = dt.RowMap
                if rm == nil then error("RowMap nil") end
                local n = "?"
                pcall(function() n = tostring(#rm) end)
                Log("[probe-tech]   RowMap readable, entries=" .. n)
            end)
            if not ok then
                Log("[probe-tech]   RowMap NOT readable: " .. tostring(err))
            end

            for _, fn in ipairs({ "FindRow", "BP_FindRow", "GetRowNames" }) do
                pcall(function()
                    if dt[fn] ~= nil then Log("[probe-tech]   exposes " .. fn) end
                end)
            end
        end
    end
end

-- Reads the game's own weather presets instead of waiting for weather. The sky
-- plugin ships one asset per weather state (DT_PPSC_Weather_Rain_01, _Snow_02,
-- _Storm_04, ...), each carrying the same settings structs the live sky exposes,
-- so every state's rain, snow, fog and lightning values can be read in one pass
-- with no weather ever occurring. That is what the four weather conditions need
-- in order to be calibrated.
-- Returns the number of presets it managed to report, so the caller can wait
-- for the world: only a stub preset exists at the main menu, the per-weather
-- assets come in with the level.
function M.dumpWeatherPresets()
    local presets = FindAllOf("PPSkyCreatorWeatherPreset") or {}
    if #presets == 0 then
        Log("[probe-wpreset] no PPSkyCreatorWeatherPreset objects found")
        return 0
    end
    Log(string.format("[probe-wpreset] %d preset objects", #presets))
    local reported = 0
    for _, p in ipairs(presets) do
        local name = "?"
        pcall(function() name = p:GetFName():ToString() end)
        if not (p and p:IsValid()) then
            Log(string.format("[probe-wpreset] %-32s (invalid object)", name))
        else
            -- Properties, never GetWeatherPresetSettings(): that getter returns the
            -- settings struct by value, and struct-by-value marshalling hard-crashes
            -- the process from Lua in this build - pcall does not catch it. The asset
            -- carries the same data as plain struct properties, which is how the live
            -- sky is read as well.
            local ok, err = pcall(function()
                local fx = p.WeatherFXSettings
                local fog = p.ExponentialHeightFogSettings
                Log(string.format("[probe-wpreset] %-32s rain=%.3f snow=%.3f fog=%.4f lightning=%s",
                    name, fx.RainAmount, fx.SnowAmount, fog.FogDensity, tostring(fx.EnableLightnings)))
            end)
            if ok then
                reported = reported + 1
            else
                Log(string.format("[probe-wpreset] %-32s read FAILED: %s", name, tostring(err)))
            end
        end
    end
    return reported
end

-- one-shot, delayed so the technology tables are past their load
LoopAsync(15000, function()
    ExecuteInGameThread(function() pcall(probeTechnologyTable) end)
    return true
end)

-- ---------------------------------------------------------------- work suitability

-- EPalWorkSuitability, from the object dump. None and the two trailing markers
-- are left out: they are not work types a pal can have a rank in.
local WORK_SUITABILITIES = {
    { 1, "EmitFlame" }, { 2, "Watering" }, { 3, "Seeding" }, { 4, "GenerateElectricity" },
    { 5, "Handcraft" }, { 6, "Collection" }, { 7, "Deforest" }, { 8, "Mining" },
    { 9, "OilExtraction" }, { 10, "ProductMedicine" }, { 11, "Cool" }, { 12, "Transport" },
    { 13, "MonsterFarm" },
}

local function readSuitabilities(param)
    local out = {}
    for _, entry in ipairs(WORK_SUITABILITIES) do
        local value = nil
        pcall(function() value = param:GetWorkSuitabilityRank(entry[1]) end)
        out[entry[1]] = value
    end
    return out
end

-- Experiment E0 for "work suitability keeps the old species until relog".
-- SetWorkSuitabilityAddRank is a reflected setter on the parameter object that
-- has never been tried, and its naming siblings are the getters the Team and
-- Palbox screens read. If a write moves the getter, the whole fix is a handful
-- of Lua lines and needs no native component at all.
--
-- Reads every rank, writes +3 on one work type, reads everything back. Run it
-- right after an evolution, then open the Palbox detail panel and compare.
function M.probeWorkSuitability(work, delta)
    work = tonumber(work) or 5          -- Handcraft: every pal has some rank in it
    delta = tonumber(delta) or 3

    local pal = firstOwnedMonster()
    if not pal then
        Log("[probe-worksuit] no pal found - summon one first")
        return
    end
    -- same route the mod itself uses: the parameter hangs off the character
    -- parameter component, not off the actor
    local param = nil
    pcall(function() param = pal.CharacterParameterComponent:GetIndividualParameter() end)
    if not (param and param:IsValid()) then
        pcall(function() param = pal:GetIndividualParameter() end)
    end
    if not (param and param:IsValid()) then
        Log("[probe-worksuit] pal has no individual parameter")
        return
    end

    local id = "?"
    pcall(function() id = param:GetCharacterID():ToString() end)

    -- Name the actor, not just the species. An evolution leaves the previous
    -- actor in the world for a moment, and firstOwnedMonster takes whichever
    -- otomo it meets first - a measurement that silently used the old pal
    -- looks like a result instead of a mistake.
    local actorName, candidates = "?", 0
    pcall(function() actorName = pal:GetFullName() end)
    pcall(function()
        local util = StaticFindObject("/Script/Pal.Default__PalUtility")
        for _, other in ipairs(FindAllOf("BP_MonsterBase_C") or {}) do
            if other:IsValid() then
                local isOtomo = false
                pcall(function() isOtomo = util:IsPlayersOtomo(other) end)
                if isOtomo then candidates = candidates + 1 end
            end
        end
    end)
    Log(string.format("[probe-worksuit] actor=%s (otomo candidates in world: %d)",
        tostring(actorName), candidates))
    if candidates > 1 then
        Log("[probe-worksuit] WARNING: more than one summoned pal - recall all but the one under test")
    end

    local before = readSuitabilities(param)
    local mapBefore = nil
    pcall(function() mapBefore = param:GetWorkSuitabilityRanksWithCharacterRank() end)

    local wrote, writeErr = pcall(function()
        param:SetWorkSuitabilityAddRank(work, delta)
    end)

    local after = readSuitabilities(param)
    local mapAfter = nil
    pcall(function() mapAfter = param:GetWorkSuitabilityRanksWithCharacterRank() end)

    Log(string.format("[probe-worksuit] pal=%s write(work=%d, delta=%+d) ok=%s%s",
        id, work, delta, tostring(wrote),
        wrote and "" or (" err=" .. tostring(writeErr))))

    for _, entry in ipairs(WORK_SUITABILITIES) do
        local k, name = entry[1], entry[2]
        local b, a = before[k], after[k]
        if b ~= nil or a ~= nil then
            Log(string.format("[probe-worksuit]   %-20s before=%s after=%s%s",
                name, tostring(b), tostring(a),
                (b ~= a) and "   CHANGED" or ""))
        end
    end

    Log(string.format("[probe-worksuit] map getter answered: before=%s after=%s",
        tostring(mapBefore ~= nil), tostring(mapAfter ~= nil)))
    Log("[probe-worksuit] now open the Palbox detail panel and compare the icons")
end

-- ---------------------------------------------------------------- net payload

-- Measures what the host-to-client channel actually carries, which decides
-- whether the host's tree can be sent to a client at all. Nothing here touches
-- the transport: it rides Role.notify, which already goes out over
-- SendScreenLogToClient and is already hooked on the client side, so a failed
-- measurement cannot break the evolve path.
--
-- Run from a CONNECTED CLIENT on a dedicated server ("!palvolve xnet"). The
-- host sends the ladder, the client logs what arrives. Compare the two logs:
-- the largest size present in both is the usable payload.
-- Up to the break, not up to a round number: a size that arrives proves only
-- that size. Each rung is sent REPEATS times, because a single success says
-- nothing about a channel that drops under load, and every line carries its
-- own length and a checksum so a half-arrived frame cannot pass for a whole one.
-- MEASURED 2026-08-12 against the local dedicated server with one client:
-- 64 to 65535 bytes arrive whole, in one message, checksum intact. 131072
-- KILLED THE SERVER PROCESS ("Pure virtual function being called while
-- application was running") and wrote a crash dump. Not an error, not a
-- rejected send - a native death that no pcall can see.
--
-- The ladder therefore stops at what is proven safe. Anything above 65535 is
-- known to be fatal and must never be sent to a live server again; if the
-- boundary between 64 KB and 128 KB ever matters, bisect it on a throwaway
-- server, never on one with players on it.
local LADDER = { 1024, 4096, 16384, 65536 }
local REPEATS = 5

-- Rate, not size. The ladder proved a single message of 65535 bytes arrives
-- whole; it says nothing about ten players joining in the same second. This
-- sends the size the sync design actually uses, back to back, which is the
-- load a full server produces at a wave join.
--
-- Switched on here rather than in the config, because this file never ships:
-- a flag in config.lua would have to survive the whitelist and would be one
-- more thing that can be left on by accident.
local BURST_ON_JOIN = false  -- measured 2026-08-12, leave off
local BURST_COUNT = 20
local BURST_SIZE = 8192
local BURST_INTERVAL_MS = 50

function M.maybeBurstOnJoin(playerCtx)
    if not BURST_ON_JOIN then return end
    if not playerCtx or playerCtx.isLocal then return end
    local sent = 0
    Log(string.format("[probe-burst] %d messages of %d bytes every %d ms",
        BURST_COUNT, BURST_SIZE, BURST_INTERVAL_MS))
    LoopAsync(BURST_INTERVAL_MS, function()
        sent = sent + 1
        if sent > BURST_COUNT then
            Log("[probe-burst] burst done")
            return true
        end
        local head = string.format("burst|%d|%d|", sent, BURST_SIZE)
        local tail = "|end"
        local fill = string.rep("ABCDEFGHIJ", math.ceil(BURST_SIZE / 10))
            :sub(1, math.max(0, BURST_SIZE - #head - #tail - 12))
        local sum = 0
        for i = 1, #fill do sum = (sum * 31 + fill:byte(i)) % 1000000007 end
        local payload = string.format("%s%s|%010d%s", head, fill, sum, tail)
        Log(string.format("[probe-burst] send seq=%d size=%d", sent, #payload))
        pcall(function()
            playerCtx.pc:SendScreenLogToClient("PVLV1|xnet|" .. payload,
                { R = 0.2, G = 1.0, B = 0.4, A = 1.0 }, 0.1, FName("PalvolveXnet"))
        end)
        return false
    end)
end

function M.probeNetPayload(playerCtx)
    local Role = require("role")
    if not playerCtx then
        Log("[probe-xnet] no player context - run this from a connected client")
        return
    end
    if playerCtx.isLocal then
        Log("[probe-xnet] sender is local, so nothing crosses the wire - run it from a client")
        return
    end

    local step = 0
    local rung, rep = 1, 0
    Log(string.format("[probe-xnet] sending %d sizes x %d, largest %d",
        #LADDER, REPEATS, LADDER[#LADDER]))
    -- 250 ms between rungs is a size test, not a rate test. The burst below
    -- answers the second question: whether the channel also carries the same
    -- size back to back, which is what a real transfer would do.
    LoopAsync(250, function()
        if rung > #LADDER then
            Log("[probe-xnet] ladder done")
            return true
        end
        rep = rep + 1
        if rep > REPEATS then
            rung, rep = rung + 1, 1
            if rung > #LADDER then
                Log("[probe-xnet] ladder done")
                return true
            end
        end
        step = step + 1
        local size = LADDER[rung]

        -- ASCII only and self-describing: a truncated line is recognizable by
        -- its missing tail marker, a dropped one by its absent sequence number.
        -- ASCII only and self describing: the sequence number finds a dropped
        -- line, the tail marker a truncated one, and the sum finds the case
        -- that neither shows - a line that arrives whole but altered.
        local head = string.format("xnet|%d|%d|", step, size)
        local tail = "|end"
        local fill = string.rep("ABCDEFGHIJ", math.ceil(size / 10)):sub(1, math.max(0, size - #head - #tail - 12))
        local sum = 0
        for i = 1, #fill do sum = (sum * 31 + fill:byte(i)) % 1000000007 end
        local payload = string.format("%s%s|%010d%s", head, fill, sum % 10000000000, tail)

        Log(string.format("[probe-xnet] send seq=%d size=%d actual=%d sum=%d",
            step, size, #payload, sum))
        -- Straight down the wire, not through Role.notify: that one mirrors
        -- every line into the player's chat, and a ladder of 45 lines would
        -- bury the chat while measuring nothing extra.
        pcall(function()
            playerCtx.pc:SendScreenLogToClient(
                "PVLV1|xnet|" .. payload,
                { R = 0.2, G = 1.0, B = 0.4, A = 1.0 },
                0.1,
                FName("PalvolveXnet"))
        end)
        return false
    end)
end

-- Abort test for the in-game browser (1.6.0). The whole design rests on one
-- assumption: that a mod can put a window on the game's own UI stack and get
-- input mode, closing on B/Esc and the menu sounds for free. PalHUDService
-- exposes Push(WidgetClass, Parameter) -> ID and Close(ID), which is what the
-- game's own screens go through. If this refuses to open, or opens without
-- taking input, or cannot be closed, there is no assetless browser and the
-- design has to change before anything else is built.
--
-- Deliberately opens the plain frame with no content: a failure here is the
-- stack's, not a content widget's.
local BROWSER_FRAME = "/Game/Pal/Blueprint/UI/UserInterface/Common/WBP_PalCommonWindow.WBP_PalCommonWindow_C"
local openWindowId = nil

-- Push only accepts classes derived from PalUserWidgetStackableUI; 120 of the
-- game's own screens qualify. These four are the ones worth looking at as a
-- host for an evolution browser, most promising first. Each press opens the
-- next one, so the shape of each can be judged before anything is built on it.
local BROWSER_CANDIDATES = {
    -- A tree already: nodes with icons, connecting lines, scrolling, click for detail.
    "/Game/Pal/Blueprint/UI/Technology/WBP_TechnologyUI.WBP_TechnologyUI_C",
    -- Pal icons in a scrollable grid with a detail pane.
    "/Game/Pal/Blueprint/UI/Paldex/WBP_Paldex_ForDisplay.WBP_Paldex_ForDisplay_C",
    -- Pan and zoom over a large surface with placed markers.
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Base.WBP_Map_Base_C",
    -- Pal list with sorting and a detail pane.
    "/Game/Pal/Blueprint/UI/PalStorage/WBP_PalStorageMenu.WBP_PalStorageMenu_C",
}
local candidateIndex = 0

-- The service that actually drives the UI hangs off the game instance
-- (PalGameInstance:HUDService). FindFirstOf hands back whatever object of that
-- class it meets first, which is regularly the class default object - it
-- accepts every call, returns a valid-looking id and builds nothing.
local function hudService()
    local gi = FindFirstOf("PalGameInstance")
    if gi and gi:IsValid() then
        local svc = gi.HUDService
        if svc and svc:IsValid() then return svc, "PalGameInstance.HUDService" end
    end
    local loose = FindFirstOf("PalHUDService")
    if loose and loose:IsValid() then return loose, "FindFirstOf" end
    return nil, "none"
end

-- Names every candidate so a silent no-op is traceable to the object it was
-- made on. A full name starting with Default__ is the class default object.
function M.probeHudObjects()
    for _, cls in ipairs({"PalHUDService", "PalHUDInGame", "PalGameInstance"}) do
        local all = FindAllOf(cls) or {}
        Log(string.format("[probe-browser] %s: %d object(s)", cls, #all))
        for i, o in ipairs(all) do
            if i > 4 then break end
            local name = "?"
            pcall(function() name = tostring(o:GetFullName()) end)
            Log(string.format("[probe-browser]   %d: %s", i, name))
        end
    end
    local svc, via = hudService()
    local name = "nil"
    if svc then pcall(function() name = tostring(svc:GetFullName()) end) end
    Log(string.format("[probe-browser] using %s via %s", name, via))
end

function M.probeBrowserWindow()
    local hud, via = hudService()
    if not hud then
        Log("[probe-browser] no PalHUDService in this world")
        return
    end
    Log("[probe-browser] service via " .. via)

    if openWindowId then
        local okClose, errClose = pcall(function() hud:Close(openWindowId) end)
        Log(string.format("[probe-browser] close: ok=%s%s", tostring(okClose),
            okClose and "" or (" err=" .. tostring(errClose))))
        openWindowId = nil
        return
    end

    candidateIndex = candidateIndex % #BROWSER_CANDIDATES + 1
    local path = BROWSER_CANDIDATES[candidateIndex]
    Log(string.format("[probe-browser] candidate %d/%d: %s",
        candidateIndex, #BROWSER_CANDIDATES, path:match("[^.]+$")))

    -- StaticFindObject rather than LoadAsset: these classes are cooked into the
    -- game's own UI packages. A miss means the class is not resident yet, not
    -- that the path is wrong - the screen has to have been opened once.
    local cls = StaticFindObject(path)
    if not cls or not cls:IsValid() then
        Log("[probe-browser] class not resident, open that screen by hand once: " .. path)
        return
    end

    local okPush, result = pcall(function() return hud:Push(cls, nil) end)
    if not okPush then
        Log("[probe-browser] push raised: " .. tostring(result))
        return
    end

    openWindowId = result
    Log(string.format("[probe-browser] pushed, id=%s - closing itself in 8s", tostring(result)))

    -- A pushed screen takes the input, so the chat that opened it is out of
    -- reach and the command cannot close it again. Without this, every single
    -- candidate costs a full game restart.
    local myId = result
    ExecuteWithDelay(8000, function()
        if openWindowId ~= myId then return end
        local okClose = pcall(function() hud:Close(myId) end)
        openWindowId = nil
        Log(string.format("[probe-browser] auto-close: ok=%s", tostring(okClose)))
    end)

    -- Push returning an id says the call went through, not that a widget was
    -- built. Counting instances of the class just pushed separates "the stack
    -- refused this class" from "it is up but not visible".
    local short = path:match("([^.]+)$")
    local found = 0
    for _, w in ipairs(FindAllOf("PalUserWidgetBase") or {}) do
        if w:IsValid() and tostring(w:GetFullName()):find(short, 1, true) then
            found = found + 1
            local vis, inViewport = "?", "?"
            pcall(function() vis = tostring(w:GetVisibility()) end)
            pcall(function() inViewport = tostring(w:IsInViewport()) end)
            Log(string.format("[probe-browser]   instance %d: visibility=%s inViewport=%s",
                found, vis, inViewport))
        end
    end
    Log(string.format("[probe-browser] %d %s instance(s) alive", found, short))
end

-- Palworld ships the engine's web browser widget and the whole Chromium runtime
-- (Engine/Binaries/ThirdParty/CEF3/Win64). UWebBrowser offers LoadString,
-- ExecuteJavascript and OnConsoleMessage, which together would carry the
-- website's own tree view into the game: HTML in, config as JSON in, clicks
-- back out. Shipping builds regularly keep the class and drop the renderer, so
-- this is asked in stages, and each stage says what it found.
function M.probeWebBrowser()
    local cls = StaticFindObject("/Script/WebBrowserWidget.WebBrowser")
    if not cls or not cls:IsValid() then
        Log("[probe-web] UWebBrowser class not resident - browser widget unavailable")
        return
    end
    Log("[probe-web] stage 1: class found")

    -- Stage 2: can an instance be constructed at all. A widget needs an outer
    -- that lives in the UI world, so the player's HUD is used rather than the
    -- transient package.
    local outer = nil
    for _, o in ipairs(FindAllOf("PalHUDInGame") or {}) do
        local n = ""
        pcall(function() n = tostring(o:GetFullName()) end)
        if o:IsValid() and not n:find("Default__") then outer = o break end
    end
    if not outer then
        Log("[probe-web] no live PalHUDInGame to own the widget")
        return
    end

    local okNew, browser = pcall(function()
        return StaticConstructObject(cls, outer, FName("PalvolveWebView"))
    end)
    if not okNew or not browser or not browser:IsValid() then
        Log("[probe-web] stage 2 FAILED: construct raised " .. tostring(browser))
        return
    end
    Log("[probe-web] stage 2: instance constructed")

    -- Stage 3: does the renderer accept content. LoadString needs no file and
    -- no network, so a failure here is the renderer's and nothing else's.
    local html = "<html><body style='background:#c0392b;color:#fff;font:700 48px sans-serif'>PALVOLVE WEBVIEW</body></html>"
    local okLoad, errLoad = pcall(function() browser:LoadString(html, "palvolve://probe") end)
    Log(string.format("[probe-web] stage 3 LoadString: ok=%s%s", tostring(okLoad),
        okLoad and "" or (" err=" .. tostring(errLoad))))

    local okJs = pcall(function() browser:ExecuteJavascript("console.log('palvolve-webview-alive')") end)
    Log(string.format("[probe-web] stage 4 ExecuteJavascript: ok=%s", tostring(okJs)))

    -- A UWebBrowser is a UWidget, not a UUserWidget, so it cannot go to the
    -- viewport by itself. The game solves this in WBP_WebBrowser_News_C, the
    -- news panel on the title screen: a canvas panel with a browser in it, and
    -- that is a UUserWidget. Borrowing it skips building a widget tree by hand.
    M.probeWebView()
end

-- The address handed to LoadString decides the page's origin, and an origin
-- Chromium does not recognise gets no script rights: with palvolve:// the page
-- rendered and styled correctly while every line of JavaScript stayed dead.
-- An http origin is never fetched - nothing here goes to the network - it only
-- has to be one the engine accepts.
local VIEW_ORIGIN = "http://palvolve.local/view"
local NEWS_WIDGET = "/Game/Pal/Blueprint/UI/Title/WBP_WebBrowser_News.WBP_WebBrowser_News_C"
local webViewWidget = nil
local webViewBrowser = nil
local webViewPoll = nil

-- While the view is up the player must not be walking around behind it, and
-- the mouse has to belong to the page. UIOnly routes input to the widget and
-- nothing else; the cursor has to be turned on separately because the game
-- runs without one.
-- Focusing the outer user widget was enough to stop the page from seeing
-- clicks at all, while plain text selection had worked before any input mode
-- was set. So no widget is named here: the mode keeps the player from walking
-- around, and the focus is left where the browser can claim it.
local function grabInput(pc, widget)
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

local function closeWebView()
    local pc = FindFirstOf("PalPlayerController")
    if pc and pc:IsValid() then releaseInput(pc) end
    if webViewWidget and webViewWidget:IsValid() then
        pcall(function() webViewWidget:RemoveFromParent() end)
    end
    webViewWidget, webViewBrowser = nil, nil
    Log("[probe-web] view closed, input handed back to the game")
end

function M.probeWebView()
    if webViewWidget and webViewWidget:IsValid() then
        closeWebView()
        return
    end

    -- The class lives in the title screen's package and is not resident during
    -- play, so it has to be pulled in first.
    local cls = StaticFindObject(NEWS_WIDGET)
    if not cls or not cls:IsValid() then
        pcall(function() LoadAsset(NEWS_WIDGET) end)
        cls = StaticFindObject(NEWS_WIDGET)
    end
    if not cls or not cls:IsValid() then
        Log("[probe-web] stage 5 FAILED: " .. NEWS_WIDGET .. " could not be loaded")
        return
    end
    Log("[probe-web] stage 5: news widget class loaded")

    local pc = FindFirstOf("PalPlayerController")
    if not pc or not pc:IsValid() then
        Log("[probe-web] no player controller")
        return
    end

    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local okCreate, widget = pcall(function() return lib:Create(pc, cls, pc) end)
    if not okCreate or not widget or not widget:IsValid() then
        Log("[probe-web] stage 6 FAILED: create raised " .. tostring(widget))
        return
    end
    webViewWidget = widget
    Log("[probe-web] stage 6: widget created")

    pcall(function() widget:AddToViewport(50) end)
    grabInput(pc, widget)
    Log("[probe-web] stage 7: on screen, input taken over")

    local browser = nil
    for _, w in ipairs(FindAllOf("WebBrowser") or {}) do
        local n = ""
        pcall(function() n = tostring(w:GetFullName()) end)
        if w:IsValid() and not n:find("Default__") then browser = w end
    end
    if not browser then
        Log("[probe-web] stage 8: no WebBrowser instance inside the widget")
        return
    end
    webViewBrowser = browser

    -- The page comes from a file next to the user config, not from this script.
    -- A game restart costs minutes and UE4SS cannot reload Lua safely here, so
    -- keeping the markup outside means the view can be changed and reopened
    -- while the game keeps running. The shipped feature needs the same split.
    local htmlPath = os.getenv("LOCALAPPDATA") .. "\\Pal\\Saved\\Palvolve\\webview.html"
    local html = nil
    local f = io.open(htmlPath, "r")
    if f then
        html = f:read("*a")
        f:close()
        Log(string.format("[probe-web] page loaded from %s (%d bytes)", htmlPath, #html))
    else
        Log("[probe-web] no webview.html found, using the built-in page: " .. htmlPath)
    end

    html = html or [[<html><head><meta charset="utf-8"><style>
      body{margin:0;background:#12161f;color:#e8eaf0;font:16px/1.5 system-ui,sans-serif;
           display:flex;flex-direction:column;gap:14px;align-items:center;
           justify-content:center;height:100vh;user-select:none}
      h1{margin:0;font-size:28px;color:#59d1a0}
      button{font:600 18px system-ui,sans-serif;padding:12px 22px;border:0;border-radius:8px;
             background:#2b3446;color:#e8eaf0;cursor:pointer}
      button:hover{background:#3a4761}
      #log{font:13px ui-monospace,monospace;color:#8b93a7;min-height:20px}
    </style></head><body>
      <h1>Palvolve web view</h1>
      <button onclick="send('pick/Pengullet')">Pick Pengullet</button>
      <button onclick="send('evolve/Penking')">Evolve to Penking</button>
      <button onclick="send('close')">Close</button>
      <div id="log">no click yet</div>
      <iframe id="bus" style="display:none"></iframe>
    <script>
      // Navigating the page itself to an unknown scheme works as a signal but
      // replaces the page with Chromium's error screen. A hidden frame carries
      // the same address change while the page stays where it is. Whether the
      // outer GetUrl still sees it is exactly what this run measures, so the
      // counter number goes along and both routes are tried.
      var n = 0;
      function send(what){
        n++;
        document.getElementById('log').textContent = 'sent #' + n + ': ' + what;
        console.log('PALVOLVE:' + what);
        // Third route, and the only one that breaks nothing: the document
        // title is settable from JS and readable through GetTitleText. No
        // navigation, no error page, no delegate binding.
        document.title = 'PV|' + n + '|' + what;
        document.getElementById('bus').src = 'palvolve://' + what + '?n=' + n;
      }
    </script></body></html>]]
    local okLoad = pcall(function() browser:LoadString(html, VIEW_ORIGIN) end)
    Log(string.format("[probe-web] stage 8 LoadString: ok=%s", tostring(okLoad)))

    -- The widget is the title screen's news panel and fetches Pocketpair's news
    -- page a moment after it is shown, replacing whatever was loaded before.
    -- The page is therefore put back whenever the address drifts away from it.
    local function reassert()
        if not (webViewBrowser and webViewBrowser:IsValid()) then return end
        pcall(function() webViewBrowser:LoadString(html, VIEW_ORIGIN) end)
    end

    -- Fixed retries rather than a reaction to the address, so this works even
    -- when the watcher below fails. The news page arrives on its own schedule
    -- and has beaten every single attempt so far.
    for _, delay in ipairs({800, 2000, 4000, 7000}) do
        ExecuteWithDelay(delay, function()
            if webViewWidget then reassert() end
        end)
    end

    -- The way back. Binding the console or url delegates from Lua is fragile,
    -- so the address is polled instead: it needs no delegate, survives a
    -- reload and cannot be swamped by unrelated console output.
    local lastUrl, lastTitle = "", ""
    local reportedUrlError, reportedTitleError = false, false
    local beats = 0
    webViewPoll = LoopAsync(150, function()
        -- Unconditional sign of life. Silence used to mean either "nothing to
        -- report" or "this loop is dead", and those need opposite fixes.
        beats = beats + 1
        if beats % 20 == 0 then
            Log(string.format("[probe-web] watcher alive, %d checks, url='%s' title='%s'",
                beats, lastUrl, lastTitle))
        end
        if not (webViewBrowser and webViewBrowser:IsValid()) then return true end

        -- Both reads were wrapped in a bare pcall before, which turned a broken
        -- getter into an empty string and the watcher into a silent no-op. The
        -- first failure of each is reported once so the reason is on record.
        local url, title = "", ""
        local okUrl, errUrl = pcall(function() url = tostring(webViewBrowser:GetUrl():ToString()) end)
        local okTitle, errTitle = pcall(function() title = tostring(webViewBrowser:GetTitleText():ToString()) end)
        if not okUrl and not reportedUrlError then
            reportedUrlError = true
            Log("[probe-web] GetUrl unusable: " .. tostring(errUrl))
        end
        if not okTitle and not reportedTitleError then
            reportedTitleError = true
            Log("[probe-web] GetTitleText unusable: " .. tostring(errTitle))
        end

        local message = nil
        if title ~= lastTitle and title ~= "" then
            lastTitle = title
            if title:sub(1, 3) == "PV|" then
                Log("[probe-web] via title: " .. title)
                message = title
            end
        end
        if url ~= lastUrl and url ~= "" then
            lastUrl = url
            Log("[probe-web] via url: " .. url)
            message = message or url

            -- Anything that is not our own address means the widget went back
            -- to its news page, so the view is put back.
            if not url:find("palvolve://", 1, true) then
                Log("[probe-web] widget navigated away, restoring the view")
                reassert()
            end
        end

        if message and message:find("close", 1, true) then
            closeWebView()
            return true
        end
        return false
    end)
    -- Fires the page's own reporting path without a mouse. That splits two
    -- questions that otherwise hide each other: does the way back work at all,
    -- and does a click reach the page. A silent log after this means the route
    -- is broken; a log here but none on click means only the input is.
    ExecuteWithDelay(3000, function()
        if not (webViewBrowser and webViewBrowser:IsValid()) then return end
        pcall(function() webViewBrowser:ExecuteJavascript("send('selftest/no-mouse')") end)
        Log("[probe-web] self-test fired from lua, watch for a message below")
    end)

    -- Safety net. The view owns the input, so a page that fails to report a
    -- close would leave the player unable to move or reach the chat that opened
    -- it. This does not depend on the page working at all.
    local generation = widget
    ExecuteWithDelay(90000, function()
        if webViewWidget == generation then
            Log("[probe-web] safety timeout reached")
            closeWebView()
        end
    end)

    Log("[probe-web] stage 9: watching the page for messages - click the buttons (closes itself after 90s)")
end

-- The positive control. WorldMap is one of the game's own stack screens, so if
-- this opens, a mod can drive the UI stack and the empty frame above simply had
-- no content to give it size. If this does nothing either, the stack is not
-- reachable from Lua and the assetless browser is off the table.
function M.probeBrowserStack()
    M.probeHudObjects()

    local hud, via = hudService()
    if not hud then
        Log("[probe-browser] no PalHUDService in this world")
        return
    end

    local okShow, result = pcall(function() return hud:ShowCommonUI(3, nil) end)
    Log(string.format("[probe-browser] ShowCommonUI(WorldMap) via %s: ok=%s result=%s",
        via, tostring(okShow), tostring(result)))

    -- PalHUDInGame is the player's own HUD actor and owns the in-world stack.
    -- Trying it as well separates "the service object was wrong" from "this
    -- entry point does not build widgets at all".
    local inGame = nil
    for _, o in ipairs(FindAllOf("PalHUDInGame") or {}) do
        local name = ""
        pcall(function() name = tostring(o:GetFullName()) end)
        if o:IsValid() and not name:find("Default__") then inGame = o break end
    end
    if not inGame then
        Log("[probe-browser] no live PalHUDInGame")
        return
    end

    local cls = StaticFindObject(BROWSER_FRAME)
    local okPush, res = pcall(function() return inGame:PushWidgetStackableUI(cls, nil) end)
    Log(string.format("[probe-browser] PalHUDInGame:PushWidgetStackableUI: ok=%s result=%s",
        tostring(okPush), tostring(res)))

    local alive = 0
    for _, w in ipairs(FindAllOf("PalUserWidgetBase") or {}) do
        if w:IsValid() and tostring(w:GetFullName()):find("PalCommonWindow") then alive = alive + 1 end
    end
    Log(string.format("[probe-browser] %d PalCommonWindow instance(s) after both attempts", alive))
end


Log(string.format("Probes active: F3 revert(own), F4 arm radial probes, F5 overlay, F6 VFX, F7 morph FX bases, F8 fanfare, F9 freeze, F10 give EXP, END free mode, test kit on %s, conditions on HOME/PAGE_UP/PAGE_DOWN, NUM7 day/night, NUM8 status cycle, F1 finale assets, BACKSPACE full evolution run (random target, 12 stages), chat !palvolve free|kit|fx|worksuit|xnet; weather recorder writes [weather] lines on every change",
    Key.INS and "INSERT" or "POS1"))

-- ---------------------------------------------------------------------------
-- Can Lua build the in-game tree, or does every node have to come from a pak?
--
-- The plan for 1.6.0 is a window showing the arrangement the author built. What
-- it costs depends on one thing: whether Lua can put widgets on a canvas at
-- coordinates it chooses. If it can, the pak only has to supply one empty shell
-- and every node, position and update stays in Lua, where it can be changed
-- without the modding kit. If it cannot, every node is Blueprint work.
--
-- Asked in stages, and each stage says what it found, because a failure four
-- steps in means something different from a failure at step one.
--   1 UImage can be constructed at all
--   2 a CanvasPanel takes it as a child and hands back a slot
--   3 the slot accepts a position and a size
--   4 a pal's own icon texture loads and lands in the image
--   5 the whole thing survives 300 nodes, and what that costs in milliseconds
-- ---------------------------------------------------------------------------

local canvasProbeWidget = nil

local function firstLive(className)
    for _, o in ipairs(FindAllOf(className) or {}) do
        local n = ""
        pcall(function() n = tostring(o:GetFullName()) end)
        if o:IsValid() and not n:find("Default__") then return o end
    end
    return nil
end

--- The icon texture Palworld uses for a species, straight from its own table.
--- Returns nil when the path does not resolve, which is the answer for a pal
--- the game does not ship an icon for.
local function palIconTexture(charId)
    local path = string.format(
        "/Game/Pal/Texture/PalIcon/Normal/T_%s_icon_normal.T_%s_icon_normal", charId, charId)
    local tex = nil
    pcall(function() tex = StaticFindObject(path) end)
    if not (tex and tex:IsValid()) then
        pcall(function() LoadAsset(path) end)
        pcall(function() tex = StaticFindObject(path) end)
    end
    if tex and tex:IsValid() then return tex end
    return nil
end

function M.probeCanvas()
    if canvasProbeWidget and canvasProbeWidget:IsValid() then
        pcall(function() canvasProbeWidget:RemoveFromParent() end)
        canvasProbeWidget = nil
        Log("[probe-canvas] closed")
        return
    end

    local pc = FindFirstOf("PalPlayerController")
    if not (pc and pc:IsValid()) then
        Log("[probe-canvas] no player controller")
        return
    end

    -- Stage 1: a UserWidget to own the canvas. UUserWidget is what AddToViewport
    -- takes, and a bare one is enough here: the canvas goes in by hand.
    local userCls = StaticFindObject("/Script/UMG.UserWidget")
    local canvasCls = StaticFindObject("/Script/UMG.CanvasPanel")
    local imageCls = StaticFindObject("/Script/UMG.Image")
    Log(string.format("[probe-canvas] stage 1 classes: UserWidget=%s CanvasPanel=%s Image=%s",
        tostring(userCls and userCls:IsValid()),
        tostring(canvasCls and canvasCls:IsValid()),
        tostring(imageCls and imageCls:IsValid())))
    if not (userCls and canvasCls and imageCls) then
        Log("[probe-canvas] stage 1 FAILED: a UMG class is not resident")
        return
    end

    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local okRoot, root = pcall(function() return lib:Create(pc, userCls, pc) end)
    if not (okRoot and root and root:IsValid()) then
        Log("[probe-canvas] stage 1 FAILED: Create returned " .. tostring(root))
        return
    end
    Log("[probe-canvas] stage 1: root widget created")

    -- Stage 2: a canvas under it, and a child on the canvas. AddChildToCanvas is
    -- the call that decides the whole architecture.
    local outer = firstLive("PalHUDInGame") or pc
    local okCanvas, canvas = pcall(function()
        return StaticConstructObject(canvasCls, outer, FName("PalvolveProbeCanvas"))
    end)
    if not (okCanvas and canvas and canvas:IsValid()) then
        Log("[probe-canvas] stage 2 FAILED: canvas construct raised " .. tostring(canvas))
        return
    end

    local okImg, img = pcall(function()
        return StaticConstructObject(imageCls, outer, FName("PalvolveProbeImage"))
    end)
    if not (okImg and img and img:IsValid()) then
        Log("[probe-canvas] stage 2 FAILED: image construct raised " .. tostring(img))
        return
    end

    local slot = nil
    local okSlot = pcall(function() slot = canvas:AddChildToCanvas(img) end)
    Log(string.format("[probe-canvas] stage 2: AddChildToCanvas ok=%s slot=%s",
        tostring(okSlot), tostring(slot and slot:IsValid())))
    if not (okSlot and slot and slot:IsValid()) then
        Log("[probe-canvas] stage 2 FAILED - nodes would have to come from a pak")
        return
    end

    -- Stage 3: the slot decides where a node sits, which is the whole point.
    local okPos = pcall(function()
        slot:SetAutoSize(false)
        slot:SetPosition({ X = 120.0, Y = 80.0 })
        slot:SetSize({ X = 64.0, Y = 64.0 })
    end)
    Log("[probe-canvas] stage 3: slot position and size ok=" .. tostring(okPos))

    -- Stage 4: the game's own icon for a pal, so nodes need no shipped art.
    local tex = palIconTexture("SheepBall")
    if tex then
        local okBrush = pcall(function() img:SetBrushFromTexture(tex, true) end)
        Log("[probe-canvas] stage 4: Lamball icon loaded, SetBrushFromTexture ok=" .. tostring(okBrush))
    else
        Log("[probe-canvas] stage 4: no icon texture at the guessed path - needs the icon table")
    end

    -- Getting it on screen is the one thing left. AddToViewport belongs to
    -- UserWidget; a CanvasPanel is a plain widget and has no such call, which is
    -- why the first run drew nothing. The canvas has to sit INSIDE the user
    -- widget's tree, and a bare UserWidget arrives without one.
    local okShow = pcall(function() root:AddToViewport(50) end)
    Log("[probe-canvas] root on screen: " .. tostring(okShow))

    local tree = nil
    pcall(function() tree = root.WidgetTree end)
    Log("[probe-canvas] stage 6: WidgetTree present = " .. tostring(tree and tree:IsValid()))

    -- Way 1: the tree is there and its root can be pointed at our canvas.
    local attached = false
    if tree and tree:IsValid() then
        local before = "nil"
        pcall(function() before = tostring(tree.RootWidget:GetFullName()) end)
        local okSet = pcall(function() tree.RootWidget = canvas end)
        local after = "nil"
        pcall(function() after = tostring(tree.RootWidget:GetFullName()) end)
        attached = okSet and after:find("PalvolveProbeCanvas") ~= nil
        Log(string.format("[probe-canvas] way 1 (tree.RootWidget): set=%s before=%s after=%s -> %s",
            tostring(okSet), before, after, tostring(attached)))
    end

    -- Way 2: build a WidgetTree ourselves and hang it on the widget. Needed when
    -- a widget created without a Blueprint arrives with no tree at all.
    if not attached then
        local treeCls = StaticFindObject("/Script/UMG.WidgetTree")
        if treeCls and treeCls:IsValid() then
            local okTree = pcall(function()
                local t = StaticConstructObject(treeCls, root, FName("PalvolveProbeTree"))
                t.RootWidget = canvas
                root.WidgetTree = t
            end)
            local after = "nil"
            pcall(function() after = tostring(root.WidgetTree.RootWidget:GetFullName()) end)
            attached = okTree and after:find("PalvolveProbeCanvas") ~= nil
            Log(string.format("[probe-canvas] way 2 (own WidgetTree): built=%s root=%s -> %s",
                tostring(okTree), after, tostring(attached)))
        else
            Log("[probe-canvas] way 2 skipped: WidgetTree class not resident")
        end
    end

    -- Way 3: skip the canvas and hand each node to the viewport on its own.
    -- UWidgetLayoutLibrary positions a widget in screen space, which is all a
    -- node needs. Slower per node, but it needs nothing from a pak at all.
    if not attached then
        local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        Log("[probe-canvas] way 3: WidgetLayoutLibrary = " .. tostring(layout and layout:IsValid()))
    end

    -- A widget already on screen does not pick up a tree swapped in underneath
    -- it, so it goes on the viewport after the attach, not before.
    if attached then
        pcall(function() root:RemoveFromParent() end)
        local okAgain = pcall(function() root:AddToViewport(50) end)
        Log("[probe-canvas] re-added after attaching: " .. tostring(okAgain)
            .. " - if a Lamball icon is on screen now, no pak is needed for the nodes")
    end

    -- Stage 5: 300 nodes is what a real tree costs. Time it, because a second
    -- of hitching when the window opens is a different feature than a frame.
    local started = os.clock()
    local made, failed = 0, 0
    for i = 1, 300 do
        local okN = pcall(function()
            local n = StaticConstructObject(imageCls, outer, FName("PalvolveProbeNode" .. i))
            local s = canvas:AddChildToCanvas(n)
            s:SetAutoSize(false)
            s:SetPosition({ X = (i % 30) * 44.0, Y = math.floor(i / 30) * 44.0 })
            s:SetSize({ X = 40.0, Y = 40.0 })
            if tex then n:SetBrushFromTexture(tex, true) end
        end)
        if okN then made = made + 1 else failed = failed + 1 end
    end
    Log(string.format("[probe-canvas] stage 5: %d nodes built, %d failed, %.0f ms",
        made, failed, (os.clock() - started) * 1000))

    canvasProbeWidget = canvas
    Log("[probe-canvas] run the command again to close")
end

-- ---------------------------------------------------------------------------
-- Can a click come back out of the browser without JavaScript?
--
-- The earlier run tried three routes - onclick, document.title, an iframe src -
-- and every one of them is JavaScript, which is dead in this widget. So all
-- three failing said nothing about the browser and everything about JS.
--
-- A plain <a href> is different: CEF follows it itself, no script involved. If
-- the address the widget reports changes to what the link said, that is a click
-- channel, and with it the whole window can be HTML: draw the page, read the
-- click, draw the next page. The game becomes the server for its own UI.
--
-- Unknown schemes usually land on Chromium's error page, so the page is put
-- back after every read. That is the same reassert the news-page hijack needed.
-- ---------------------------------------------------------------------------

local linkBrowser = nil
local linkStop = false
local linkSeen = {}

local LINK_ORIGIN = "http://palvolve.local/tree"

local LINK_HTML = [[<!doctype html><html><head><meta charset="utf-8">
<style>
  body{margin:0;background:#1b2430;color:#eaf0f7;font:15px/1.5 system-ui,sans-serif;padding:24px}
  h1{font-size:18px;margin:0 0 14px}
  a{display:inline-block;margin:0 10px 10px 0;padding:10px 16px;border-radius:8px;
    background:#2c3d51;color:#eaf0f7;text-decoration:none;border:1px solid #3f5266}
  a:hover{background:#3a4e66;border-color:#f0c24a}
  p{color:#9fb0c3;font-size:13px}
</style></head><body>
  <h1>Click a link. No script on this page.</h1>
  <a href="palvolve://select/SheepBall">Lamball</a>
  <a href="palvolve://select/Penguin">Pengullet</a>
  <a href="http://palvolve.local/tree?pick=Mau">Mau (same scheme)</a>
  <a href="/tree?pick=Relative">relative link</a>
  <p>Every one of these is a plain anchor. If the address the mod reads changes,
     the window can be HTML and still answer a click.</p>
</body></html>]]

function M.probeLinkClick()
    if linkBrowser and linkBrowser:IsValid() then
        linkStop = true
        local pc = FindFirstOf("PalPlayerController")
        if pc and pc:IsValid() then releaseInput(pc) end
        if webViewWidget and webViewWidget:IsValid() then
            pcall(function() webViewWidget:RemoveFromParent() end)
        end
        webViewWidget, linkBrowser = nil, nil
        Log("[probe-link] closed")
        return
    end

    local pc = FindFirstOf("PalPlayerController")
    if not (pc and pc:IsValid()) then
        Log("[probe-link] no player controller")
        return
    end

    -- The route that is known to render. Constructing a bare UWebBrowser gives
    -- an object whose CEF renderer never starts, which is a spinner and nothing
    -- else; the news widget brings a browser that is already alive.
    pcall(function() LoadAsset(NEWS_WIDGET) end)
    local cls = StaticFindObject(NEWS_WIDGET)
    if not (cls and cls:IsValid()) then
        Log("[probe-link] news widget class did not load")
        return
    end

    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local widget = nil
    pcall(function() widget = lib:Create(pc, cls, pc) end)
    if not (widget and widget:IsValid()) then
        Log("[probe-link] could not create the news widget")
        return
    end
    pcall(function() widget:AddToViewport(70) end)

    -- The browser lives inside that widget; it is picked up after the widget
    -- exists, skipping the class default object.
    local browser = nil
    for _, b in ipairs(FindAllOf("WebBrowser") or {}) do
        local n = ""
        pcall(function() n = tostring(b:GetFullName()) end)
        if b:IsValid() and not n:find("Default__") then browser = b end
    end
    if not (browser and browser:IsValid()) then
        Log("[probe-link] no live WebBrowser inside the widget")
        pcall(function() widget:RemoveFromParent() end)
        return
    end

    webViewWidget, linkBrowser = widget, browser
    pcall(function() linkBrowser:LoadString(LINK_HTML, LINK_ORIGIN) end)
    grabInput(pc)
    Log("[probe-link] open - click a link, then run the command again to close")

    -- Every tick is reported for the first few seconds. Logging only on change
    -- made an empty address indistinguishable from a dead loop, which is what
    -- the first run actually measured.
    linkStop = false
    local last, ticks = nil, 0
    LoopAsync(250, function()
        if linkStop or not (linkBrowser and linkBrowser:IsValid()) then
            Log("[probe-link] watcher done after " .. ticks .. " ticks")
            return true
        end
        ticks = ticks + 1
        local url, title = "", ""
        pcall(function() url = tostring(linkBrowser:GetUrl():ToString()) end)
        pcall(function() title = tostring(linkBrowser:GetTitleText():ToString()) end)

        if ticks <= 8 or url ~= last then
            Log(string.format("[probe-link] tick %d url=[%s] title=[%s]", ticks, url, title))
        end
        if url ~= last then
            last = url
            local pick = url:match("select/([%w_]+)") or url:match("pick=([%w_]+)")
            if pick and not linkSeen[pick] then
                linkSeen[pick] = true
                Log("[probe-link] CLICK RECEIVED: " .. pick
                    .. " - a plain link answers, the window can be HTML")
            end
            -- an unknown scheme leaves an error page behind, so the page goes back
            if url ~= "" and not url:find("palvolve.local", 1, true) then
                pcall(function() linkBrowser:LoadString(LINK_HTML, LINK_ORIGIN) end)
            end
        end

        -- the news widget fetches Pocketpair's page a moment after it appears
        if ticks == 6 or ticks == 14 or ticks == 30 then
            pcall(function() linkBrowser:LoadString(LINK_HTML, LINK_ORIGIN) end)
        end
        if ticks > 480 then
            Log("[probe-link] watcher stopped after two minutes")
            return true
        end
        return false
    end)
end

-- ---------------------------------------------------------------------------
-- [probe-pak] Does the cooked pak reach the game, and does a click come back?
--
-- Every earlier attempt built the window out of bare UMG classes and could not
-- receive a click, because Lua has no way to bind a delegate: OnClicked wants a
-- UObject with a reflected UFunction, and a Lua closure is neither.
--
-- The pak carries two authored widgets instead. WBP_PalvolveTree is the window
-- with a named ListRoot and GraphRoot; WBP_PalvolveNode is one card, and its
-- button sets the card's own Clicked flag in Blueprint. Lua reads that flag,
-- which is an ordinary property read and needs no delegate at all.
--
-- Asked in stages so a failure names its half: classes missing means the pak is
-- not mounting, a window without ListRoot means Is Variable is off, and a card
-- that never reports means the Blueprint wiring.
-- ---------------------------------------------------------------------------

local TREE_PKG, TREE_ASSET = "/Game/Palvolve/WBP_PalvolveTree", "WBP_PalvolveTree_C"
local NODE_PKG, NODE_ASSET = "/Game/Palvolve/WBP_PalvolveNode", "WBP_PalvolveNode_C"

local pakWindow = nil
local pakCards = {}
local pakStop = false

local function addName(s)
    local n = FName(s, EFindName.FNAME_Find)
    if n == NAME_None then n = FName(s, EFindName.FNAME_Add) end
    return n
end

--- Loads a class out of a mod pak.
---
--- Not through UE4SS's LoadAsset: that one asks the asset registry for the
--- path, and the registry is built when the game is cooked, so it has never
--- heard of anything a mod pak brings along - the call comes back empty even
--- though the pak is mounted and the file is right there.
---
--- The way the BP mod loader does it works instead: hand FAssetData that was
--- filled in by hand to the registry helper, which loads the package by name
--- rather than looking it up. UE 5.1 wants the package and the asset apart.
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

local function palIcon(id)
    local path = string.format(
        "/Game/Pal/Texture/PalIcon/Normal/T_%s_icon_normal.T_%s_icon_normal", id, id)
    local tex = nil
    pcall(function() tex = StaticFindObject(path) end)
    if not (tex and tex:IsValid()) then
        pcall(function() LoadAsset(path) end)
        pcall(function() tex = StaticFindObject(path) end)
    end
    return (tex and tex:IsValid()) and tex or nil
end

function M.probePak()
    if pakWindow and pakWindow:IsValid() then
        pakStop = true
        local pc = FindFirstOf("PalPlayerController")
        if pc and pc:IsValid() then releaseInput(pc) end
        pcall(function() pakWindow:RemoveFromParent() end)
        pakWindow, pakCards = nil, {}
        Log("[probe-pak] closed")
        return
    end

    local treeCls, how1 = loadClass(TREE_PKG, TREE_ASSET)
    local nodeCls, how2 = loadClass(NODE_PKG, NODE_ASSET)
    Log(string.format("[probe-pak] stage 1 classes: tree=%s (%s) node=%s (%s)",
        tostring(treeCls ~= nil), how1, tostring(nodeCls ~= nil), how2))
    if not (treeCls and nodeCls) then
        Log("[probe-pak] stage 1 FAILED - the pak is not reaching the game")
        return
    end

    local pc = FindFirstOf("PalPlayerController")
    if not (pc and pc:IsValid()) then
        Log("[probe-pak] no player controller")
        return
    end

    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local win = nil
    pcall(function() win = lib:Create(pc, treeCls, pc) end)
    if not (win and win:IsValid()) then
        Log("[probe-pak] stage 2 FAILED: the window did not build")
        return
    end

    local listRoot, graphRoot = nil, nil
    pcall(function() listRoot = win.ListRoot end)
    pcall(function() graphRoot = win.GraphRoot end)
    Log(string.format("[probe-pak] stage 2 panels: ListRoot=%s GraphRoot=%s",
        tostring(listRoot and listRoot:IsValid()),
        tostring(graphRoot and graphRoot:IsValid())))
    if not (listRoot and listRoot:IsValid()) then
        Log("[probe-pak] stage 2 FAILED - Is Variable is probably off on ListRoot")
        return
    end

    pcall(function() win:AddToViewport(60) end)
    pakWindow = win

    -- Stage 3: real Pals from the loaded tree, through the same model the Lua
    -- window reads, so the pak never grows its own copy of the rules.
    local ids = {}
    local okView, view = pcall(require, "treeview")
    if okView and view and view.listedPals then
        local okIds, got = pcall(view.listedPals)
        if okIds and got then ids = got end
    end

    local built = 0
    for i = 1, math.min(#ids, 16) do
        local id = ids[i]
        local card = nil
        pcall(function() card = lib:Create(pc, nodeCls, pc) end)
        if card and card:IsValid() then
            pcall(function() card.PalId = id end)
            local tex = palIcon(id)
            if tex then pcall(function() card.Icon:SetBrushFromTexture(tex, false) end) end
            pcall(function()
                local ktl = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
                local name = (view and view.palName) and view.palName(id) or id
                if ktl and ktl:IsValid() then card.Label:SetText(ktl:Conv_StringToText(name)) end
            end)
            pcall(function() listRoot:AddChild(card) end)
            table.insert(pakCards, { id = id, widget = card })
            built = built + 1
        end
    end
    Log(string.format("[probe-pak] stage 3 cards: %d of %d Pals with a path", built, #ids))

    grabInput(pc)

    -- Stage 4: the relay. The Blueprint raises Clicked on the card that was
    -- pressed, this lowers it again and reports which Pal it was.
    pakStop = false
    local ticks = 0
    LoopAsync(200, function()
        if pakStop or not (pakWindow and pakWindow:IsValid()) then
            Log("[probe-pak] watcher done after " .. ticks .. " ticks")
            return true
        end
        ticks = ticks + 1
        for _, c in ipairs(pakCards) do
            if c.widget and c.widget:IsValid() then
                local clicked = false
                pcall(function() clicked = c.widget.Clicked end)
                if clicked then
                    pcall(function() c.widget.Clicked = false end)
                    Log("[probe-pak] CLICK: " .. c.id .. " - the relay works")
                end
            end
        end
        if ticks > 1800 then
            Log("[probe-pak] watcher stopped after six minutes")
            return true
        end
        return false
    end)

    Log("[probe-pak] open - click a card, run !palvolve pak again to close")
end

return M
