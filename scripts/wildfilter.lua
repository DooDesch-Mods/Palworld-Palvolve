-- Palvolve wild level limit ("devolve mode"): a WILD pal must never spawn as a
-- species its rolled level could not legitimately have reached. Every wild
-- spawn (overworld spawner lottery AND dungeon spawners - both derive from
-- APalNPCSpawnerBase) funnels through PalUtility's character-DB build family
-- BEFORE any actor exists, so a PRE-hook that rewrites the CharacterID param
-- makes stats/actor-class/moves/passives all follow the corrected species for
-- free.
--
--   mode "devolve" (default) - walk the chain down to the stage the level does
--     allow and rewrite the species to it.
--   mode "levelFloor"        - leave the species and instead raise the level to
--     that species' floor.
--
-- Gender-faithful wild spawns (genderFaithful, on by default) ride the same
-- choke point from the POST side: gender persists through evolution in this
-- mod, so a species whose ENTIRE ancestry demands one gender can only
-- legitimately exist as that gender - a wild male Vanwyrm is exactly as
-- illegitimate as an under-levelled one. The post-hook reads the species AFTER
-- the pre-hook's possible devolve rewrite (so the constraint always lands on
-- the FINAL species) and corrects Gender in the save parameter, still before
-- any actor exists.
--
-- Three variants of the build carry the same first six params, so one handler
-- family serves all of them:
--   GetInitializedCharacterSaveParemter                    (misspelled in game)
--   GetInitializedCharacterSaveParemter_PassiveSkillList
--   GetInitializedCharacterSaveParemter_NPCOtomo           (v1.7.2, NPC-companion
--     pals - settlement guards'/merchants' pals lottery like wilds but build
--     through this initializer; switch: wildLevelLimit.npcOtomo, registered
--     best-effort so its absence never disarms the proven hooks)
-- _ParamSetup is deliberately NOT rewritten (its explicit WazaList/StatusRank
-- are curated scripted spawns a species swap would desync, and its inserted
-- TalentLevel param breaks the shared positional bindings anyway). In devMode
-- a log-only post-hook on _ParamSetup records its fires so its field pattern
-- can be learned. Unique (story) NPCs' authored companions are exempt on every
-- variant.
--
-- Authority-side only (host/dedicated server): wild pals are world simulation,
-- clients just see the result replicate. Depends only on config/role/
-- servercheck/boss_static - never on evolution.lua (though on a non-dedicated
-- host the gate only opens once servercheck classifies the world LOCAL, and
-- main.lua initializes servercheck alongside the evolution core).
local Config = require("config")
local Role = require("role")
local ServerCheck = require("servercheck")
local okBoss, BossSet = pcall(require, "boss_static")
if not okBoss then BossSet = nil end

local WildFilter = {}

local function Log(msg)
    print(string.format("[Palvolve] %s\n", msg))
end

-- Retry budget for hook registration: PalUtility is a /Script/Pal native so
-- registration takes on the first attempt in practice; this only bounds the
-- rare late-load retry before failing closed.
local HOOK_RETRY_BUDGET = 12 -- ~1 minute at the 5s cadence below

-- EPalGenderType, quoted from
-- PalworldModdingKit\Source\Pal\Public\EPalGenderType.h:
--     enum class EPalGenderType : uint8 {
--         None,
--         Male,
--         Female,
--     };
-- i.e. None = 0, Male = 1, Female = 2 - the same pair conditions.lua compares
-- GetGenderType() against for isMale/isFemale.
local GENDER_MALE, GENDER_FEMALE = 1, 2

-- ---- module state (declared ABOVE every closure that captures it) ----------
local enabled = false      -- armed flag; latched false on init/registration failure (fail closed)
local mode = "devolve"     -- "devolve" | "levelFloor"
local exemptAlphas = true  -- BOSS_ (Alpha) spawns skipped when true
local parents = {}         -- parents[to] = { { from, minLevel, gender = g|nil, conflict }, ... }
local floors = {}          -- floors[X] = minimum level to legitimately BE X (absent = root / un-gated = 0)
local bestParent = {}      -- bestParent[X] = the `from` on X's cheapest ancestry path (settle-order: acyclic)
local cycleSeen = false    -- some species' every ancestry path was cyclic (left un-gated)
local fires = 0            -- devMode telemetry: hook fires this window
local rewrites = 0         -- devMode telemetry: rewrites this window
local genderFaithful = true -- own flag for the gender fix (still under `enabled`)
local requiredGender = {}   -- requiredGender[X] = GENDER_MALE|GENDER_FEMALE (absent = unconstrained)
local genderCount = 0       -- constrained species in the map (0 = the fix is inert)
local genderConflict = false -- some pair demands BOTH isMale and isFemale (constrains nothing)
local genderDiverged = false -- the mask pass hit its insurance bound (constraints discarded)
local genderBroken = false  -- struct access threw / the write did not stick: off for the session
local genderProven = false  -- the FIRST write's read-back has been reported (once, any mode)
local genderRvWarned = false -- the trailing return value could not be read (reported once)
local genderFixes = 0       -- devMode telemetry: gender corrections ATTEMPTED this window
local genderVerified = 0    -- devMode telemetry: of those, the ones the read-back confirmed

-- Alpha handling, mirroring evolution.lua's baseCharacterId: the pair map uses
-- base ids while alpha spawns carry a BOSS_ prefix. Returns (baseId, isAlpha).
local BOSS_PREFIX = "BOSS_"
local BOSS_PREFIX_LEN = #BOSS_PREFIX
local function baseId(rawId)
    if rawId:sub(1, BOSS_PREFIX_LEN) == BOSS_PREFIX then
        return rawId:sub(BOSS_PREFIX_LEN + 1), true
    end
    return rawId, false
end

-- floor(X): the minimum level at which a pal may legitimately BE species X -
-- the cheapest ancestry path's gating level. Precomputed by buildMap; absent
-- means root / un-gated.
local function floorOf(id)
    return floors[id] or 0
end

-- Descend the best-parent chain from `species` until a stage whose floor the
-- `level` already satisfies. bestParent edges follow valid (acyclic) ancestry
-- and always reach a floor-0 root, so this terminates; the counter is pure
-- insurance against any residual cycle.
local function devolveTarget(species, level)
    local cur = species
    local guard = 0
    while floorOf(cur) > level do
        local p = bestParent[cur]
        if not p then break end
        cur = p
        guard = guard + 1
        if guard > 64 then break end
    end
    -- a broken walk (guard trip / missing parent) must never emit a stage the
    -- level still cannot hold - not rewriting beats rewriting wrong
    if floorOf(cur) > level then return species end
    return cur
end

-- Precompute parents / floors / best-parent chain from Config.map ONCE. The
-- config_user overlay has already replaced Config.map wholesale by now (it runs
-- during config.lua load, before init), so this sees the final pairs.
local function buildMap(includeAdaptations)
    parents, floors, bestParent, cycleSeen = {}, {}, {}, false
    requiredGender, genderCount, genderConflict, genderDiverged = {}, 0, false, false
    for _, pair in ipairs(Config.map) do
        if pair.enabled ~= false then
            local cat = pair.category
            -- evolution parents always; adaptation parents when included;
            -- funchain NEVER (matches the egg filter's ancestry semantics)
            if cat == "evolution" or (includeAdaptations and cat == "adaptation") then
                -- the pair's OWN gender demand, read from the same condition ids
                -- conditions.lua evaluates at evolve time. Because the parents
                -- list is already category-filtered, an adaptation pair's gender
                -- condition counts exactly when adaptations are included. A pair
                -- demanding BOTH is unsatisfiable - it is flagged per-edge so the
                -- mask pass can treat it as vacuous (no individual ever arrives
                -- through it, so it delivers nothing at all, not even its
                -- parent's gender) and reported once at init.
                local pg, pConflict = nil, false
                local conds = pair.conditions
                -- A single-member anyOf group is an AND term in disguise - its
                -- gender demand is as hard as one in `conditions`, so it joins
                -- the scan (via a copy: the pair's own lists are shared by
                -- reference). Multi-member groups stay invisible here BY
                -- DESIGN: satisfiable through another member, they demand no
                -- gender, and rewriting wild spawns for one would be wrong.
                local group = pair.anyOf
                if type(group) == "table" and #group == 1 then
                    local merged = {}
                    for _, c in ipairs(conds or {}) do table.insert(merged, c) end
                    table.insert(merged, group[1])
                    conds = merged
                end
                if conds then
                    local wantsMale, wantsFemale = false, false
                    for _, c in ipairs(conds) do
                        -- Since 1.7.0 any condition may carry a leading "!", and
                        -- EPalGenderType has exactly two live values - so "!isMale"
                        -- is a female demand and "!isFemale" a male one. Matching
                        -- only the bare ids would leave a negated edge recorded as
                        -- un-gendered: the species would keep its random roll and
                        -- every wild individual arriving through that edge would be
                        -- rejected by the evolve-time gate, so the target form
                        -- would never appear in the wild at all.
                        if c == "isMale" or c == "!isFemale" then wantsMale = true
                        elseif c == "isFemale" or c == "!isMale" then wantsFemale = true end
                    end
                    if wantsMale and wantsFemale then
                        genderConflict = true
                        pConflict = true
                    elseif wantsMale then pg = GENDER_MALE
                    elseif wantsFemale then pg = GENDER_FEMALE end
                end
                local list = parents[pair.to]
                if not list then list = {}; parents[pair.to] = list end
                -- the edge stays in `parents` regardless: the devolve floors are
                -- shipped semantics and this changes nothing about them
                table.insert(list, { from = pair.from, minLevel = pair.minLevel,
                    gender = pg, conflict = pConflict })
            end
        end
    end
    -- Settle-order relaxation (Dijkstra with path cost = the LARGEST minLevel
    -- along the path; floor = min of that over all ancestry paths). Each round
    -- settles the globally cheapest still-open species, and a species may only
    -- settle through a parent that is a root or already settled - so bestParent
    -- edges can never form a cycle, and no value is ever cached from a
    -- half-explored context (the flaw in a naive memoized DFS). Species whose
    -- every path is cyclic never settle: they keep floor 0 and are simply
    -- never rewritten (a broken map fails open).
    local settled = {}
    local settleOrder = {} -- settled species in settle order (the gender pass reuses it)
    local unsettledCount = 0
    for _ in pairs(parents) do unsettledCount = unsettledCount + 1 end
    while unsettledCount > 0 do
        local pickId, pickFloor, pickFrom = nil, nil, nil
        for to, plist in pairs(parents) do
            if not settled[to] then
                for _, p in ipairs(plist) do
                    -- usable parent = settled, or a root (no parents entry)
                    if settled[p.from] or not parents[p.from] then
                        local need = p.minLevel or 1
                        local pf = floors[p.from] or 0
                        if pf > need then need = pf end
                        if pickFloor == nil or need < pickFloor then
                            pickId, pickFloor, pickFrom = to, need, p.from
                        end
                    end
                end
            end
        end
        if pickId == nil then break end -- the rest are all-cyclic
        settled[pickId] = true
        table.insert(settleOrder, pickId)
        floors[pickId] = pickFloor
        bestParent[pickId] = pickFrom
        unsettledCount = unsettledCount - 1
    end
    if unsettledCount > 0 then cycleSeen = true end

    -- ---- requiredGender: species the map can only legitimately produce as one
    -- gender. A pair's gender condition constrains the individual evolving
    -- through THAT hop, and gender persists across hops, so each in-edge of X
    -- delivers either the edge's own demanded gender or - lacking one - whatever
    -- its parent already is. X is constrained only when every in-edge delivers
    -- the SAME single gender; roots are unconstrained, and one unconstrained
    -- in-edge is enough to leave X unconstrained too.
    --
    -- The state is the 4-point lattice 0 (nothing yet) < MASK_MALE / MASK_FEMALE
    -- < MASK_EITHER (unconstrained), and every join only moves UP it. Settle
    -- order reaches a child right after its CHEAPEST parent, but a costlier
    -- in-edge's parent can settle later, so a single pass would read that parent
    -- as still-unknown - hence the pass repeats until nothing moves. Starting
    -- every species at 0 is what stops a cycle among settled species from
    -- bootstrapping a constraint out of itself.
    local MASK_MALE, MASK_FEMALE, MASK_EITHER = 1, 2, 3
    local mask = {}
    -- species whose EVERY in-edge is unsatisfiable: unconstrained themselves
    -- (their fixpoint mask stays 0), but their OWN out-edges must impose
    -- EITHER on children - wild spawns of both genders are legitimate for
    -- them, so a child must not end up single-gendered on the strength of its
    -- other edges alone (the over-constrain direction this feature forbids)
    local allVacuous = {}
    for id, plist in pairs(parents) do
        local vac = true
        for _, p in ipairs(plist) do
            if not p.conflict then vac = false; break end
        end
        if vac then allVacuous[id] = true end
    end
    local function join(a, b)
        if a == 0 then return b end
        if b == 0 then return a end
        if a == b then return a end
        return MASK_EITHER
    end
    local function maskOf(id)
        -- a root, or an all-cyclic species that never settled: imposes nothing
        if not (parents[id] and settled[id]) then return MASK_EITHER end
        -- all-vacuous species contribute EITHER, never their raw 0 (which
        -- mid-iteration is reserved for "not yet computed")
        if allVacuous[id] then return MASK_EITHER end
        return mask[id] or 0
    end
    local moved, rounds = true, 0
    while moved do
        moved = false
        rounds = rounds + 1
        if rounds > 64 then genderDiverged = true; break end -- insurance only (masks grow)
        for _, id in ipairs(settleOrder) do
            local m = 0
            for _, p in ipairs(parents[id]) do
                -- an unsatisfiable pair is vacuous: skipped entirely, so it
                -- cannot smuggle its parent's gender in as if it were an
                -- ordinary un-gendered edge
                if not p.conflict then
                    if p.gender == GENDER_MALE then
                        m = join(m, MASK_MALE)
                    elseif p.gender == GENDER_FEMALE then
                        m = join(m, MASK_FEMALE)
                    else
                        m = join(m, maskOf(p.from))
                    end
                    if m == MASK_EITHER then break end -- top of the lattice, cannot narrow again
                end
            end
            if m ~= (mask[id] or 0) then mask[id] = m; moved = true end
        end
    end
    if genderDiverged then
        -- Masks were still climbing when the bound tripped. Because the
        -- iteration starts at the BOTTOM, an intermediate mask claims FEWER
        -- possible genders than reality - publishing it would OVER-constrain,
        -- forcing a gender on a species that is legitimately either. That is the
        -- one failure direction this feature must never have, so a non-converged
        -- pass yields nothing at all and the fix goes inert (fail open, exactly
        -- like the cyclic-map path).
        requiredGender, genderCount = {}, 0
    else
        for _, id in ipairs(settleOrder) do
            local m = mask[id]
            -- mask 0 = every in-edge was vacuous: nothing can legitimately reach
            -- this species, so nothing is forced on it either
            if m == MASK_MALE then
                requiredGender[id] = GENDER_MALE
                genderCount = genderCount + 1
            elseif m == MASK_FEMALE then
                requiredGender[id] = GENDER_FEMALE
                genderCount = genderCount + 1
            end
        end
    end
end

-- Shared handler for the rewrite variants (identical first six params - the
-- header shares WorldContextObject, CharacterID, UniqueNPCID, Level,
-- OwnerPlayerUId, outParameter across plain, _PassiveSkillList AND _NPCOtomo;
-- only _ParamSetup deviates, which is why it stays log-only). Cheap
-- early-outs run in the spec's order so the common non-target spawn costs one
-- id read + one table lookup; the real work (guid read, rewrite) is reached
-- only for actual evolution targets and is inner-shielded.
local ownedSkipBudget = 5 -- devMode forensic: make "fired but skipped as
                          -- owned" visible (it used to be indistinguishable
                          -- from "never fired" - the male-Katress lesson)
local uniqueSkipBudget = 5 -- same discipline for the unique-NPC exemption
                           -- line: settlements rebuild their NPCs per area
                           -- reload, and an unbudgeted line would drown the
                           -- receipts this diff exists to collect
local function handleSpawn(CharacterID, Level, OwnerPlayerUId, UniqueNPCID)
    if not enabled then return end
    -- authority gate (pure Lua, cheap), mirroring the primed scanner's: rewrite
    -- only where THIS process owns the world sim. The brief unknown-status
    -- window at world entry is an accepted gap.
    if not (Role.isDedicated() or ServerCheck.getStatus() == "local") then return end
    -- rolled species (the outer pcall in the callback shields a native throw)
    local rawId = CharacterID:get():ToString()
    if type(rawId) ~= "string" or rawId == "" then return end
    local base, isAlpha = baseId(rawId)
    if isAlpha and exemptAlphas then return end
    -- THE hot-path filter: not an evolution target -> done
    if not parents[base] then return end
    -- a real target: the rest is rare, inner-shielded so nothing escapes into
    -- the native caller even past the outer pcall (double shield)
    pcall(function()
        -- a UNIQUE NPC's designed companion is never touched: species, level
        -- and gender are authored (the unique-NPC row can even force gender -
        -- FPalUniqueNPCDatabaseRow.Gender), and rewriting a story character's
        -- pal risks quest state. Wild spawns and generic settlement mobs
        -- carry None here, so this is a no-op for the existing coverage.
        if UniqueNPCID ~= nil then
            local npcId = nil
            pcall(function() npcId = UniqueNPCID:get():ToString() end)
            if npcId ~= nil and npcId ~= "None" and npcId ~= "" then
                if Config.devMode and uniqueSkipBudget > 0 then
                    uniqueSkipBudget = uniqueSkipBudget - 1
                    Log(string.format("[wildfilter] unique-npc skip %s (npc %s)",
                        rawId, npcId))
                end
                return
            end
        end
        -- wildness: any non-zero guid component means an owned pal -> skip
        -- (same test as evolution.lua's isOwned, inverted)
        local g = OwnerPlayerUId:get()
        if not g then return end
        if g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0 then
            if Config.devMode and ownedSkipBudget > 0 then
                ownedSkipBudget = ownedSkipBudget - 1
                Log(string.format("[wildfilter] owned-skip %s guid %s/%s/%s/%s",
                    rawId, tostring(g.A), tostring(g.B), tostring(g.C), tostring(g.D)))
            end
            return
        end
        local level = Level:get()
        if type(level) ~= "number" or level < 1 then return end
        local speciesFloor = floorOf(base)
        if level >= speciesFloor then return end
        if mode == "levelFloor" then
            -- user-map minLevel may be fractional; the param is an int32
            Level:set(math.floor(speciesFloor))
            rewrites = rewrites + 1
            if Config.devMode then
                Log(string.format("[wildfilter] level-floored %s lv %g -> %g",
                    rawId, level, speciesFloor))
            end
            return
        end
        -- devolve (default): drop to the stage the level allows
        local target = devolveTarget(base, level)
        if not target or target == base then return end
        local finalId = target
        if isAlpha then
            -- re-apply BOSS_ ONLY when the devolved species has a real alpha
            -- row (same consult as evolution.lua's alphaTargetId); without one
            -- the spawn class cannot resolve, so leave the spawn untouched
            -- rather than emit an invalid actor
            if BossSet and BossSet[target] then
                finalId = BOSS_PREFIX .. target
            else
                return
            end
        end
        CharacterID:set(FName(finalId))
        rewrites = rewrites + 1
        if Config.devMode then
            Log(string.format("[wildfilter] devolved %s lv %g -> %s (floor %g)",
                rawId, level, finalId, speciesFloor))
        end
    end)
end

-- Registered pre callback (plain + _PassiveSkillList variants). Outer pcall =
-- shield 1; handleSpawn adds shield 2 around the rewrite. A Lua error must
-- never reach the native call.
local function preRewrite(self, WorldContextObject, CharacterID, UniqueNPCID, Level, OwnerPlayerUId)
    fires = fires + 1
    pcall(handleSpawn, CharacterID, Level, OwnerPlayerUId, UniqueNPCID)
end

-- Pre callback for the _NPCOtomo variant (v1.7.2 NPC-companion coverage):
-- the same shared handler, plus a budgeted devMode receipt that settles the
-- male-Katress discrimination in one line - WHICH path settlement pals take,
-- and what owner guid / unique-npc id they carry (if the guid turns out
-- non-zero for NPC pals, the owner gate is the next thing to revisit).
local npcReceiptBudget = 10
local function preRewriteNpc(self, WorldContextObject, CharacterID, UniqueNPCID, Level, OwnerPlayerUId)
    fires = fires + 1
    if Config.devMode and npcReceiptBudget > 0 then
        npcReceiptBudget = npcReceiptBudget - 1
        pcall(function()
            -- every optional field individually guarded into a local: this
            -- receipt is the whole discriminator, and one unreadable field
            -- must not cost the line. Only the CharacterID read can still
            -- lose it (accepted: a receipt without the species is worthless
            -- anyway, and the budget slot is already spent either way).
            local own = "?"
            pcall(function()
                local g = OwnerPlayerUId:get()
                own = string.format("%s/%s/%s/%s",
                    tostring(g.A), tostring(g.B), tostring(g.C), tostring(g.D))
            end)
            local npc = "?"
            pcall(function() npc = UniqueNPCID:get():ToString() end)
            local lv = "?"
            pcall(function() lv = tostring(Level:get()) end)
            Log(string.format("[wildfilter] _NPCOtomo fired: %s lv %s npc=%s owner=%s",
                CharacterID:get():ToString(), lv, npc, own))
        end)
    end
    pcall(handleSpawn, CharacterID, Level, OwnerPlayerUId, UniqueNPCID)
end

-- Gender enforcement, shared by the rewrite variants. Runs POST so the species
-- it reads is the one the pre-hook may have devolved to - the constraint has to
-- land on the FINAL species. Same early-out discipline as handleSpawn: a spawn
-- of an unconstrained species costs one id read, one substring and one table
-- lookup before returning.
local function handleGenderFix(CharacterID, OwnerPlayerUId, outParameter, ReturnValue, UniqueNPCID)
    -- authority gate, identical to preRewrite's
    if not (Role.isDedicated() or ServerCheck.getStatus() == "local") then return end
    local rawId = CharacterID:get():ToString()
    if type(rawId) ~= "string" or rawId == "" then return end
    local base, isAlpha = baseId(rawId)
    if isAlpha and exemptAlphas then return end
    -- THE hot-path filter: the map forces no gender on this species -> done
    local want = requiredGender[base]
    if not want then return end
    -- unique-NPC exemption, mirroring handleSpawn's: an authored companion's
    -- gender is the row's business, and our write could race a data-driven
    -- override (FPalUniqueNPCDatabaseRow.Gender). Deliberately fails OPEN
    -- (a throw inside the guard leaves uniqueSkip false and the write
    -- proceeds): a UniqueNPCID-specific read failure with a healthy
    -- CharacterID read is a narrow structural oddity, and the module's
    -- stance everywhere is fail-open on unreadable optional signals.
    local uniqueSkip = false
    pcall(function()
        if UniqueNPCID == nil then return end
        local npcId = UniqueNPCID:get():ToString()
        uniqueSkip = (npcId ~= nil and npcId ~= "None" and npcId ~= "")
    end)
    if uniqueSkip then return end
    -- rare from here on; inner-shielded so nothing escapes into the native
    -- caller even past the callback's own pcall (double shield)
    --
    -- A build the native reported as failed has nothing worth correcting. This
    -- gets its OWN guard and fails OPEN: only a value actually READ as false
    -- skips. If this build hands the trailing param over in a form that cannot
    -- be read, treating that as "failed" would silently swallow every
    -- correction for the whole session while the banner still advertised the
    -- feature - so an unreadable return value is treated exactly like an absent
    -- one, and says so in the log once.
    if ReturnValue ~= nil then
        local built = nil
        local okRv = true
        if type(ReturnValue) == "boolean" then
            built = ReturnValue
        else
            okRv = pcall(function() built = ReturnValue:get() end)
        end
        if not okRv then
            if not genderRvWarned then
                genderRvWarned = true
                Log("[wildfilter] gender post: return value uninterpretable - "
                    .. "treating builds as successful")
            end
        elseif built == false then
            return
        end
    end
    -- wildness: any non-zero guid component means an owned pal -> skip (same
    -- test as handleSpawn's). Its own guard: a throw here stays a soft skip.
    local isWild = false
    pcall(function()
        local g = OwnerPlayerUId:get()
        if not g then return end
        if g.A ~= 0 or g.B ~= 0 or g.C ~= 0 or g.D ~= 0 then return end
        isWild = true
    end)
    if not isWild then return end
    -- The struct work. Writing a field of an out-REFERENCE struct param from a
    -- post-hook is the one API nothing else in this mod leans on, so the write
    -- is read back and BOTH outcomes are logged: a play-test then proves or
    -- refutes it outright. (The read-back proves the property write reached the
    -- struct UE4SS handed us; only the pal that walks out of the spawner proves
    -- that struct was the native's own.)
    local wantName = (want == GENDER_FEMALE) and "Female" or "Male"
    local okStruct = pcall(function()
        local sp = outParameter:get()
        if not sp then return end
        if sp.Gender == want then return end -- rolled correctly on its own
        sp.Gender = want
        local after = sp.Gender
        local stuck = (after == want)
        genderFixes = genderFixes + 1
        if stuck then genderVerified = genderVerified + 1 end
        -- the FIRST one is logged whatever the mode: devMode ships off, and a
        -- play-test that cannot see this line proves nothing either way
        if Config.devMode or not genderProven then
            genderProven = true
            Log(string.format("[wildfilter] gender-fixed %s -> %s (%s)", rawId, wantName,
                stuck and "verified" or "WRITE DID NOT STICK"))
        end
        if not stuck then
            -- decisive structural evidence that the struct handed to us is not
            -- the one the native keeps: stop retrying a dead write all session
            -- (same fail-closed-on-structural-failure stance as below)
            genderBroken = true
            Log("wild level limit: gender write did not stick - "
                .. "gender-faithful spawns disabled for this session")
        end
    end)
    if not okStruct then
        -- structural surprise (field renamed/inaccessible): soft-disable rather
        -- than throw at every spawn for the rest of the session
        genderBroken = true
        Log("wild level limit: save-parameter Gender unavailable - "
            .. "gender-faithful spawns disabled for this session")
    end
end

-- Registered post callback factory (one instance per rewrite variant). UE4SS
-- hands a post callback the same params as the pre one, and appends the
-- native's return value as one EXTRA trailing param. The repo's other
-- post-hooks on value-returning natives - palpedia.lua on
-- PalUIPaldex:GetFilteredDisplayInfoArray (array), statuspage.lua on
-- PalHUDService:ShowCommonUI (FGuid), and this module's own devMode
-- _ParamSetup diagnostic (bool) - all ignore their trailing params entirely,
-- so none is EVIDENCE of the arity either way (the remaining post-hooks -
-- netchannel's SetSelectOtomoID_ToServer, statuspage's other three,
-- eggfilter's OnFinishWorkInServer pair, palpedia's CreateDisplayInfo,
-- radialmenu's four - are all on void natives). That is exactly why the
-- arity is measured here rather than assumed: guessing wrong would read
-- RarePalAble (a bool, false for nearly every wild spawn) as a failed build and
-- skip every correction. The declared trailing param counts after outParameter
-- come from PalUtility.h:
--   GetInitializedCharacterSaveParemter
--       ... outParameter, DisableRandomPassiveSkill, RarePalAble            -> 2
--   GetInitializedCharacterSaveParemter_PassiveSkillList
--       ... outParameter, DisableRandomPassiveSkill, PassiveSkillList,
--           RarePalAble                                                     -> 3
--   GetInitializedCharacterSaveParemter_NPCOtomo
--       ... outParameter (nothing after it)                                 -> 0
-- so anything beyond that count is the return value; absent it, ReturnValue
-- stays nil and the build is treated as successful (fail open).
local function makeGenderPost(tailCount)
    return function(self, WorldContextObject, CharacterID, UniqueNPCID, Level, OwnerPlayerUId,
                    outParameter, ...)
        -- pure upvalue reads, cheapest possible gate on a hook that fires for
        -- every single spawn
        if not (enabled and genderFaithful) then return end
        if genderBroken or genderCount == 0 then return end
        local n = select("#", ...)
        local rv = nil
        if n > tailCount then rv = select(n, ...) end
        pcall(handleGenderFix, CharacterID, OwnerPlayerUId, outParameter, rv, UniqueNPCID)
    end
end

-- devMode-only log post-hook on _ParamSetup: learn its fire pattern in the
-- field without ever rewriting it. Level is the 4th param here too.
local function logParamSetup(self, WorldContextObject, CharacterID, UniqueNPCID, Level)
    pcall(function()
        local id = CharacterID:get():ToString()
        local level = Level:get()
        Log(string.format("[wildfilter] _ParamSetup fired: %s lv %g",
            tostring(id), level or 0))
    end)
end

function WildFilter.init()
    local cfg = Config.wildLevelLimit
    if not (cfg and cfg.enabled) then return end

    mode = (cfg.mode == "levelFloor") and "levelFloor" or "devolve"
    exemptAlphas = cfg.exemptAlphas ~= false
    genderFaithful = cfg.genderFaithful ~= false
    local includeAdaptations = cfg.includeAdaptations ~= false

    buildMap(includeAdaptations)
    if cycleSeen then
        -- unconditional: the consequence (species silently un-gated) is a
        -- config-shape problem the user should see without devMode
        Log("wild level limit: cycle in the evolution/adaptation map - "
            .. "affected species left un-gated (never rewritten)")
    end
    if genderFaithful and genderConflict then
        -- same reasoning: an unsatisfiable pair is a config-shape problem
        Log("wild level limit: a pair demands both isMale and isFemale - "
            .. "that pair contributes no gender constraint")
    end
    if genderFaithful and genderDiverged then
        Log("wild level limit: gender pass did not converge - "
            .. "gender-faithful spawns disabled")
    end

    enabled = true -- armed before registration; no hook can fire until hooked

    -- hook the pre-actor character-DB build family. natives take a (pre, post)
    -- pair: pre rewrites the species/level, post corrects the rolled gender of
    -- whatever species the pre left behind. Still ONE registration per path.
    local NOOP = function() end
    -- the load-bearing rewrite hooks only; the devMode _ParamSetup
    -- diagnostic is registered best-effort below and never participates in the
    -- retry budget or the fail-closed latch. The _NPCOtomo entry (v1.7.2)
    -- extends the same rules to NPC-companion pals - settlement guards'
    -- and merchants' pals lottery like wilds but build through their own
    -- initializer, which is how a male Katress walked past a female-only map.
    -- Own switch (wildLevelLimit.npcOtomo) so it can be disabled alone.
    local hooks = {
        { "/Script/Pal.PalUtility:GetInitializedCharacterSaveParemter",
          preRewrite, makeGenderPost(2) },
        { "/Script/Pal.PalUtility:GetInitializedCharacterSaveParemter_PassiveSkillList",
          preRewrite, makeGenderPost(3) },
    }
    if cfg.npcOtomo ~= false then
        -- optional: SDK-header presence is not live proof (census-first law -
        -- the statuspage triggers were SDK-declared and dead). A failed
        -- registration here must never join the fail-closed latch and kill
        -- the two PROVEN hooks; it only costs the NPC extension.
        hooks[#hooks + 1] =
            { "/Script/Pal.PalUtility:GetInitializedCharacterSaveParemter_NPCOtomo",
              preRewriteNpc, makeGenderPost(0), optional = true }
    end

    -- register each target, pcall-guarded. Mirrors eggfilter.lua's retry
    -- discipline: the done-flag lives OUTSIDE the ExecuteInGameThread-queued
    -- closure because that call only QUEUES the work - a flag set inside is
    -- written after this tick already returned, so the NEXT tick observes it.
    local registered = {}
    local npcHookWarned = false
    local function tryHooks()
        local allOk = true
        for _, h in ipairs(hooks) do
            local path = h[1]
            if not registered[path] then
                local ok = pcall(RegisterHook, path, h[2], h[3])
                registered[path] = ok
                if h.optional then
                    -- best-effort: never feeds allOk (the fail-closed latch is
                    -- for load-bearing hooks only); warn once so the armed
                    -- banner's coverage claim is corrected in the same log
                    if not ok and not npcHookWarned then
                        npcHookWarned = true
                        Log("wild level limit: npc otomo hook registration failed "
                            .. "(NPC-companion coverage unavailable; wild coverage unaffected)")
                    end
                else
                    allOk = allOk and ok
                end
            end
        end
        return allOk
    end
    if not tryHooks() then
        local hooksDone = false
        local attempts = 0
        LoopAsync(5000, function()
            if hooksDone then return true end
            attempts = attempts + 1
            if attempts > HOOK_RETRY_BUDGET then
                enabled = false -- fail closed: give up and disarm the hook body
                Log("wild level limit: hook registration failed after retries - disabled")
                return true
            end
            ExecuteInGameThread(function() hooksDone = tryHooks() end)
            return false
        end)
    end

    -- devMode-only _ParamSetup observation hook: log-only, best-effort (a
    -- failure here must never disarm the healthy rewrite hooks)
    if Config.devMode then
        local okPS = pcall(RegisterHook,
            "/Script/Pal.PalUtility:GetInitializedCharacterSaveParemter_ParamSetup",
            NOOP, logParamSetup)
        if not okPS then
            Log("[wildfilter] _ParamSetup diagnostic hook unavailable (log-only; feature unaffected)")
        end
    end

    -- devMode fire-rate telemetry: pure-Lua logging, no ExecuteInGameThread,
    -- loop not started at all when devMode is off.
    if Config.devMode then
        LoopAsync(60000, function()
            if not enabled then return true end -- ended by the fail-closed latch
            if fires > 0 then
                Log(string.format("[wildfilter] 60s: %g fires, %g rewrites, "
                    .. "%g gender fixes (%g verified)",
                    fires, rewrites, genderFixes, genderVerified))
                fires, rewrites, genderFixes, genderVerified = 0, 0, 0, 0
            end
            return false
        end)
    end

    local flags = { mode, includeAdaptations and "adaptations included" or "adaptations excluded" }
    if genderFaithful then
        -- the count is what tells the user whether their map actually gates any
        -- species by gender (0 = the fix is armed but has nothing to do)
        table.insert(flags, string.format("gender-faithful: %g species", genderCount))
    end
    if cfg.npcOtomo ~= false then
        table.insert(flags, "npc otomo covered")
    end
    Log(string.format("wild level limit armed (%s)", table.concat(flags, ", ")))
end

return WildFilter
