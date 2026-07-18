-- Palvolve finale recipes: pure data for the layered grand finale that
-- finale.lua schedules over the reveal window (grow + finale hold).
-- No engine calls in this file.
--
-- Layering: a BASE layer identical for every pal (reveal light column,
-- grown flash, afterglow) plus an ELEMENT layer from the target form's
-- elements - element 1 supplies the centerpiece, element 2 the accents and
-- the ring salvo (mono-element pals use element 1 for both).
--
-- Every asset slot is a CANDIDATE CHAIN: the first path that resolves in
-- the running build wins. The chain implicitly continues with
-- hitBursts[element] -> hitBursts.Normal -> RETURN_NS, so a slot can
-- degrade but never go silent. Candidate entries are either a plain path
-- string or a table { path=..., rotation=..., scale=..., killAfterMs=... }
-- whose fields override the spec while that candidate is the winner.
--
-- Event spec fields (times in ms, distances in world units):
--   at         = { anchor = "reveal"|"grown"|"midHold", plus = ms }
--                reveal = start of the grow, grown = pal snaps to full size
--   pattern    = "center" | "ring" | "cluster" | "column"
--   count      = spawns for ring/cluster/column (center ignores it)
--   radius     = "fr" | number; "fr" resolves ctx.finaleRadius (MP seam)
--   radiusMul  = multiplier on the resolved radius
--   z          = "fzA" | "fzB" | number. For center/ring a fixed height
--                offset; for cluster the step of a z-stack CENTERED on the
--                anchor; for column the step of a beam rising from the
--                anchor
--   rise       = extra height per spawn for center/ring (climbing accents)
--   stagger    = ms between the spawns of one pattern (0 = salvo)
--
-- Vertical anchoring (resolved in finale.lua): reveal-anchored events
-- measure from the GROUND at the evolution spot (the pal is still tiny),
-- grown/midHold-anchored events from the grown pal's center. All distances
-- and radii are authored for a reference capsule half-height of 80 and are
-- scaled to the target species' size at build time.
--   scale      = number or {x,y,z}; best effort, some systems ignore it
--   rotation   = { pitch=, yaw=, roll= } (e.g. pitch=90 aims projectile
--                systems upward)
--   candidates = { entry, ... } or nil (nil = the element's hit burst)
--   looping    = true marks a system that never ends on its own:
--                killAfterMs becomes mandatory and the spec is dropped
--                entirely when component capture is unavailable
--   killAfterMs= deactivate the spawned component this long after spawn
--                (best effort - ignored when the component could not be
--                captured, unless looping is set)
--
-- Candidate paths come from the object dumps of build 24088745 and are
-- confirmed/pruned by the live probe pass (probes.lua NUM_ONE) against the
-- running build before final tuning.

local R = {}

-- Vanilla element hit effects, the proven per-element burst tier; keys
-- match the element names from elements.lua. Also the implicit fallback
-- tier of every candidate chain.
R.hitBursts = {
    Normal      = "/Game/Pal/Effect/Common/Hit/Hit01/NS_Hit01Max.NS_Hit01Max",
    Fire        = "/Game/Pal/Effect/Common/Hit/Hit01Fire/NS_Hit01Fire.NS_Hit01Fire",
    Water       = "/Game/Pal/Effect/Common/Hit/Hit01Water/NS_Hit01Water.NS_Hit01Water",
    Leaf        = "/Game/Pal/Effect/Common/Hit/Hit01_grass/NS_Hit01_grass.NS_Hit01_grass",
    Electricity = "/Game/Pal/Effect/Common/Hit/Hit01Thunder/NS_Hit01Thunder_M.NS_Hit01Thunder_M",
    Ice         = "/Game/Pal/Effect/Common/Hit/Hit01Ice/NS_Hit01Ice.NS_Hit01Ice",
    Earth       = "/Game/Pal/Effect/Common/Hit/Hit01_earth/NS_Hit01earth.NS_Hit01earth",
    -- NS_Hit01dark is practically invisible (live test 18.07.2026); the
    -- Dark Ball skill impact is the visible dark burst tier instead
    Dark        = "/Game/Pal/Effect/Skill/DarkBall/NS_CommonSkill_DarkBall_Hit.NS_CommonSkill_DarkBall_Hit",
    Dragon      = "/Game/Pal/Effect/Common/Hit/Hit01_dragon/NS_Hit01_dragon.NS_Hit01_dragon",
}

-- Vanilla recall light (always resident, scale-safe, no color parameter);
-- terminal fallback of every chain and the only asset the base layer uses.
R.RETURN_NS = "/Game/Pal/Effect/Common/Return/NS_Return.NS_Return"

-- Plug-in seam for a future NS_PalvolveReform LogicMods pak: an entry here
-- is prepended to that element's centerpiece chain and probed exactly like
-- a vanilla asset, so shipping without the pak costs nothing.
-- Example:
--   Fire = "/Game/Mods/Palvolve/NS_PalvolveReform_Fire.NS_PalvolveReform_Fire",
R.moduleOverrides = {}

-- BASE layer, identical for every pal. The t=0 center flash is NOT listed
-- here: fx.lua keeps its own spawnLight at reveal (it must also fire on the
-- legacy fallback path).
R.base = {
    -- rising light column right after the reveal flash (kept tight: tall
    -- stacks read as detached lights floating above small pals)
    { at = { anchor = "reveal", plus = 0 },   pattern = "column", count = 3, z = 70, stagger = 120,
      candidates = { R.RETURN_NS } },
    -- flash the moment the pal snaps to full size
    { at = { anchor = "grown", plus = 0 },    pattern = "center",
      candidates = { R.RETURN_NS } },
    -- NO generic events after the grown moment: a delayed base-layer echo
    -- read as effects "running once more" after the pal had fully appeared
    -- (live feedback 18.07.2026) - the element layer owns the ending
}

-- Shared element-layer geometry. Accents climb around the growing pal
-- (element 2), the ring is the full-size salvo, the cluster is the
-- centerpiece tier for elements without a confirmed showy candidate
-- (still clearly richer than the old single burst).
local ACCENTS = { at = { anchor = "reveal", plus = 400 }, pattern = "ring",
    count = 4, radius = "fr", z = "fzA", rise = 45, stagger = 550 }
local RING = { at = { anchor = "grown", plus = 50 }, pattern = "ring",
    count = 6, radius = "fr", radiusMul = 1.5, z = "fzA", stagger = 0 }
local CLUSTER = { at = { anchor = "grown" }, pattern = "cluster",
    count = 3, z = 70, stagger = 120 }

R.elements = {
    Fire = {
        centerpiece = { at = { anchor = "grown" }, pattern = "center", candidates = {
            "/Game/Pal/Effect/CoopSkill/FlamedExplosion/NS_CoopSkill_FlamedExplosion.NS_CoopSkill_FlamedExplosion",
            { path = "/Game/Pal/Effect/Skill/FireBall/NS_CommonSkill_FireBall.NS_CommonSkill_FireBall",
              rotation = { pitch = 90 }, killAfterMs = 1500 },
        } },
        accents = ACCENTS, ring = RING,
    },
    -- The LegendDeer BarrierRelease explosions were tried here and removed
    -- again (18.07.2026 live test): they are building-sized boss domes that
    -- drown the whole finale, and Niagara scale is not reliable enough to
    -- shrink them.
    Water = {
        centerpiece = { at = { anchor = "grown" }, pattern = "center", candidates = {
            { path = "/Game/Pal/Effect/Skill/WaterGun/NS_WaterGun.NS_WaterGun",
              rotation = { pitch = 90 }, killAfterMs = 1500 },
        } },
        accents = ACCENTS, ring = RING,
    },
    Electricity = {
        centerpiece = { at = { anchor = "grown" }, pattern = "center", candidates = {
            "/Game/Pal/Effect/Skill/ThunderRain/NS_LightningStrike.NS_LightningStrike",
            { path = "/Game/Pal/Effect/Common/RaidBoss/NS_RaidBossModeChange_Electric.NS_RaidBossModeChange_Electric",
              killAfterMs = 2500 },
        } },
        accents = ACCENTS, ring = RING,
    },
    Ice = {
        centerpiece = { at = { anchor = "grown" }, pattern = "center", candidates = {
            "/Game/Pal/Effect/Skill/IceBlade/NS_CommonSkill_IceBlade.NS_CommonSkill_IceBlade",
            { path = "/Game/Pal/Effect/Common/RaidBoss/NS_RaidBossModeChange_Ice.NS_RaidBossModeChange_Ice",
              killAfterMs = 2500 },
        } },
        accents = ACCENTS, ring = RING,
    },
    -- Leaf centerpiece: cluster tier until a right-sized leaf skill VFX is
    -- found (BarrierRelease_Grass removed, see the Water note above).
    Leaf = { centerpiece = CLUSTER, accents = ACCENTS, ring = RING },
    -- Dark, tuned across three live rounds (18.07.2026): Hit01dark is
    -- invisible (globally replaced by DarkBall_Hit above), the Baphomet
    -- shield reads as a fire-pal bubble, and the Darkness mist works as
    -- AMBIENCE but not as the money shot. Composition: dark pillar
    -- explosion centerpiece (pak-listed skill tree), DarkBall_Hit accents
    -- via the burst tier, mist-plume ring on kill deadlines.
    Dark = {
        centerpiece = { at = { anchor = "grown" }, pattern = "center", candidates = {
            "/Game/Pal/Effect/Skill/WhiteDeer/DarkPillar/NS_UniqueSkill_WhiteDeer_Dark_DarkPillar_Explosion.NS_UniqueSkill_WhiteDeer_Dark_DarkPillar_Explosion",
            "/Game/Pal/Effect/Skill/DarkCanon/NS_CommonSkill_DarkCanon_Impact.NS_CommonSkill_DarkCanon_Impact",
        } },
        accents = { at = { anchor = "reveal", plus = 400 }, pattern = "ring",
            count = 5, radius = "fr", z = "fzA", rise = 45, stagger = 440 },
        ring = { at = { anchor = "grown", plus = 50 }, pattern = "ring",
            count = 5, radius = "fr", radiusMul = 1.2, z = "fzA", stagger = 120,
            candidates = {
                { path = "/Game/Pal/Effect/Common/StatusEffect/Darkness/NS_Status_Darkness.NS_Status_Darkness",
                  looping = true, killAfterMs = 1100 },
            } },
    },
    -- No showy candidate confirmed for these yet (candidate search tracked
    -- as a follow-up): their centerpiece is a z-stacked cluster of their
    -- own hit burst.
    Earth  = { centerpiece = CLUSTER, accents = ACCENTS, ring = RING },
    Dragon = { centerpiece = CLUSTER, accents = ACCENTS, ring = RING },
    Normal = { centerpiece = CLUSTER, accents = ACCENTS, ring = RING },
}

-- Used when element data names something not in R.elements.
R.defaultElement = { centerpiece = CLUSTER, accents = ACCENTS, ring = RING }

return R
