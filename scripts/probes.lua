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

-- F6: spiel-eigene VisualEffects durchprobieren - jeder Druck der naechste Effekt.
-- Befund: 1=CaptureEmissive glueht auf und laesst den Pal VERSCHWINDEN (Fang-Verhalten)
-- = perfekte Phase 1 der Evolution; 2=SpawnFromBallEmissive sollte das Erscheinen sein.
local VFX_IDS = {
    { id = 1,  name = "CaptureEmissive (Glow + Verschwinden)" },
    { id = 2,  name = "SpawnFromBallEmissive (Erscheinen mit Glow)" },
    { id = 41, name = "PalEnhancement" },
    { id = 27, name = "RarePal" },
    { id = 5,  name = "FadeIn" },
    { id = 4,  name = "FadeOut" },
}
local vfxIndex = 0
RegisterKeyBind(Key.F6, Debounced("vfx", function()
    ExecuteInGameThread(function()
        local pal = firstOwnedMonster()
        if not pal then Log("[probe-vfx] kein Pal gespawnt") return end
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

-- F7: Species-Swap-Kernprobe ueber mehrere Paare (NUR in der Testwelt ausloesen!)
-- Modell baut sich NICHT sofort neu (RequestRespawnPal wirkungslos) - erst beim
-- naechsten Beschwoeren/Box-Roundtrip spawnt der Actor als neue Spezies (live bewiesen).
local SWAP_PAIRS = {
    { from = "Penguin", to = "CaptainPenguin" },  -- Pengullet -> Penking
    { from = "MopBaby", to = "MopKing" },         -- Swee -> Sweepa
    { from = "MopKing", to = "Yeti" },            -- Sweepa -> Wumpo (Fun-Kette)
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
                        Log(string.format("[probe-speciesswap] %s -> %s, MaxHP %s -> %s (Box-Roundtrip/Resummon fuer Modell)",
                            pair.from, p:GetCharacterID():ToString(), tostring(hpBefore), tostring(p:GetMaxHP())))
                        return
                    end
                end
            end
            -- Diagnose: welche Spezies sind ueberhaupt im Speicher?
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
            Log("[probe-speciesswap] kein Swap-Kandidat; Spezies im Speicher: " .. table.concat(list, ", "))
        end)
        if not suc then Log("[probe-speciesswap] FAIL: " .. tostring(e)) end
    end)
end))

-- F3: Rueckverwandlung fuers Testen - NUR eigene Pals (Owner-Filter wie im echten Mod)
local REVERT_PAIRS = {
    { from = "CaptainPenguin", to = "Penguin" },  -- Penking -> Pengullet
    { from = "MopKing", to = "MopBaby" },         -- Sweepa -> Swee
    { from = "Yeti", to = "MopKing" },            -- Wumpo -> Sweepa
}
-- Befund: OwnerPlayerUId.A war auch beim eigenen Penking 0 (oder nicht lesbar) ->
-- Revert nimmt vorerst ALLE Kandidaten und loggt den rohen Owner-Guid zur Diagnose.
local function ownerGuidString(p)
    local s = "unlesbar"
    pcall(function()
        local g = p.SaveParameter.OwnerPlayerUId
        s = string.format("%08X-%08X-%08X-%08X", g.A, g.B, g.C, g.D)
    end)
    return s
end

RegisterKeyBind(Key.F3, Debounced("revert", function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local all = FindAllOf("PalIndividualCharacterParameter") or {}
            local count = 0
            for _, p in ipairs(all) do
                if p:IsValid() then
                    local id = p:GetCharacterID():ToString()
                    for _, pair in ipairs(REVERT_PAIRS) do
                        if id == pair.from then
                            p.SaveParameter.CharacterID = FName(pair.to)
                            p.SaveParameterMirror.CharacterID = FName(pair.to)
                            count = count + 1
                            Log(string.format("[probe-revert] %s -> %s (OwnerGuid %s)",
                                pair.from, pair.to, ownerGuidString(p)))
                            break
                        end
                    end
                end
            end
            if count == 0 then
                Log("[probe-revert] keine Rueckverwandlungs-Kandidaten gefunden")
            else
                Log(string.format("[probe-revert] %d Pal(s) zurueckverwandelt - ein-/aussummonen fuer das Modell", count))
            end
        end)
        if not suc then Log("[probe-revert] FAIL: " .. tostring(e)) end
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
            Log("[probe-freeze] frozen=" .. tostring(frozen) .. " auf " .. pal:GetFullName())
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
        -- Palvolve-Steine (existieren nur, wenn PalSchema die Items geladen hat)
        local ret3 = inv:AddItem_ServerInternal(FName("Palvolve_EvolutionStone"), 5, false, 0.0, true)
        local ret4 = inv:AddItem_ServerInternal(FName("Palvolve_AdaptionStone"), 5, false, 0.0, true)
        Log(string.format("[probe-testkit] AddItem PalSphere=%s Mega=%s EvoStone=%s AdaptStone=%s",
            tostring(ret1), tostring(ret2), tostring(ret3), tostring(ret4)))
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
            -- GiveExpToAroundPlayerCharacter trifft nur SPIELER (live bestaetigt) ->
            -- GiveExpToAroundCharacter mit CharacterClass=PalCharacter fuer die Pals
            -- (Dump :64555: WorldContext, Center, Radius, Exp, CharacterClass, bCallDelegate)
            local center = player:K2_GetActorLocation()
            local palClass = StaticFindObject("/Script/Pal.PalCharacter")
            util:GiveExpToAroundCharacter(player, center, 3000.0, 50000.0, palClass, true)
            Log("[probe-giveexp] 50000 EXP an Pals im Umkreis vergeben")
        end)
        if not suc then Log("[probe-giveexp] FAIL: " .. tostring(e)) end
    end)
end))

Log(string.format("Proben aktiv: F3 Revert(eigene), F5 Overlay, F6 VFX, F7 SpeciesSwap, F8 Fanfare, F9 Freeze, F10 GiveExp, TestKit auf %s",
    Key.INS and "EINFG" or "F4"))

return M
