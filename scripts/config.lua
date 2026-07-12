-- Palvolve-Konfiguration: Evolutions-Map und Einstellungen.
-- Kategorien: "evolution" (kleine -> grosse Form), "funchain" (ueber Familiengrenzen),
-- "adaptation" (Elementwechsel; erst mit Adaptionsstein in v1 aktiv).
-- stone: "evolution" | "adaptation" - Item-Kosten greifen erst, wenn die PalSchema-Steine
-- existieren (requireStone=false solange).

local Config = {
    -- Zweistufiger Confirm: erster Druck prueft und meldet, zweiter Druck bestaetigt.
    confirmKey = "F2",
    confirmWindowSeconds = 10,
    debounceSeconds = 0.5,

    -- IV-Bonus pro Evolutionsstufe (auf Talent_HP/Melee/Shot/Defense, Cap 100)
    ivBonusPerStage = 5,
    ivCap = 100,

    -- Item-Kosten aktivieren, sobald die Steine existieren (M2)
    requireStone = false,
    stoneItemIds = {
        evolution = "Palvolve_EvolutionStone",
        adaptation = "Palvolve_AdaptionStone",
    },

    -- Schema-Version der Map (fuer spaetere Migrationen)
    schemaVersion = 1,
    gameBuild = 24088745,

    map = {
        { from = "Penguin",  to = "CaptainPenguin", category = "evolution", minLevel = 30, stone = "evolution", enabled = true },
        { from = "MopBaby",  to = "MopKing",        category = "evolution", minLevel = 25, stone = "evolution", enabled = true },
        { from = "MopKing",  to = "Yeti",           category = "funchain",  minLevel = 45, stone = "evolution", enabled = true },
        -- Adaptationen folgen kuratiert mit M2 (Adaptionsstein), z.B.:
        -- { from = "Mau", to = "Mau_Cryst", category = "adaptation", minLevel = 30, stone = "adaptation", enabled = false },
    },
}

function Config.findPair(characterId)
    for _, pair in ipairs(Config.map) do
        if pair.enabled and pair.from == characterId then
            return pair
        end
    end
    return nil
end

return Config
