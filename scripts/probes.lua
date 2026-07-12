-- Palvolve Dev-Proben (temporaer, vor Release loeschen).
-- Verifiziert die offenen Punkte aus Workspace/docs/Palvolve/RESEARCH.md live im Spiel.
-- Marker: [probe-pallevelup] [probe-expdb] [probe-speciesswap] [probe-vfx]
--         [probe-overlay] [probe-ake] [probe-freeze] [probe-giveexp] [probe-testkit]
--
-- Keybinds (Testwelt "ModDev", eigenen Pal aussummonen):
--   F5 = Overlay-Glow an/aus (M_Glow)      F6 = AddVisualEffect CaptureEmissive
--   F7 = Species-Swap Penguin->CaptainPenguin (NUR Testwelt!)
--   F8 = Fanfare (AKE_CampLevelUp)         F9 = Freeze/Unfreeze naechster Pal
--   F10 = EXP an Pals im Umkreis (loest Level-Hook aus)
--   EINFG (Fallback F4) = Test-Kit: Sphaeren + Test-Pals (Eskalationskette mit Log)

local M = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- UE4SS-Keybinds feuern doppelt (~35 ms Abstand, live beobachtet) -> Entprellung.
local lastFire = {}
local function Debounced(name, fn)
    return function()
        local now = os.clock()
        if lastFire[name] and (now - lastFire[name]) < 0.5 then return end
        lastFire[name] = now
        fn()
    end
end

-- ---------------------------------------------------------------- Hooks beim Laden

-- Probe 1: feuert der BP-Level-Up-Handler? (UTF-8-Funktionsname mit japanischem "Event")
-- Der BP ist beim Lua-Init noch nicht geladen -> Registrierung mit Retry, bis die
-- Klasse existiert (spaetestens sobald der erste Pal in der Welt gespawnt ist).
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
    Log(string.format("[probe-pallevelup] Sofort-Registrierung fehlgeschlagen (%s) - Retry alle 5 s", tostring(errNow)))
    LoopAsync(5000, function()
        if levelHookRegistered then return true end
        ExecuteInGameThread(function()
            tryRegisterLevelHook()
        end)
        return levelHookRegistered
    end)
end

-- Probe 2: laufen die PalExpDatabase-UFunctions ueber ProcessEvent?
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

-- ---------------------------------------------------------------- Helfer

local function firstOwnedMonster()
    -- Bevorzugt den eigenen (Otomo-)Pal; sonst den erstbesten gespawnten Monster-Actor.
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

-- ---------------------------------------------------------------- Keybind-Proben

-- F5: Overlay-Fallback (M_Glow), Restore nach ~2 s
RegisterKeyBind(Key.F5, Debounced("overlay", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local pal = firstOwnedMonster()
            if not pal then Log("[probe-overlay] kein Pal gespawnt") return end
            local glow = StaticFindObject("/Game/Pal/Effect/Material/M_Glow.M_Glow")
            if not glow or not glow:IsValid() then Log("[probe-overlay] M_Glow nicht gefunden") return end
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
            Log("[probe-overlay] set auf " .. pal:GetFullName())
        end)
        if not suc then Log("[probe-overlay] FAIL: " .. tostring(e)) end
    end)
end))

-- F6: spiel-eigener Glow via PalVisualEffectComponent (CaptureEmissive=1)
RegisterKeyBind(Key.F6, Debounced("vfx", function()
    ExecuteInGameThread(function()
        local pal = firstOwnedMonster()
        if not pal then Log("[probe-vfx] kein Pal gespawnt") return end
        local suc, e = pcall(function()
            local fx = pal.VisualEffectComponent:AddVisualEffect(1, { FloatValues = {} })
            Log(string.format("[probe-vfx] AddVisualEffect -> %s",
                fx and fx:IsValid() and fx:GetFullName() or "nil/invalid"))
        end)
        if not suc then
            Log("[probe-vfx] AddVisualEffect FAIL: " .. tostring(e))
            local suc2, e2 = pcall(function()
                local fx = pal.VisualEffectComponent:AddVisualEffectForActor(pal, 2, { FloatValues = {} })
                Log(string.format("[probe-vfx] ForActor-Ausweich -> %s",
                    fx and fx:IsValid() and fx:GetFullName() or "nil/invalid"))
            end)
            if not suc2 then Log("[probe-vfx] ForActor FAIL: " .. tostring(e2)) end
        end
    end)
end))

-- F7: Species-Swap-Kernprobe Penguin -> CaptainPenguin (NUR in der Testwelt ausloesen!)
RegisterKeyBind(Key.F7, Debounced("speciesswap", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local all = FindAllOf("PalIndividualCharacterParameter") or {}
            for _, p in ipairs(all) do
                if p:IsValid() and p:GetCharacterID():ToString() == "Penguin" then
                    local hpBefore = p:GetMaxHP()
                    p.SaveParameter.CharacterID = FName("CaptainPenguin")
                    p.SaveParameterMirror.CharacterID = FName("CaptainPenguin")
                    local skin = FindFirstOf("PalPlayerSkinData")
                    if skin and skin:IsValid() then
                        skin:RequestRespawnPal(p)
                    else
                        Log("[probe-speciesswap] PalPlayerSkinData nicht gefunden (Respawn offen)")
                    end
                    Log(string.format("[probe-speciesswap] Penguin -> %s, MaxHP %s -> %s",
                        p:GetCharacterID():ToString(), tostring(hpBefore), tostring(p:GetMaxHP())))
                    return
                end
            end
            Log("[probe-speciesswap] kein Penguin im Speicher gefunden")
        end)
        if not suc then Log("[probe-speciesswap] FAIL: " .. tostring(e)) end
    end)
end))

-- F8: Fanfare via Wwise
RegisterKeyBind(Key.F8, Debounced("ake", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local pal = firstOwnedMonster()
            local ake = StaticFindObject("/Game/Pal/Sound/Events/SE/UI/CampLevelUp/AKE_CampLevelUp.AKE_CampLevelUp")
            local aks = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics")
            if not (ake and ake:IsValid()) then Log("[probe-ake] AKE_CampLevelUp nicht gefunden") return end
            if not (aks and aks:IsValid()) then Log("[probe-ake] AkGameplayStatics nicht gefunden") return end
            local id = aks:PostEvent(ake, pal, 0, nil, false)
            Log("[probe-ake] PostEvent id=" .. tostring(id))
        end)
        if not suc then Log("[probe-ake] FAIL: " .. tostring(e)) end
    end)
end))

-- F9: Freeze-Toggle (AI aus + Move-Lock)
local frozen = false
RegisterKeyBind(Key.F9, Debounced("freeze", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local pal = firstOwnedMonster()
            if not pal then Log("[probe-freeze] kein Pal gespawnt") return end
            frozen = not frozen
            local ctrl = pal:GetController()
            if ctrl and ctrl:IsValid() then ctrl:SetActiveAI(not frozen) end
            local util = StaticFindObject("/Script/Pal.Default__PalUtility")
            if util and util:IsValid() then
                util:SetMoveDisableFlag(pal, frozen, FName("EvoSeq"))
            end
            Log("[probe-freeze] frozen=" .. tostring(frozen) .. " auf " .. pal:GetName())
        end)
        if not suc then Log("[probe-freeze] FAIL: " .. tostring(e)) end
    end)
end))

-- Test-Kit (EINFG, Fallback F4): Eskalationskette, jeder Schritt loggt sein Ergebnis.
-- Befund 1. Versuch: RequestAddItem_ForDebug + Debug_Capture*_ToServer laufen fehlerfrei
-- durch, bewirken im Shipping-Build aber NICHTS (vermutlich Debug-Gate) -> jetzt die
-- autoritativen Wege mit Rueckgabewert-Auswertung.
local function giveItemsV2(inv)
    -- Autoritativer Weg (Single-Player = lokale Autoritaet): Result-Enum auswerten
    local ok, err = pcall(function()
        local ret1 = inv:AddItem_ServerInternal(FName("PalSphere"), 20, false, 0.0, true)
        local ret2 = inv:AddItem_ServerInternal(FName("PalSphere_Mega"), 10, false, 0.0, true)
        Log(string.format("[probe-testkit] AddItem_ServerInternal PalSphere=%s Mega=%s",
            tostring(ret1), tostring(ret2)))
    end)
    if not ok then Log("[probe-testkit] AddItem_ServerInternal FAIL: " .. tostring(err)) end
end

local function getCheatManager(pc)
    local cm = pc.CheatManager
    if cm and cm:IsValid() then return cm end
    -- Shipping erzeugt den CheatManager erst nach EnableCheats
    pcall(function() pc:EnableCheats() end)
    cm = pc.CheatManager
    if cm and cm:IsValid() then return cm end
    return nil
end

-- Befund 2. Versuch (live): Debug_Capture*, cm:CaptureNewMonster, cm:SpawnMonsterForPlayer
-- und cm:GetItem laufen alle ok=true durch, bewirken im Retail aber NICHTS Sichtbares.
-- Pal-Give ist damit tot - Test-Pals werden manuell gefangen. Letzter Versuch hier:
-- cm:SpawnMonster (ohne ForPlayer) als einzelner Kandidat, sonst nur noch Sphaeren.
local function givePalsV2(pc)
    local cm = getCheatManager(pc)
    if not cm then
        Log("[probe-testkit] kein CheatManager")
        return
    end
    local ok, err = pcall(function()
        cm:SpawnMonster(FName("Penguin"), 31)
    end)
    Log(string.format("[probe-testkit] cm:SpawnMonster ok=%s err=%s", tostring(ok), tostring(err)))
end

local KIT_KEY = Key.INS or Key.F4
RegisterKeyBind(KIT_KEY, Debounced("testkit", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local pc = FindFirstOf("PalPlayerController")
            if not pc or not pc:IsValid() then Log("[probe-testkit] kein PalPlayerController") return end
            local ps = pc:GetPalPlayerState()
            if not ps or not ps:IsValid() then Log("[probe-testkit] kein PalPlayerState") return end
            local inv = ps:GetInventoryData()
            if inv and inv:IsValid() then
                giveItemsV2(inv)
            else
                Log("[probe-testkit] kein InventoryData")
            end
            givePalsV2(pc)
        end)
        if not suc then Log("[probe-testkit] FAIL: " .. tostring(e)) end
    end)
end))

-- F10: EXP-Hebel, um den Level-Hook reproduzierbar auszuloesen
RegisterKeyBind(Key.F10, Debounced("giveexp", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local player = FindFirstOf("PalPlayerCharacter")
            if not player or not player:IsValid() then Log("[probe-giveexp] kein Spieler") return end
            local util = StaticFindObject("/Script/Pal.Default__PalUtility")
            -- Signatur (Dump :64549): WorldContextObject, Center: FVector, Radius, Exp, bCallDelegate
            local center = player:K2_GetActorLocation()
            util:GiveExpToAroundPlayerCharacter(player, center, 2000.0, 500.0, true)
            Log("[probe-giveexp] 500 EXP an Umkreis vergeben")
        end)
        if not suc then Log("[probe-giveexp] FAIL: " .. tostring(e)) end
    end)
end))

Log(string.format("Proben aktiv: F5 Overlay, F6 VFX, F7 SpeciesSwap, F8 Fanfare, F9 Freeze, F10 GiveExp, TestKit auf %s",
    Key.INS and "EINFG" or "F4"))

return M
