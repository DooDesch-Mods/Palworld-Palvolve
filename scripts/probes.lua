-- Palvolve Dev-Proben (temporaer, vor Release loeschen).
-- Verifiziert die offenen Punkte aus Workspace/docs/Palvolve/RESEARCH.md live im Spiel.
-- Marker: [probe-pallevelup] [probe-expdb] [probe-speciesswap] [probe-vfx]
--         [probe-overlay] [probe-ake] [probe-freeze] [probe-giveexp]
--
-- Keybinds (Testwelt "ModDev", eigenen Pal aussummonen):
--   F5 = Overlay-Glow an/aus (M_Glow)      F6 = AddVisualEffect CaptureEmissive
--   F7 = Species-Swap Penguin->CaptainPenguin (NUR Testwelt!)
--   F8 = Fanfare (AKE_CampLevelUp)         F9 = Freeze/Unfreeze naechster Pal
--   F10 = EXP an Pals im Umkreis (loest Level-Hook aus)

local M = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- ---------------------------------------------------------------- Hooks beim Laden

-- Probe 1: feuert der BP-Level-Up-Handler? (UTF-8-Funktionsname mit japanischem "Event")
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
Log(string.format("[probe-pallevelup] hook registered ok=%s err=%s", tostring(ok), tostring(err)))

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
    -- Grobe Dev-Heuristik: erster gespawnter Monster-Actor. Fuer Proben ausreichend,
    -- der echte Mod filtert ueber OwnerPlayerUId/IsPlayersOtomo.
    local pal = FindFirstOf("BP_MonsterBase_C")
    if pal and pal:IsValid() then return pal end
    return nil
end

-- ---------------------------------------------------------------- Keybind-Proben

-- F5: Overlay-Fallback (M_Glow), Restore nach ~2 s
RegisterKeyBind(Key.F5, function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local pal = firstOwnedMonster()
            if not pal then Log("[probe-overlay] kein Pal gespawnt") return end
            local glow = StaticFindObject("/Game/Pal/Effect/Material/M_Glow.M_Glow")
            if not glow or not glow:IsValid() then Log("[probe-overlay] M_Glow nicht gefunden") return end
            local mesh = pal:GetMainMesh()
            mesh:SetOverlayMaterial(glow)
            Log("[probe-overlay] set auf " .. pal:GetName())
            ExecuteWithDelay(2000, function()
                ExecuteInGameThread(function()
                    if pal:IsValid() and mesh:IsValid() then
                        mesh:SetOverlayMaterial(nil)
                        Log("[probe-overlay] restored")
                    end
                end)
            end)
        end)
        if not suc then Log("[probe-overlay] FAIL: " .. tostring(e)) end
    end)
end)

-- F6: spiel-eigener Glow via PalVisualEffectComponent (CaptureEmissive=1)
RegisterKeyBind(Key.F6, function()
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
end)

-- F7: Species-Swap-Kernprobe Penguin -> CaptainPenguin (NUR in der Testwelt ausloesen!)
RegisterKeyBind(Key.F7, function()
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
end)

-- F8: Fanfare via Wwise
RegisterKeyBind(Key.F8, function()
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
end)

-- F9: Freeze-Toggle (AI aus + Move-Lock)
local frozen = false
RegisterKeyBind(Key.F9, function()
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
end)

-- F10: EXP-Hebel, um den Level-Hook reproduzierbar auszuloesen
RegisterKeyBind(Key.F10, function()
    ExecuteInGameThread(function()
        local suc, e = pcall(function()
            local player = FindFirstOf("PalPlayerCharacter")
            if not player or not player:IsValid() then Log("[probe-giveexp] kein Spieler") return end
            local util = StaticFindObject("/Script/Pal.Default__PalUtility")
            util:GiveExpToAroundPlayerCharacter(player, 2000.0, 500.0)
            Log("[probe-giveexp] 500 EXP an Umkreis vergeben")
        end)
        if not suc then Log("[probe-giveexp] FAIL: " .. tostring(e)) end
    end)
end)

Log("Proben aktiv: F5 Overlay, F6 VFX, F7 SpeciesSwap, F8 Fanfare, F9 Freeze, F10 GiveExp")

return M
