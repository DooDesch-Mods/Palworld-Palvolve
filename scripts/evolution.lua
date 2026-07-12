-- Palvolve-Kern: Eligibility, zweistufiger Confirm, transaktionaler Spezies-Swap,
-- Snapshot/Rollback, IV-Bonus und die Evolutions-Sequenz.
-- API-Fakten: Workspace/docs/Palvolve/RESEARCH.md. Sequenz-Design nach Codex-Review:
-- handle-gezielter Rueckruf (InactiveOtomoByHandle_PreProcess) + Aktivierung
-- (ActivatePalByHandle) statt der Current-Otomo-Funktionen, Swap erst nach
-- BESTAETIGTEM Despawn, Respawn wird verifiziert statt angenommen.

local Config = require("config")

local Evolution = {}

local MOD_NAME = "Palvolve"
local STATE_FILE = "ue4ss\\Mods\\Palvolve\\palvolve_state.lua"

local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- ---------------------------------------------------------------- Utilities

local function palUtility()
    local u = StaticFindObject("/Script/Pal.Default__PalUtility")
    if u and u:IsValid() then return u end
    return nil
end

-- Owner-Check: Kennung steckt u.a. in der D-Komponente (lokaler Host = ...-0001),
-- deshalb alle vier Guid-Komponenten pruefen.
local function isOwned(param)
    local owned = false
    pcall(function()
        local g = param.SaveParameter.OwnerPlayerUId
        owned = (g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0)
    end)
    return owned
end

local function guidString(g)
    return string.format("%08X-%08X-%08X-%08X", g.A, g.B, g.C, g.D)
end

local function individualKey(param)
    local key = ""
    pcall(function() key = guidString(param.IndividualId.InstanceId) end)
    if key == "" then pcall(function() key = param:GetFullName() end) end
    return key
end

local function paramOf(palActor)
    local param = nil
    pcall(function()
        param = palActor.CharacterParameterComponent:GetIndividualParameter()
    end)
    if param and param:IsValid() then return param end
    return nil
end

local function findHolder(actor)
    local util = palUtility()
    if not util then return nil end
    local holder = nil
    if actor then
        pcall(function()
            if actor:IsValid() then holder = util:GetOtomoHolderByOtomoPal(actor) end
        end)
        if holder and holder:IsValid() then return holder end
    end
    pcall(function()
        local pc = FindFirstOf("PalPlayerController")
        if pc and pc:IsValid() then holder = util:GetOtomoHolderComponent(pc) end
    end)
    if holder and holder:IsValid() then return holder end
    return nil
end

local function findManager(ctx)
    local mgr = nil
    pcall(function()
        local util = palUtility()
        if util then mgr = util:GetCharacterManager(ctx) end
    end)
    if mgr and mgr:IsValid() then return mgr end
    pcall(function() mgr = FindFirstOf("PalCharacterManager") end)
    if mgr and mgr:IsValid() then return mgr end
    return nil
end

-- ---------------------------------------------------------------- Snapshots (Rollback)

-- Persistiert als ausfuehrbares Lua (einfachster robuster Weg ohne JSON-Lib).
local snapshots = {}

local function loadSnapshots()
    local ok = pcall(function()
        local chunk = loadfile(STATE_FILE)
        if chunk then
            local data = chunk()
            if type(data) == "table" then snapshots = data end
        end
    end)
    if not ok then snapshots = {} end
end

local function saveSnapshots()
    local ok, err = pcall(function()
        local f = assert(io.open(STATE_FILE, "w"))
        f:write("return {\n")
        for _, s in ipairs(snapshots) do
            f:write(string.format(
                "  { key = %q, from = %q, to = %q, level = %d, nickname = %q, ivHP = %d, ivMelee = %d, ivShot = %d, ivDefense = %d },\n",
                s.key or "", s.from, s.to, s.level, s.nickname or "",
                s.ivHP or -1, s.ivMelee or -1, s.ivShot or -1, s.ivDefense or -1))
        end
        f:write("}\n")
        f:close()
    end)
    if not ok then Log("Snapshot-Datei nicht schreibbar: " .. tostring(err)) end
end

-- ---------------------------------------------------------------- FX-Bausteine

local function playFanfare(actor)
    pcall(function()
        local ake = StaticFindObject("/Game/Pal/Sound/Events/SE/UI/CampLevelUp/AKE_CampLevelUp.AKE_CampLevelUp")
        local aks = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics")
        if ake and ake:IsValid() and aks and aks:IsValid() then
            aks:PostEvent(ake, actor, 0, nil, false)
        end
    end)
end

local function playEffect(actor, effectId)
    pcall(function()
        actor.VisualEffectComponent:AddVisualEffect(effectId, { FloatValues = {} })
    end)
end

local function setFrozen(palActor, frozen)
    pcall(function()
        local ctrl = palActor:GetController()
        if ctrl and ctrl:IsValid() then ctrl:SetActiveAI(not frozen) end
    end)
    pcall(function()
        local util = palUtility()
        if util then util:SetMoveDisableFlag(palActor, frozen, FName("PalvolveSeq")) end
    end)
end

-- ---------------------------------------------------------------- IV-Bonus

local TALENT_FIELDS = { "Talent_HP", "Talent_Melee", "Talent_Shot", "Talent_Defense" }

local function readTalents(param)
    local t = {}
    for _, field in ipairs(TALENT_FIELDS) do
        local v = -1
        pcall(function() v = param.SaveParameter[field] end)
        t[field] = v
    end
    return t
end

local function applyIvBonus(param)
    local applied = {}
    for _, field in ipairs(TALENT_FIELDS) do
        local ok = pcall(function()
            local cur = param.SaveParameter[field]
            local new = math.min(cur + Config.ivBonusPerStage, Config.ivCap)
            param.SaveParameter[field] = new
            param.SaveParameterMirror[field] = new
            table.insert(applied, string.format("%s %d->%d", field, cur, new))
        end)
        if not ok then
            Log("IV-Bonus: Feld " .. field .. " nicht schreibbar (Feldname pruefen)")
        end
    end
    if #applied > 0 then Log("IV-Bonus: " .. table.concat(applied, ", ")) end
end

-- ---------------------------------------------------------------- Polling-Helfer

-- Prueft checkFn (Game-Thread) alle intervalMs, bis true oder timeoutMs erreicht;
-- ruft doneFn(success) genau einmal im Game-Thread auf.
local function pollUntil(intervalMs, timeoutMs, checkFn, doneFn)
    local elapsed = 0
    local finished = false
    LoopAsync(intervalMs, function()
        if finished then return true end
        elapsed = elapsed + intervalMs
        ExecuteInGameThread(function()
            if finished then return end
            local ok, res = pcall(checkFn)
            if ok and res then
                finished = true
                doneFn(true)
            elseif elapsed >= timeoutMs then
                finished = true
                doneFn(false)
            end
        end)
        return finished
    end)
end

-- ---------------------------------------------------------------- Kern-Sequenz

-- pending = { actor, param, pair, armedAt, key }
local pending = nil

-- Der Spieler kann nur 1 eigenen Pal gleichzeitig beschwoeren -> die autoritative
-- Quelle ist der Otomo-Holder, nicht ein FindAllOf-Scan (der auch Geister-Actor traefe).
local function findEligible()
    local holder = findHolder(nil)
    if not holder then return nil end
    local actor = nil
    pcall(function() actor = holder:TryGetSpawnedOtomo() end)
    if not (actor and actor:IsValid()) then return nil end
    local param = paramOf(actor)
    if not (param and isOwned(param)) then return nil end
    local id = param:GetCharacterID():ToString()
    local pair = Config.findPair(id)
    if not pair then
        return nil, string.format("%s hat keine Entwicklung", id)
    end
    local level = 0
    pcall(function() level = param:GetLevel() end)
    if level < pair.minLevel then
        return nil, string.format("%s braucht Level %d fuer die Entwicklung (aktuell %d)",
            id, pair.minLevel, level)
    end
    return actor, param, pair, level, holder
end

local function performEvolution(p)
    local actor, param, pair, holder = p.actor, p.param, p.pair, p.holder
    pending = nil
    if not (actor:IsValid() and param:IsValid() and holder and holder:IsValid()) then
        Log("Entwicklung abgebrochen: Pal/Holder nicht mehr gueltig")
        return
    end

    local mgr = findManager(actor)
    if not mgr then
        Log("Entwicklung abgebrochen: PalCharacterManager nicht gefunden")
        return
    end
    local handle = nil
    pcall(function() handle = mgr:GetIndividualHandleFromCharacterParameter(param) end)
    if not (handle and handle:IsValid()) then
        Log("Entwicklung abgebrochen: Individual-Handle nicht ermittelbar")
        return
    end

    -- Ausgangszustand festhalten (Diagnose + Snapshot-Daten)
    local level, nickname = 0, ""
    pcall(function() level = param:GetLevel() end)
    pcall(function() nickname = param.SaveParameter.NickName and param.SaveParameter.NickName:ToString() or "" end)
    local key = individualKey(param)
    local talentsBefore = readTalents(param)
    Log(string.format("Sequenz-Start: %s Lv%d key=%s", pair.from, level, key))

    -- Phase 1: Einfrieren + Rueckruf-Optik
    setFrozen(actor, true)
    playEffect(actor, 3)  -- ReturnToBallEmissive: die echte Einzieh-Optik
    playFanfare(actor)

    -- Phase 2: Rueckruf mit Eskalationskette, jede Stufe mit Despawn-Verifikation.
    -- PreProcess allein baut den Actor NICHT ab (live belegt); da die Eligibility den
    -- echten Current Otomo liefert, sind die Current-Funktionen hier zielsicher.
    local recallStrategies = {
        { name = "PreProcess+Complete", fn = function()
            holder:InactiveOtomoByHandle_PreProcess(handle)
            holder:CompleteInactiveCurrentOtomo()
        end },
        { name = "InactivateCurrentOtomo", fn = function()
            holder:InactivateCurrentOtomo()
        end },
        { name = "PlayerController:InactiveOtomo", fn = function()
            local pc = FindFirstOf("PalPlayerController")
            if pc and pc:IsValid() then pc:InactiveOtomo() end
        end },
    }

    -- Autoritative Sicht: der Holder weiss, ob ein Otomo draussen ist.
    -- (handle:TryGetIndividualActor liefert auch nach dem Einzug noch einen
    -- "gueltigen" Actor - live belegt, daher untauglich als Signal.)
    local function isDespawned()
        local spawned = nil
        pcall(function() spawned = holder:TryGetSpawnedOtomo() end)
        return not (spawned and spawned:IsValid())
    end

    local proceedAfterDespawn  -- forward declaration

    local function tryRecall(i)
        if i > #recallStrategies then
            Log("Rueckruf nicht bestaetigt (alle Strategien erschoepft) - breche OHNE Swap ab")
            if actor:IsValid() then setFrozen(actor, false) end
            return
        end
        local strat = recallStrategies[i]
        local okCall, errCall = pcall(strat.fn)
        Log(string.format("Rueckruf-Versuch '%s' call=%s%s", strat.name, tostring(okCall),
            okCall and "" or (" err=" .. tostring(errCall))))
        pollUntil(200, 2000, isDespawned, function(despawned)
            if despawned then
                Log(string.format("Despawn bestaetigt via '%s'", strat.name))
                proceedAfterDespawn()
            else
                tryRecall(i + 1)
            end
        end)
    end

    proceedAfterDespawn = function()
        -- Phase 3: Swap im despawnten Zustand (sicherster Schreibmoment) + verifizieren
        if not param:IsValid() then
            Log("Abbruch: Parameter nach Despawn ungueltig")
            return
        end
        local okSwap, errSwap = pcall(function()
            param.SaveParameter.CharacterID = FName(pair.to)
            param.SaveParameterMirror.CharacterID = FName(pair.to)
        end)
        local idNow = ""
        pcall(function() idNow = param:GetCharacterID():ToString() end)
        if not okSwap or idNow ~= pair.to then
            Log(string.format("SWAP FEHLGESCHLAGEN (err=%s, id=%s) - kein Respawn-Versuch",
                tostring(errSwap), idNow))
            return
        end
        applyIvBonus(param)
        pcall(function() param:FullRecoveryHP() end)

        -- Snapshot erst NACH erfolgreichem Swap (kein Phantom-Rollback-Eintrag)
        table.insert(snapshots, {
            key = key, from = pair.from, to = pair.to, level = level, nickname = nickname,
            ivHP = talentsBefore.Talent_HP, ivMelee = talentsBefore.Talent_Melee,
            ivShot = talentsBefore.Talent_Shot, ivDefense = talentsBefore.Talent_Defense,
        })
        saveSnapshots()

        -- Phase 4: gezielt DIESEN Handle wieder aktivieren
        local okAct, errAct = pcall(function()
            local tf = holder:GetTransform_SpawnPalNearTrainer()
            holder:ActivatePalByHandle(handle, tf.Translation, tf.Rotation, false)
        end)
        if not okAct then
            Log("ActivatePalByHandle Fehler: " .. tostring(errAct) .. " - Fallback CurrentOtomo")
            pcall(function() holder:ActivateCurrentOtomoNearThePlayer() end)
        end

        -- Phase 5: Respawn VERIFIZIEREN statt annehmen (Holder-Sicht + Spezies-Check)
        pollUntil(200, 4000, function()
            local a = nil
            pcall(function() a = holder:TryGetSpawnedOtomo() end)
            if not (a and a:IsValid()) then return false end
            local id = ""
            pcall(function() id = paramOf(a) and paramOf(a):GetCharacterID():ToString() or "" end)
            return id == pair.to
        end, function(spawned)
            if spawned then
                local newActor = nil
                pcall(function() newActor = holder:TryGetSpawnedOtomo() end)
                if newActor and newActor:IsValid() then
                    setFrozen(newActor, false)
                end
                playFanfare(newActor or actor)
                Log(string.format("ENTWICKELT: %s -> %s (Level %d)%s - Respawn OK",
                    pair.from, pair.to, level,
                    nickname ~= "" and (" '" .. nickname .. "'") or ""))
            else
                Log(string.format("ENTWICKELT: %s -> %s (Level %d) - Swap OK, aber Respawn NICHT bestaetigt; bitte einmal manuell aussummonen",
                    pair.from, pair.to, level))
            end
        end)
    end

    tryRecall(1)
end

-- ---------------------------------------------------------------- Public API

function Evolution.check()
    local actor, param, pair, level, holder = findEligible()
    if not actor then
        if not pending then
            Log(param or "Kein eigener Pal aussummont")
        end
        return
    end
    local now = os.clock()
    local key = individualKey(param)
    if pending and (now - pending.armedAt) <= Config.confirmWindowSeconds then
        if pending.key == key then
            performEvolution(pending)
            return
        else
            Log(string.format("Confirm-Ziel gewechselt (vorher %s, jetzt %s) - neu armiert", pending.key, key))
        end
    end
    pending = { actor = actor, param = param, pair = pair, holder = holder, armedAt = now, key = key }
    playFanfare(actor)
    Log(string.format("%s (Lv %d) kann sich zu %s entwickeln - %s erneut druecken zum Bestaetigen (%ds)",
        pair.from, level, pair.to, Config.confirmKey, Config.confirmWindowSeconds))
end

function Evolution.rollbackLast()
    local last = table.remove(snapshots)
    if not last then
        Log("Rollback: kein Snapshot vorhanden")
        return
    end
    local reverted = false
    local all = FindAllOf("PalIndividualCharacterParameter") or {}
    -- Erst gezielt ueber den Individual-Key, dann Fallback ueber Spezies
    for pass = 1, 2 do
        for _, p in ipairs(all) do
            if p:IsValid() and isOwned(p) and p:GetCharacterID():ToString() == last.to then
                local match = (pass == 2)
                if pass == 1 and last.key and last.key ~= "" then
                    match = (individualKey(p) == last.key)
                end
                if match then
                    pcall(function()
                        p.SaveParameter.CharacterID = FName(last.from)
                        p.SaveParameterMirror.CharacterID = FName(last.from)
                    end)
                    -- IVs auf den Stand vor der Evolution zuruecksetzen
                    local restore = {
                        Talent_HP = last.ivHP, Talent_Melee = last.ivMelee,
                        Talent_Shot = last.ivShot, Talent_Defense = last.ivDefense,
                    }
                    for field, v in pairs(restore) do
                        if v and v >= 0 then
                            pcall(function()
                                p.SaveParameter[field] = v
                                p.SaveParameterMirror[field] = v
                            end)
                        end
                    end
                    reverted = true
                    break
                end
            end
        end
        if reverted then break end
    end
    saveSnapshots()
    Log(string.format("Rollback %s -> %s: %s (neu aussummonen)",
        last.to, last.from, reverted and "zurueckgesetzt inkl. IVs" or "kein passender Pal gefunden"))
end

function Evolution.init()
    loadSnapshots()

    local lastPress = 0
    RegisterKeyBind(Key[Config.confirmKey], function()
        local now = os.clock()
        if (now - lastPress) < Config.debounceSeconds then return end
        lastPress = now
        ExecuteInGameThread(function()
            local ok, err = pcall(Evolution.check)
            if not ok then Log("check FAIL: " .. tostring(err)) end
        end)
    end)

    -- Level-Up-Benachrichtigung: meldet EINMAL pro Pal, sobald die Schwelle erreicht ist
    local notified = {}
    local hookRegistered = false
    local function tryHook()
        if hookRegistered then return true end
        local ok = pcall(RegisterHook,
            "/Game/Pal/Blueprint/Character/Monster/BP_MonsterBase.BP_MonsterBase_C:OnUpdateLevelDelegate_イベント_0",
            function(self, addLevel, nowLevel)
                pcall(function()
                    local actor = self:get()
                    local param = actor.CharacterParameterComponent:GetIndividualParameter()
                    if not isOwned(param) then return end
                    local id = param:GetCharacterID():ToString()
                    local pair = Config.findPair(id)
                    if not pair then return end
                    -- nowLevel ist das Level VOR der Addition (live belegt)
                    local newLevel = nowLevel:get() + addLevel:get()
                    if newLevel >= pair.minLevel then
                        local key = individualKey(param)
                        if notified[key] then return end
                        notified[key] = true
                        playFanfare(actor)
                        Log(string.format("%s hat Level %d erreicht und kann sich zu %s entwickeln! (%s druecken)",
                            id, newLevel, pair.to, Config.confirmKey))
                    end
                end)
            end)
        hookRegistered = ok
        return ok
    end
    if not tryHook() then
        LoopAsync(5000, function()
            if hookRegistered then return true end
            ExecuteInGameThread(function() tryHook() end)
            return hookRegistered
        end)
    end

    -- Konsole: "palvolve rollback" | "palvolve check"
    pcall(function()
        RegisterConsoleCommandHandler("palvolve", function(fullCommand, parameters)
            local sub = parameters[1] or "check"
            ExecuteInGameThread(function()
                if sub == "rollback" then
                    Evolution.rollbackLast()
                else
                    Evolution.check()
                end
            end)
            return true
        end)
    end)

    Log(string.format("Evolutions-Kern aktiv: %s = pruefen/bestaetigen, Konsole: palvolve check|rollback",
        Config.confirmKey))
end

return Evolution
