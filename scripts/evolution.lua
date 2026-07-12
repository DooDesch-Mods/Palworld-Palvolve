-- Palvolve-Kern: Eligibility, zweistufiger Confirm, transaktionaler Spezies-Swap,
-- Snapshot/Rollback, IV-Bonus und die Evolutions-Sequenz aus Vanilla-Effekten.
-- Alle Spiel-API-Aufrufe sind live verifiziert (Workspace/docs/Palvolve/RESEARCH.md).

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

-- Eigener, aktuell gespawnter Pal-Actor (Otomo bevorzugt)
local function ownedSummonedPals()
    local result = {}
    local util = palUtility()
    local all = FindAllOf("BP_MonsterBase_C") or {}
    for _, pal in ipairs(all) do
        if pal:IsValid() then
            local isOtomo = false
            if util then
                pcall(function() isOtomo = util:IsPlayersOtomo(pal) end)
            end
            if isOtomo then
                table.insert(result, pal)
            end
        end
    end
    return result
end

local function paramOf(palActor)
    local param = nil
    pcall(function()
        param = palActor.CharacterParameterComponent:GetIndividualParameter()
    end)
    if param and param:IsValid() then return param end
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
                "  { from = %q, to = %q, level = %d, nickname = %q, stage = %d },\n",
                s.from, s.to, s.level, s.nickname or "", s.stage or 1))
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

local function playVanishGlow(palActor)
    -- CaptureEmissive (ID 1): Aufgluehen + Verschwinden = Phase 1 der Evolution
    local ok = pcall(function()
        palActor.VisualEffectComponent:AddVisualEffect(1, { FloatValues = {} })
    end)
    return ok
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

-- ---------------------------------------------------------------- Kern-Sequenz

-- pending = { actor, param, pair, armedAt }
local pending = nil

local function findEligible()
    for _, actor in ipairs(ownedSummonedPals()) do
        local param = paramOf(actor)
        if param and isOwned(param) then
            local id = param:GetCharacterID():ToString()
            local pair = Config.findPair(id)
            if pair then
                local level = 0
                pcall(function() level = param:GetLevel() end)
                if level >= pair.minLevel then
                    return actor, param, pair, level
                else
                    Log(string.format("%s braucht Level %d fuer die Entwicklung (aktuell %d)",
                        id, pair.minLevel, level))
                end
            end
        end
    end
    return nil
end

local function performEvolution(p)
    local actor, param, pair = p.actor, p.param, p.pair
    if not (actor:IsValid() and param:IsValid()) then
        Log("Entwicklung abgebrochen: Pal nicht mehr gueltig")
        return
    end

    -- 1) Einfrieren + Snapshot VOR jeder Mutation
    setFrozen(actor, true)
    local level, nickname = 0, ""
    pcall(function() level = param:GetLevel() end)
    pcall(function() nickname = param.SaveParameter.NickName and param.SaveParameter.NickName:ToString() or "" end)
    table.insert(snapshots, { from = pair.from, to = pair.to, level = level, nickname = nickname, stage = 1 })
    saveSnapshots()

    -- 2) Phase 1: Aufgluehen + Verschwinden (Vanilla-Capture-Effekt), Fanfare
    playVanishGlow(actor)
    playFanfare(actor)

    -- 3) Nach dem Glow: Swap committen (Animation ist rein kosmetisch, Swap zuerst
    --    im Sinne von: bevor irgendetwas den Actor zerstoeren kann)
    local okSwap, errSwap = pcall(function()
        param.SaveParameter.CharacterID = FName(pair.to)
        param.SaveParameterMirror.CharacterID = FName(pair.to)
    end)
    if not okSwap then
        Log("SWAP FEHLGESCHLAGEN: " .. tostring(errSwap) .. " - Pal unveraendert")
        setFrozen(actor, false)
        pending = nil
        return
    end
    applyIvBonus(param)
    pcall(function() param:FullRecoveryHP() end)

    Log(string.format("ENTWICKELT: %s -> %s (Level %d)%s", pair.from, pair.to, level,
        nickname ~= "" and (" '" .. nickname .. "'") or ""))
    Log("Neu aussummonen, um die neue Gestalt zu sehen (Phase-3-Glow kommt beim Beschwoeren)")

    -- 4) Freeze wieder loesen (der Actor verschwindet durch den Capture-Effekt ohnehin)
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            if actor:IsValid() then setFrozen(actor, false) end
        end)
    end)
    pending = nil
end

-- ---------------------------------------------------------------- Public API

function Evolution.check()
    local actor, param, pair, level = findEligible()
    if not actor then
        if not pending then Log("Kein entwickelbarer eigener Pal aussummont") end
        return
    end
    local now = os.clock()
    local key = ""
    pcall(function() key = param:GetFullName() end)
    if pending and pending.key == key and (now - pending.armedAt) <= Config.confirmWindowSeconds then
        performEvolution(pending)
        return
    end
    pending = { actor = actor, param = param, pair = pair, armedAt = now, key = key }
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
    local count = 0
    local all = FindAllOf("PalIndividualCharacterParameter") or {}
    for _, p in ipairs(all) do
        if p:IsValid() and isOwned(p) and p:GetCharacterID():ToString() == last.to then
            pcall(function()
                p.SaveParameter.CharacterID = FName(last.from)
                p.SaveParameterMirror.CharacterID = FName(last.from)
            end)
            count = count + 1
            break
        end
    end
    saveSnapshots()
    Log(string.format("Rollback %s -> %s: %d Pal(s) zurueckgesetzt (neu aussummonen)",
        last.to, last.from, count))
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

    -- Level-Up-Benachrichtigung: meldet, sobald ein eigener Pal die Schwelle erreicht
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
