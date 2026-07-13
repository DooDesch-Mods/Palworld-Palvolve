-- Palvolve dev probes (devMode only, never packaged for release).
-- Live-verifies the open items from Workspace/docs/Palvolve/RESEARCH.md.
-- Markers: [probe-pallevelup] [probe-expdb] [probe-speciesswap] [probe-vfx]
--          [probe-overlay] [probe-ake] [probe-freeze] [probe-giveexp]
--          [probe-testkit] [probe-revert]
--
-- Keybinds (test world "ModDev", own pal summoned):
--   F5 = overlay glow on/off (M_Glow)     F6 = cycle visual effects
--   F7 = species swap probe (test world ONLY!)
--   F8 = fanfare (AKE_CampLevelUp)        F9 = freeze/unfreeze nearest pal
--   F10 = EXP to pals around (triggers the level-up hook)
--   F3 = revert own evolved pals          INSERT (fallback F4) = test kit
--
local M = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- UE4SS keybinds fire twice (~35ms apart, observed live) -> debounce.
local lastFire = {}
local function Debounced(name, fn)
    return function()
        local now = os.clock()
        if lastFire[name] and (now - lastFire[name]) < 0.5 then return end
        lastFire[name] = now
        fn()
    end
end

-- ---------------------------------------------------------------- load-time hooks

-- Probe 1: does the BP level-up handler fire? (UTF-8 function name with a
-- Japanese "event" suffix.) The BP is not loaded during Lua init -> retry
-- until the class exists (at the latest once the first pal spawns).
local levelHookRegistered = false
local function tryRegisterLevelHook()
    if levelHookRegistered then return true end
    local ok, err = pcall(RegisterHook,
        "/Game/Pal/Blueprint/Character/Monster/BP_MonsterBase.BP_MonsterBase_C:OnUpdateLevelDelegate_イベント_0",
        function(self, addLevel, nowLevel)
            local suc, e = pcall(function()
                local actor = self:get()
                local param = actor.CharacterParameterComponent:GetIndividualParameter()
                Log(string.format("[probe-pallevelup] id=%s addLevel=%d nowLevel=%d ownedGuidA=%s",
                    param:GetCharacterID():ToString(), addLevel:get(), nowLevel:get(),
                    tostring(param.SaveParameter.OwnerPlayerUId.A)))
            end)
            if not suc then Log("[probe-pallevelup] handler FAIL: " .. tostring(e)) end
        end)
    if ok then
        levelHookRegistered = true
        Log("[probe-pallevelup] hook registered ok=true")
    end
    return ok, err
end

local okNow, errNow = tryRegisterLevelHook()
if not okNow then
    Log(string.format("[probe-pallevelup] immediate registration failed (%s) - retrying every 5s", tostring(errNow)))
    LoopAsync(5000, function()
        if levelHookRegistered then return true end
        ExecuteInGameThread(function()
            tryRegisterLevelHook()
        end)
        return levelHookRegistered
    end)
end

-- Probe 2: do the PalExpDatabase UFunctions go through ProcessEvent?
for _, fn in ipairs({
    "/Script/Pal.PalExpDatabase:AddExpValue_forPlayerParty_Server",
    "/Script/Pal.PalExpDatabase:AddExp_forPlayerParty_ByExpCalcType",
    "/Script/Pal.PalExpDatabase:AddExp_EnemyDeath",
}) do
    local hooked = pcall(RegisterHook, fn, function()
        Log("[probe-expdb] fired " .. fn)
    end)
    Log("[probe-expdb] hook " .. fn .. " ok=" .. tostring(hooked))
end

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
            ExecuteWithDelay(2000, function()
                ExecuteInGameThread(function()
                    if pal:IsValid() and mesh:IsValid() then
                        mesh:SetOverlayMaterial(nil)
                        Log("[probe-overlay] restored")
                    end
                end)
            end)
            Log("[probe-overlay] set on " .. pal:GetFullName())
        end)
        if not suc then Log("[probe-overlay] FAIL: " .. tostring(e)) end
    end)
end))

-- F6: cycle through the game's own visual effects - each press plays the next.
-- Finding: 1=CaptureEmissive glows white and makes the pal VANISH (capture look)
-- = perfect phase 1 of the evolution; 2=SpawnFromBallEmissive is the appear side.
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

-- F7: raw species swap probe across several pairs (test world ONLY!)
-- The model does NOT rebuild immediately - only the next summon/box roundtrip
-- spawns the actor as the new species (verified live).
local SWAP_PAIRS = {
    { from = "Penguin", to = "CaptainPenguin" },  -- Pengullet -> Penking
    { from = "MopBaby", to = "MopKing" },         -- Swee -> Sweepa
    { from = "MopKing", to = "Yeti" },            -- Sweepa -> Wumpo (fun chain)
}
RegisterKeyBind(Key.F7, Debounced("speciesswap", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local all = FindAllOf("PalIndividualCharacterParameter") or {}
            for _, pair in ipairs(SWAP_PAIRS) do
                for _, p in ipairs(all) do
                    if p:IsValid() and p:GetCharacterID():ToString() == pair.from then
                        local hpBefore = p:GetMaxHP()
                        p.SaveParameter.CharacterID = FName(pair.to)
                        p.SaveParameterMirror.CharacterID = FName(pair.to)
                        Log(string.format("[probe-speciesswap] %s -> %s, MaxHP %s -> %s (box roundtrip/resummon for the model)",
                            pair.from, p:GetCharacterID():ToString(), tostring(hpBefore), tostring(p:GetMaxHP())))
                        return
                    end
                end
            end
            -- diagnostics: which species are in memory at all?
            local seen, list = {}, {}
            for _, p in ipairs(all) do
                if p:IsValid() then
                    local id = p:GetCharacterID():ToString()
                    if id ~= "" and id ~= "None" and not seen[id] then
                        seen[id] = true
                        table.insert(list, id)
                        if #list >= 15 then break end
                    end
                end
            end
            Log("[probe-speciesswap] no swap candidate; species in memory: " .. table.concat(list, ", "))
        end)
        if not suc then Log("[probe-speciesswap] FAIL: " .. tostring(e)) end
    end)
end))

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

local KIT_KEY = Key.INS or Key.F4
RegisterKeyBind(KIT_KEY, Debounced("testkit", function()
    ExecuteInGameThread(function()
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
    end)
end))

-- F10: EXP lever to trigger level-ups reproducibly
RegisterKeyBind(Key.F10, Debounced("giveexp", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local player = FindFirstOf("PalPlayerCharacter")
            if not player or not player:IsValid() then Log("[probe-giveexp] no player") return end
            local util = StaticFindObject("/Script/Pal.Default__PalUtility")
            -- GiveExpToAroundPlayerCharacter only hits PLAYERS (verified live) ->
            -- GiveExpToAroundCharacter with CharacterClass=PalCharacter for pals
            -- (dump :64555: WorldContext, Center, Radius, Exp, CharacterClass, bCallDelegate)
            local center = player:K2_GetActorLocation()
            local palClass = StaticFindObject("/Script/Pal.PalCharacter")
            util:GiveExpToAroundCharacter(player, center, 3000.0, 50000.0, palClass, true)
            Log("[probe-giveexp] 50000 EXP given to pals around")
        end)
        if not suc then Log("[probe-giveexp] FAIL: " .. tostring(e)) end
    end)
end))

-- Radial menu dispatch probes ([probe-radial], wave E stage R1): log which
-- native functions fire while the hold-4 wheel is used, to map entries to
-- hook points. The comment in the log carries nowSelectedIndex when readable.
pcall(function()
    local function idx(self)
        local i = "?"
        pcall(function() i = tostring(self:get().nowSelectedIndex) end)
        return i
    end
    RegisterHook("/Script/Pal.PalUIPlayerRadialMenuBase:OpenOtomoFeedInventory", function(self)
        Log("[probe-radial] OpenOtomoFeedInventory fired")
    end)
    RegisterHook("/Script/Pal.PalUIPlayerRadialMenuBase:SelectedFeed", function(self, ItemSlotId, itemNum)
        Log("[probe-radial] SelectedFeed fired")
    end)
    RegisterHook("/Script/Pal.PalUIPlayerRadialMenuBase:LaunchPhotoMode", function(self)
        Log("[probe-radial] LaunchPhotoMode fired")
    end)
    RegisterHook("/Script/Pal.PalUIRadialMenuWidgetBase:SetSelectedIndexForce", function(self, Index)
        Log(string.format("[probe-radial] SetSelectedIndexForce idx=%s now=%s",
            tostring(Index:get()), idx(self)))
    end)
    RegisterHook("/Script/Pal.PalUIRadialMenuWidgetBase:ClearSelectedIndex", function(self)
        Log(string.format("[probe-radial] ClearSelectedIndex now=%s", idx(self)))
    end)
    RegisterHook("/Script/Pal.PalOtomoHolderComponentBase:RequestSetOtomoOrder", function(self, OrderType)
        Log(string.format("[probe-radial] RequestSetOtomoOrder order=%s", tostring(OrderType:get())))
    end)
end)

Log(string.format("Probes active: F3 revert(own), F5 overlay, F6 VFX, F7 species swap, F8 fanfare, F9 freeze, F10 give EXP, radial probes, test kit on %s",
    Key.INS and "INSERT" or "F4"))

return M
