-- Palvolve prestige recipes: one effect programme per prestige stage, pure data.
-- No engine calls in this file.
--
-- The SEQUENCE is the same one an evolution runs - spin up, shrink, swap, grow,
-- hold. Only the effects differ, and this file is the whole of that difference.
--
-- Ten stages, because the prestige passive ladder carries ten
-- (palpassives.lua, LADDERS.prestige.maxStage). Stage N is what the Pal's Nth
-- prestige looks like, so every prestige outdoes the one before it.
--
-- ADDITIVE, NOT COPIED: a stage lists only what it ADDS, and Stages() returns
-- stage N as stages 1..N concatenated. A correction to stage 2 therefore
-- reaches stages 2 through 10 without being pasted eight times, and the
-- escalation stays readable as the diff it is.
--
-- Beat vocabulary is finale_recipes.lua's, unchanged: at.anchor, pattern, count,
-- radius, radiusMul, z, rise, stagger, scale, rotation, candidates, looping,
-- killAfterMs. Every beat additionally carries a `name`, which is what
-- `!palvolve prestige <stage> <name>` plays in isolation.
--
-- Asset paths are verified against the shipped pak index of build 24467282.
-- Every one still runs through the candidate chain in finale.lua, so a path a
-- patch removes degrades to the hit burst rather than going silent.

local P = {}

local RAID = "/Game/Pal/Effect/Common/RaidBoss/"
local COMMON = "/Game/Pal/Effect/Common/"

-- Stage 1 is what shipped as R.prestige: the raid boss vocabulary, one
-- composition, nothing that touches the world outside the viewer.
P.stages = {
    {
        title = "Awakened",
        beats = {
            { name = "modechange", at = { anchor = "reveal", plus = 0 },
              pattern = "center", scale = 0.85,
              candidates = { RAID .. "NS_RaidBossModeChange.NS_RaidBossModeChange" } },
            { name = "comets", at = { anchor = "reveal", plus = 300 },
              pattern = "ring", count = 6, radius = "fr", radiusMul = 3.0,
              z = "fzB", stagger = 140, scale = 0.7,
              candidates = { RAID .. "NS_RaidBoss_Summon_Comet.NS_RaidBoss_Summon_Comet" } },
            { name = "rise", at = { anchor = "reveal", plus = 650 },
              pattern = "center", z = "fzA", scale = 1.0,
              candidates = { COMMON .. "LevelUp/NS_LevelUp_Pal.NS_LevelUp_Pal" } },
            -- looping, so the deadline is what ends it, and it is short enough
            -- to finish inside the hold
            { name = "aura", at = { anchor = "grown", plus = -650 },
              pattern = "center", scale = 0.8,
              candidates = {
                  { path = COMMON .. "AwakeningAura/NS_AwakeningAura.NS_AwakeningAura",
                    looping = true, killAfterMs = 1400 },
              } },
            { name = "impact", at = { anchor = "grown", plus = 0 },
              pattern = "center", scale = 0.8,
              candidates = { RAID .. "NS_RaidBoss_Summon_Impact.NS_RaidBoss_Summon_Impact" } },
        },
    },

    {
        title = "Awakened II",
        beats = {
            { name = "appear", at = { anchor = "reveal", plus = 120 },
              pattern = "center", scale = 0.7,
              candidates = { COMMON .. "PalCatch/NS_PalAppear_Boss.NS_PalAppear_Boss" } },
        },
    },

    {
        title = "Ascendant",
        beats = {
            { name = "bossaura", at = { anchor = "grown", plus = -900 },
              pattern = "center", scale = 0.75,
              candidates = {
                  { path = COMMON .. "BossAura/NS_BossAura.NS_BossAura",
                    looping = true, killAfterMs = 1800 },
              } },
            { name = "statusup", at = { anchor = "grown", plus = 200 },
              pattern = "center", scale = 0.7,
              candidates = {
                  { path = COMMON .. "BossAura/NS_StatusUpAura.NS_StatusUpAura",
                    looping = true, killAfterMs = 1200 },
              } },
        },
    },

    {
        title = "Ascendant II",
        beats = {
            -- NOT the dungeon gate here. NS_DungeonGate_Boss is a barrier: it
            -- draws a flat red wall, which is exactly its job at a dungeon
            -- entrance and exactly wrong around a transforming Pal.
            { name = "ringlow", at = { anchor = "reveal", plus = 200 },
              pattern = "ring", count = 5, radius = "fr", radiusMul = 1.4,
              z = "fzA", stagger = 110, scale = 0.6,
              candidates = { RAID .. "NS_RaidBoss_Summon_Impact.NS_RaidBoss_Summon_Impact" } },
        },
    },

    {
        title = "Mythic",
        beats = {
            { name = "summon", at = { anchor = "reveal", plus = 450 },
              pattern = "ring", count = 4, radius = "fr", radiusMul = 1.8,
              stagger = 180, scale = 0.75,
              candidates = { RAID .. "NS_RaidBoss_Summon_00.NS_RaidBoss_Summon_00" } },
        },
    },

    {
        title = "Mythic II",
        beats = {
            { name = "deerchange", at = { anchor = "grown", plus = -300 },
              pattern = "center", scale = 0.65,
              candidates = { RAID .. "NS_RaidBoss_LegendDeer_ModeChange.NS_RaidBoss_LegendDeer_ModeChange" } },
        },
    },

    {
        title = "Celestial",
        beats = {
            { name = "meteor", at = { anchor = "grown", plus = 120 },
              pattern = "ring", count = 3, radius = "fr", radiusMul = 2.4,
              stagger = 220, scale = 0.7,
              candidates = { "/Game/Pal/Effect/Skill/DragonMeteor/NS_CommonSkill_DragonMeteor_Explosion.NS_CommonSkill_DragonMeteor_Explosion" } },
        },
    },

    {
        title = "Celestial II",
        beats = {
            { name = "purge", at = { anchor = "grown", plus = 400 },
              pattern = "center", scale = 0.6,
              candidates = { "/Game/Pal/Effect/Skill/LegendDeer/RadiantPurge/NS_UniqueSkill_LegendDeer_RadiantPurge_Explosion.NS_UniqueSkill_LegendDeer_RadiantPurge_Explosion" } },
        },
    },

    {
        title = "Apotheosis",
        beats = {
            { name = "worldtree", at = { anchor = "grown", plus = 0 },
              pattern = "center", scale = 0.8,
              candidates = { "/Game/Pal/Effect/CutScene/WorldTreeBossStart/NS_WorldTreeBossStart_Burst.NS_WorldTreeBossStart_Burst" } },
        },
    },

    {
        title = "Apotheosis II",
        beats = {
            { name = "echo", at = { anchor = "midHold", plus = -400 },
              pattern = "ring", count = 8, radius = "fr", radiusMul = 3.6,
              stagger = 90, scale = 0.65,
              candidates = { RAID .. "NS_RaidBoss_Summon_Comet.NS_RaidBoss_Summon_Comet" } },
        },
    },
}

P.maxStage = #P.stages

local function clampStage(stage)
    local n = math.floor(tonumber(stage) or 1)
    if n < 1 then return 1 end
    if n > P.maxStage then return P.maxStage end
    return n
end

--- Every beat of stage `stage`, which is stages 1..stage concatenated.
--- Order is stage order, so a later stage's beats sort after the earlier ones
--- at the same anchor time. finale.lua sorts by time afterwards anyway.
function P.beatsFor(stage)
    local n = clampStage(stage)
    local out = {}
    for i = 1, n do
        for _, beat in ipairs(P.stages[i].beats) do
            out[#out + 1] = beat
        end
    end
    return out
end

--- One named beat, for judging a single scale or anchor in isolation.
function P.beatNamed(stage, name)
    for _, beat in ipairs(P.beatsFor(stage)) do
        if beat.name == name then return { beat } end
    end
    return nil
end

--- "1 Awakened (5)  2 Awakened II (+1)  ..." for the chat listing.
function P.describe()
    local parts = {}
    for i, s in ipairs(P.stages) do
        parts[#parts + 1] = string.format("%d %s (+%d)", i, s.title, #s.beats)
    end
    return table.concat(parts, "  ")
end

return P
