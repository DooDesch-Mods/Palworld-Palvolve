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

-- ---------------------------------------------------------------- Item-Kosten

local function inventoryData()
    local inv = nil
    pcall(function()
        local pc = FindFirstOf("PalPlayerController")
        if pc and pc:IsValid() then
            inv = pc:GetPalPlayerState():GetInventoryData()
        end
    end)
    if inv and inv:IsValid() then return inv end
    return nil
end

local function countItem(staticItemId)
    local n = 0
    pcall(function()
        local inv = inventoryData()
        if inv then n = inv:CountItemNum(FName(staticItemId)) end
    end)
    return n
end

-- Verbraucht need Stueck; Erfolg wird ueber die Count-Differenz verifiziert
-- (RequestConsumeInventoryItem ist der einzige BP-exponierte Konsum-Pfad).
local function tryConsumeItems(staticItemId, need)
    local ok = false
    pcall(function()
        local inv = inventoryData()
        if not inv then return end
        local id = FName(staticItemId)
        local before = inv:CountItemNum(id)
        if before < need then return end
        local cdo = StaticFindObject("/Script/Pal.Default__PalIncidentBase")
        if cdo and cdo:IsValid() then
            cdo:RequestConsumeInventoryItem(inv, id, need)
        end
        local after = inv:CountItemNum(id)
        ok = (before - after) == need
    end)
    return ok
end

-- Prueft die Stein-Kosten fuer ein Paar; liefert ok, stoneId, anzeigename
local function stoneCheck(pair)
    if not Config.requireStone then return true, nil, nil end
    local stoneId = Config.stoneItemIds[pair.stone]
    local stoneName = Config.stoneNames[pair.stone] or pair.stone
    if not stoneId then return true, nil, nil end
    return countItem(stoneId) >= Config.stoneCount, stoneId, stoneName
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
                local okDone, errDone = pcall(doneFn, true)
                if not okDone then Log("pollUntil doneFn FAIL: " .. tostring(errDone)) end
            elseif elapsed >= timeoutMs then
                finished = true
                local okDone, errDone = pcall(doneFn, false)
                if not okDone then Log("pollUntil doneFn FAIL: " .. tostring(errDone)) end
            end
        end)
        return finished
    end)
end

-- ---------------------------------------------------------------- Kern-Sequenz

-- pending = { actor, param, pair, armedAt, key }
local pending = nil
-- Globaler Sequenz-Lock: nie zwei Evolutionen parallel.
-- Watchdog: falls ein Fehlerpfad den Lock haengen laesst, gibt check() ihn
-- nach 30 s selbst wieder frei.
local sequenceRunning = false
local sequenceStartedAt = 0

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
    sequenceRunning = true
    sequenceStartedAt = os.clock()
    local function finish()
        sequenceRunning = false
    end
    if not (actor:IsValid() and param:IsValid() and holder and holder:IsValid()) then
        Log("Entwicklung abgebrochen: Pal/Holder nicht mehr gueltig")
        finish()
        return
    end

    local mgr = findManager(actor)
    if not mgr then
        Log("Entwicklung abgebrochen: PalCharacterManager nicht gefunden")
        finish()
        return
    end
    local handle = nil
    pcall(function() handle = mgr:GetIndividualHandleFromCharacterParameter(param) end)
    if not (handle and handle:IsValid()) then
        Log("Entwicklung abgebrochen: Individual-Handle nicht ermittelbar")
        finish()
        return
    end

    -- Stein-Kosten VOR der Sequenz einziehen (kein TOCTOU: schlaegt spaeter etwas
    -- vor dem Swap fehl, wird der Stein zurueckerstattet; nach dem Swap ist er verdient)
    local paidStoneId = nil
    if Config.requireStone then
        local _, stoneId, stoneName = stoneCheck(pair)
        if stoneId then
            if not tryConsumeItems(stoneId, Config.stoneCount) then
                Log(string.format("Entwicklung abgebrochen: %dx %s nicht verfuegbar/verbrauchbar",
                    Config.stoneCount, stoneName))
                finish()
                return
            end
            paidStoneId = stoneId
            Log(string.format("%dx %s eingesetzt", Config.stoneCount, stoneName))
        end
    end
    local function refundStone(reason)
        if not paidStoneId then return end
        pcall(function()
            local inv = inventoryData()
            if inv then
                inv:AddItem_ServerInternal(FName(paidStoneId), Config.stoneCount, false, 0.0, true)
                Log("Stein zurueckerstattet (" .. reason .. ")")
            end
        end)
    end

    -- Ausgangszustand festhalten (Diagnose + Snapshot-Daten + Position fuer
    -- die Entwicklung VOR ORT)
    local level, nickname = 0, ""
    pcall(function() level = param:GetLevel() end)
    pcall(function() nickname = param.SaveParameter.NickName and param.SaveParameter.NickName:ToString() or "" end)
    local key = individualKey(param)
    local talentsBefore = readTalents(param)
    local oldLoc, oldRot = nil, nil
    pcall(function()
        oldLoc = actor:K2_GetActorLocation()
        oldRot = actor:K2_GetActorRotation()
    end)
    Log(string.format("Sequenz-Start: %s Lv%d key=%s", pair.from, level, key))

    -- Phase 1: Einfrieren + Evolutions-Optik. CaptureEmissive (ID 1) laesst den Pal
    -- AN ORT UND STELLE weiss aufgluehen. VOR dem Rueckruf wird der Actor dann HART
    -- versteckt (SetActorHiddenInGame) - die Ball-Einsaug-Animation laeuft damit
    -- unsichtbar ins Leere (Codex-Design).
    setFrozen(actor, true)
    pcall(function() actor:SetActorEnableCollision(false) end)
    playEffect(actor, 1)  -- CaptureEmissive: Weissglow vor Ort
    playFanfare(actor)

    -- Phase 2: Rueckruf mit Eskalationskette, jede Stufe mit Despawn-Verifikation.
    -- PreProcess allein baut den Actor NICHT ab (live belegt); da die Eligibility den
    -- echten Current Otomo liefert, sind die Current-Funktionen hier zielsicher.
    -- Direkter Manager-Teardown ZUERST: zerstoert den Actor ohne die Rueckruf-Action
    -- des Holders - deren Ball-Optik laeuft ueber einen Mesh-Klon, den das Verstecken
    -- des echten Actors nicht erfasst. InactivateCurrentOtomo bleibt Fallback, falls
    -- der Direktweg den Otomo-Slot nicht sauber hinterlaesst.
    local recallStrategies = {
        { name = "DirektTeardown", fn = function()
            mgr:DespawnCharacterByHandle(handle, nil)
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
            refundStone("Rueckruf fehlgeschlagen")
            finish()
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
            refundStone("Parameter ungueltig")
            finish()
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
            refundStone("Swap fehlgeschlagen")
            finish()
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

        -- Phase 4: Actor-Neuaufbau ERZWINGEN. Palworld poolt Pal-Actor - der Holder
        -- reaktiviert sonst denselben (alten) Koerper (live belegt: Pengullet-Modell
        -- trotz CaptainPenguin-Daten). Also: gepoolten Actor zerstoeren, dann an der
        -- ALTEN Position neu aktivieren (Entwicklung vor Ort).
        local okDespawn, errDespawn = pcall(function()
            mgr:DespawnCharacterByHandle(handle, nil)
        end)
        if not okDespawn then
            okDespawn = pcall(function() mgr:DespawnCharacterByHandle(handle) end)
        end
        Log(string.format("Actor-Teardown (DespawnCharacterByHandle) ok=%s%s",
            tostring(okDespawn), okDespawn and "" or (" err=" .. tostring(errDespawn))))

        -- Phase 4+5: Aktivierungs-Pumpe mit inszeniertem Enthuellen.
        local expectedClass = "BP_" .. pair.to .. "_C"
        local function isRespawned()
            local a = nil
            pcall(function() a = holder:TryGetSpawnedOtomo() end)
            if not (a and a:IsValid()) then return false end
            -- SOFORT verstecken, bevor der Spawn sichtbar wird (Enthuellung kommt inszeniert)
            pcall(function() a:SetActorHiddenInGame(true) end)
            pcall(function() a:SetActorEnableCollision(false) end)
            local cls = ""
            pcall(function() cls = a:GetClass():GetFullName() end)
            return cls:find(expectedClass, 1, true) ~= nil
        end

        -- Lichtsaeule an der Evolutions-Stelle (NS_Return = vanilla Licht-Aufloesung)
        local function spawnGapLight()
            pcall(function()
                if not oldLoc then return end
                local ns = StaticFindObject("/Game/Pal/Effect/Common/Return/NS_Return.NS_Return")
                local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
                if ns and ns:IsValid() and lib and lib:IsValid() then
                    lib:SpawnSystemAtLocation(holder, ns, oldLoc, oldRot or {Pitch=0,Yaw=0,Roll=0},
                        {X=1,Y=1,Z=1}, true, true, 0, false)
                end
            end)
        end

        local function revealActor(a)
            pcall(function() a:SetActorHiddenInGame(false) end)
            pcall(function() a:SetActorEnableCollision(true) end)
            pcall(function()
                local u = palUtility()
                if u then u:SetOpacityForCharacter(a, 1.0) end
            end)
        end

        local function finishRespawn(success)
            local newActor = nil
            pcall(function() newActor = holder:TryGetSpawnedOtomo() end)
            if success and newActor and newActor:IsValid() then
                -- Inszeniertes Enthuellen: versteckt an die alte Position, dann
                -- im naechsten Moment mit FadeIn + Glow + Fanfare erscheinen
                if oldLoc then
                    pcall(function() newActor:K2_TeleportTo(oldLoc, oldRot) end)
                end
                spawnGapLight()
                ExecuteWithDelay(200, function()
                    ExecuteInGameThread(function()
                        if newActor:IsValid() then
                            revealActor(newActor)
                            playEffect(newActor, 5)  -- FadeIn (PalEnhancement klebte dauerhaft)
                            setFrozen(newActor, false)
                            playFanfare(newActor)
                        end
                    end)
                end)
                Log(string.format("ENTWICKELT: %s -> %s (Level %d)%s - Respawn mit neuem Modell OK",
                    pair.from, pair.to, level,
                    nickname ~= "" and (" '" .. nickname .. "'") or ""))
            else
                -- Fehlerpfad: nichts unsichtbar zuruecklassen
                if newActor and newActor:IsValid() then
                    revealActor(newActor)
                    setFrozen(newActor, false)
                end
                local cls = ""
                pcall(function()
                    if newActor and newActor:IsValid() then cls = newActor:GetClass():GetFullName() end
                end)
                Log(string.format("ENTWICKELT (Daten): %s -> %s (Level %d) - Respawn nicht bestaetigt (Klasse '%s' statt %s); bitte einmal manuell aussummonen",
                    pair.from, pair.to, level, cls, expectedClass))
            end
            finish()
        end

        -- Aktivierungs-Pumpe: Die Engine gibt den neuen Actor erst nach variabler
        -- Settle-Zeit frei (live: 4-10 s nach Teardown). Alle 1,2 s ein Impuls -
        -- SpawnOtomoByLoad ZUERST (ballfrei), ActivateCurrentOtomoNearThePlayer nur
        -- als Fallback (kann Wurf-Optik ausloesen). Verifikation alle 100 ms, damit
        -- der Spawn sofort versteckt wird; die Lichtsaeule fuellt die Wartezeit.
        local startedAt = os.clock()
        local lastNudge = startedAt  -- erste Impuls-Pause = Settle-Zeit
        local nudgeCount = 0
        local pumpDone = false
        spawnGapLight()
        LoopAsync(100, function()
            if pumpDone then return true end
            ExecuteInGameThread(function()
                if pumpDone then return end
                if isRespawned() then
                    pumpDone = true
                    finishRespawn(true)
                    return
                end
                local now = os.clock()
                if (now - startedAt) > 15 then
                    pumpDone = true
                    finishRespawn(false)
                    return
                end
                if (now - lastNudge) >= 1.2 then
                    lastNudge = now
                    nudgeCount = nudgeCount + 1
                    local okNudge = pcall(function()
                        if nudgeCount % 2 == 1 then
                            local idx = holder:GetSlotIndexByIndividualHandle(handle)
                            holder:SpawnOtomoByLoad(idx)
                        else
                            holder:ActivateCurrentOtomoNearThePlayer()
                        end
                    end)
                    spawnGapLight()
                    Log(string.format("Aktivierungs-Impuls #%d ok=%s", nudgeCount, tostring(okNudge)))
                end
            end)
            return pumpDone
        end)
    end

    -- Rueckruf erst NACH dem Weissglow (ca. 1,2 s), und unmittelbar davor wird der
    -- Actor HART unsichtbar gemacht - das Ball-Einsaugen ist dann nicht zu sehen
    ExecuteWithDelay(1200, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                if actor:IsValid() then
                    pcall(function() actor:SetActorHiddenInGame(true) end)
                    pcall(function() actor:SetActorEnableCollision(false) end)
                    pcall(function()
                        local u = palUtility()
                        if u then u:SetOpacityForCharacter(actor, 0.0) end
                    end)
                end
                tryRecall(1)
            end)
            if not ok then
                Log("Rueckruf-Start FAIL: " .. tostring(err))
                refundStone("Sequenzfehler")
                finish()
            end
        end)
    end)
end

-- ---------------------------------------------------------------- Public API

function Evolution.check()
    if sequenceRunning then
        if (os.clock() - sequenceStartedAt) > 30 then
            Log("Sequenz-Lock haengt (>30s) - Watchdog gibt frei")
            sequenceRunning = false
        else
            Log("Eine Entwicklung laeuft bereits - bitte warten")
            return
        end
    end
    local actor, param, pair, level, holder = findEligible()
    if not actor then
        if not pending then
            Log(param or "Kein eigener Pal aussummont")
        end
        return
    end
    -- Stein-Kosten pruefen (greift erst mit requireStone=true, sobald die Steine existieren)
    local stoneOk, _, stoneName = stoneCheck(pair)
    if not stoneOk then
        Log(string.format("%s (Lv %d) koennte sich zu %s entwickeln, aber es fehlt: %dx %s",
            pair.from, level, pair.to, Config.stoneCount, stoneName))
        return
    end

    local now = os.clock()
    local key = individualKey(param)
    if pending and (now - pending.armedAt) <= Config.confirmWindowSeconds then
        if pending.key == key then
            -- FRISCHE Handles nutzen (der Pal kann seit dem Armieren neu ausgesummont
            -- worden sein - alte Actor-/Holder-Referenzen waeren dann stale)
            performEvolution({ actor = actor, param = param, pair = pair, holder = holder, key = key })
            return
        else
            Log(string.format("Confirm-Ziel gewechselt (vorher %s, jetzt %s) - neu armiert", pending.key, key))
        end
    end
    pending = { actor = actor, param = param, pair = pair, holder = holder, armedAt = now, key = key }
    playFanfare(actor)
    local costHint = ""
    if Config.requireStone and stoneName then
        costHint = string.format(" [Kosten: %dx %s]", Config.stoneCount, stoneName)
    end
    Log(string.format("%s (Lv %d) kann sich zu %s entwickeln%s - %s erneut druecken zum Bestaetigen (%ds)",
        pair.from, level, pair.to, costHint, Config.confirmKey, Config.confirmWindowSeconds))
end

function Evolution.rollbackLast()
    if sequenceRunning then
        Log("Rollback blockiert: eine Entwicklung laeuft gerade")
        return
    end
    -- Snapshot erst NACH verifiziertem Restore entfernen (kein Datenverlust bei Fehlschlag)
    local last = snapshots[#snapshots]
    if not last then
        Log("Rollback: kein Snapshot vorhanden")
        return
    end
    local reverted = false
    local all = FindAllOf("PalIndividualCharacterParameter") or {}
    local hasKey = last.key and last.key ~= ""
    for _, p in ipairs(all) do
        if p:IsValid() and isOwned(p) and p:GetCharacterID():ToString() == last.to then
            -- Mit Key NUR exakter Match (Spezies-Fallback traefe sonst z.B. den
            -- falschen Yeti bei SmallYeti->Yeti vs. MopKing->Yeti)
            local match = hasKey and (individualKey(p) == last.key) or (not hasKey)
            if match then
                pcall(function()
                    p.SaveParameter.CharacterID = FName(last.from)
                    p.SaveParameterMirror.CharacterID = FName(last.from)
                end)
                local idNow = ""
                pcall(function() idNow = p:GetCharacterID():ToString() end)
                if idNow == last.from then
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
                end
                break
            end
        end
    end
    if reverted then
        table.remove(snapshots)
        saveSnapshots()
        Log(string.format("Rollback %s -> %s: zurueckgesetzt inkl. IVs (neu aussummonen)",
            last.to, last.from))
    else
        Log(string.format("Rollback %s -> %s: kein passender Pal gefunden (Snapshot bleibt erhalten; Pal in die Naehe holen und erneut versuchen)",
            last.to, last.from))
    end
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
                        -- Key inkl. Ziel: nach einer Evolution meldet sich die
                        -- naechste Kettenstufe (z.B. MopKing->Yeti) wieder neu
                        local key = individualKey(param) .. ">" .. pair.to
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
                local ok, err = pcall(function()
                    if sub == "rollback" then
                        Evolution.rollbackLast()
                    else
                        Evolution.check()
                    end
                end)
                if not ok then Log("Konsole FAIL: " .. tostring(err)) end
            end)
            return true
        end)
    end)

    Log(string.format("Evolutions-Kern aktiv: %s = pruefen/bestaetigen, Konsole: palvolve check|rollback",
        Config.confirmKey))
end

return Evolution
