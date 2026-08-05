-- Palvolve configuration: evolution map and settings.
-- Categories: "evolution" (small -> big form), "funchain" (across family lines),
-- "adaptation" (element variant). stone: "evolution" | "adaptation" - item costs
-- only apply while requireStone is true.
--
-- Optional per-pair field `free = true`: THAT pair costs nothing at all (no
-- stone, no materials) regardless of the global switches, so a tree can mix
-- level-only evolutions with costed ones. Free pairs are exactly the ones
-- auto-evolve fires on its own; costed pairs always keep the prompt flows.
-- Example: { from = "Penguin", to = "CaptainPenguin", minLevel = 20, free = true },
--
-- Optional per-pair field `conditions = { "night", "knowsMove:Dragon", ... }`:
-- every listed condition must hold at evolve time (AND). An either/or split is
-- two pairs with the same from/to and different conditions - the gates try all
-- same-target candidates - or the in-pair form `anyOf = { ... }`: same
-- vocabulary, at least one listed id must hold (see conditions.lua).
-- Vocabulary and colon syntax ("knowsMove:<Element>",
-- "inParty:<CharacterID>") live in conditions.lua; unknown ids are dropped at
-- load with a log line.
--
-- Map basis: DT_PalMonsterParameter row names (buildid 24088745). findPair
-- returns the FIRST enabled match: evolutions are therefore listed BEFORE
-- adaptations of the same base (e.g. Penguin). BOSS_/GYM_/RAID_/_Oilrig/
-- _Tower ids must NEVER be targets (boss/spawn logic is attached to them).
local Conditions = require("conditions")

-- ============================== FORK FEATURES ==============================
-- Everything this fork adds over DooDesch's Palvolve, and the switch that
-- turns each one off. Every switch below is also settable from
-- config_user.lua, so a stock-Palvolve-plus-nothing session is one user file
-- away - no reinstall needed.
--   auto-evolve (free evolutions fire on their own) ..... autoEvolve.enabled
--   base workers auto-evolve ............................ autoEvolve.basePals
--   transformation protection (no mid-evolve deaths) .... evolveProtection.enabled
--   Primed Pals (wild pals evolve at low HP) ............ primedPals.enabled
--   wild level limit / devolve-at-spawn ................. wildLevelLimit.enabled
--   gender-faithful wild spawns ......................... wildLevelLimit.genderFaithful
--   NPC-companion pals obey the same rules .............. wildLevelLimit.npcOtomo
--   cross-species adaptations gate eggs ................. eggFilter.gateCrossAdaptations
--   in-session work-suitability refresh at evolve ....... worksuitRefresh
--   saddle-tech census dump (RETIRED on build 933,
--     switch inert - see the declaration below) ......... techCensus
--   workbench unlock level (applies next launch) ........ techLevelCap
--   withdraw-to-cancel (recall aborts + refunds) ........ withdrawCancels
--   status-page evolution list .......................... statusEvolutions.enabled
--   Palpedia Evolutions tab ............................. palpediaEvolutions.enabled
--   evolution prompts (toast + chat line) ............... evolveNotify.enabled
--   "What's this?" pre-evolution beat + pause ........... evolveNotify.flavorLine
--   DarnToasts delivery (that mod's toasts + a progress
--     panel instead of the vanilla notice feed, only
--     while DarnToasts is installed) .................... evolveNotify.darnToasts
--   primed-stone naming & labels ........................ stoneNames.primedNaming
--   material costs on top of the stone .................. costs.enabled
--   in-game options menu (Mod Options Framework, if it
--     is installed - 36 of the switches on this list,
--     precedence config.lua < config_user.lua < menu;
--     rows marked "Applies at next launch." arm a hook
--     at startup and reach the game through the cache
--     file, see the third-layer pass at the bottom) ..... modoptions.lua
--   in-game settings page (DarnMenu, if THAT mod is
--     installed - the same 36 switches on a second
--     menu, rendered from the same row table; both
--     menus merge their CHANGED KEYS into the ONE
--     options cache above, so the last Apply OF A KEY
--     wins and neither menu can revert the other's
--     untouched rows; nothing here reads a DarnMenu
--     file) ............................................. darnmenu.lua
-- DATA-HALF feature, no runtime switch (PalSchema loads it before any Lua
-- runs): saddle-tech tree sync - gear techs move to your map's begin
-- levels via Mods/PalSchema/mods/Palvolve-Fork/raw/palvolve_saddletech.jsonc.
-- To remove it, delete that file from the installed data half (and re-run
-- tools/gen-saddletech.js after map edits to refresh it). The same
-- data-half caveat covers the stone item names further below.
-- The egg filter exists upstream too; the fork keeps it ON by default
-- (eggFilter.enabled) and extends its semantics (gateCrossAdaptations
-- above is fork-only). Everything NOT listed - rollback, the radial info,
-- the bench and its recipes, conditions, the layered grand finale
-- (finale.style / digimon.elementColors), the catch-tech unlock
-- (unlockCatchTech) - is upstream behavior with upstream's own switches.
-- ===========================================================================

local Config = {
    -- Dev mode: enables the diagnostic key bindings (probes.lua) and the
    -- [diag] sequence telemetry in the log.
    devMode = false,

    -- Reveal telemetry, on top of devMode. Its own switch because it keeps a
    -- polling closure alive for the whole reveal, and two overlapping runs of
    -- it have killed the game with "Ref was not function".
    diagReveal = false,

    -- Mod version, reported to connected clients by the host handshake. Keep in
    -- sync with Info.json (the release flow checks this).
    modVersion = "1.10.0",

    -- In-session work-suitability refresh: after a species swap the pal's
    -- work-style cache (CraftSpeeds, Transient) still describes the OLD form
    -- until the param is rebuilt at world load, so the party panel shows the
    -- wrong styles for the rest of the session. With this on, the ranks are
    -- rebuilt in place from the new species' database row at the swap. The
    -- SAVE is never affected either way (the cache is never serialized);
    -- false = the stock behavior, new work styles show after a save & reload.
    worksuitRefresh = true,

    -- Saddle-tech census: RETIRED on build 100933 - the runtime read route
    -- was convicted of two CTDs by crumb forensics (see techcensus.lua for
    -- the record). The module no-ops regardless of this flag now; it stays
    -- for config compatibility and for a future build's revalidation run.
    techCensus = false,

    -- Workbench unlock level: the technology stage the Pal Alchemy Workbench is
    -- unlocked at (1-100). This is PalSchema DATA, read once when PalSchema
    -- loads, so it can never change for the running session - techlevel.lua
    -- rewrites the data half's building file at every launch and the new stage
    -- applies at the NEXT one. The same pass repairs the value after a
    -- reinstall replaced the data half with its shipped default.
    techLevelCap = 10,

    -- Unlock the catch-gated technologies (saddle, Pal gear) of the target species when a
    -- pal evolves, the same way capturing one would. Needs the native companion in
    -- dlls/main.dll; without it this is skipped and evolution works as before.
    unlockCatchTech = true,

    -- Server check: a connected client asks the host whether Palvolve runs
    -- server-side and which version. Without a host-side answer, evolution and
    -- the bench recipe patch are disabled for the session and the client is told
    -- why (so a client-only install no longer half-works and confuses players).
    serverCheck = {
        enabled = true,
        -- Grace window for the host's join greet. The greet fires from the
        -- client's server-side character init, which on a busy dedicated server
        -- can lag the client's own world entry by many seconds, so keep this
        -- generous. Hitting the timeout only soft-gates silently (the player is
        -- told at the moment they reach for evolution, not with a banner).
        timeoutSeconds = 25,
    },

    -- Timings for the evolution staging
    -- (spin-up -> shrink -> peak hold -> grow -> finale hold)
    digimon = {
        spinUpMs = 3000,       -- phase A: accelerating spin, effects ramp up
        shrinkMs = 2500,       -- phase B: keeps spinning, scales down to nothing
        growMs = 3500,         -- reveal: grows back while the spin winds down
        peakDegPerSec = 1080,  -- top angular speed at the end of the shrink
        finaleHoldMs = 3500,   -- finale: keeps turning majestically while the
                               -- effects fade, steering into the face-player
                               -- yaw at the very end
        elementColors = true   -- tint bursts/glow with the pals' elements
                               -- (dissolve = old form, reveal = target form);
                               -- false also disables the layered finale's
                               -- element layer (its base layer still runs)
    },

    -- Transformation protection: an evolving pal cannot die while the
    -- sequence runs. The staging freezes the pal but leaves it damageable,
    -- and no stage checks for death - mid-combat a kill during the dissolve
    -- reads as a despawn, and the new form can be shot down mid-reveal. While
    -- the window is open the current actor (old body, then the freshly
    -- spawned target body) is flagged undamageable and the individual's HP is
    -- re-topped on a short pump; the window closes with one final full heal,
    -- so an evolution always ends at full HP even under fire.
    evolveProtection = {
        enabled = true,
        healPumpMs = 250,       -- HP re-top + flag re-assert interval
        maxWindowSeconds = 90,  -- hard deadline backstop; every normal
                                -- sequence end releases much earlier
    },

    -- Primed Pals: a wild pal whose level already satisfies one of its
    -- species' evolutions has a chance to be PRIMED - when its HP drops
    -- below the threshold in a fight, it evolves right there. The roll is
    -- deterministic per individual (hashed from its instance id), so a
    -- Primed Pal stays primed across save/load with no stored state.
    -- During the short telegraph before the swap the pal is death-protected
    -- but NOT healed and stays fully catchable: sphere it then (at its juicy
    -- low-HP catch odds) and you catch the UN-evolved form - the evolution
    -- aborts; let it finish and you face a full-HP evolved pal worth more
    -- (it gets the same benefits as player evolutions: IV bonus, full heal,
    -- protection through the reveal). Pairs with environment conditions
    -- (desert, cave, night, weather...) participate: region checks use the
    -- nearby fighting player's position as the pal's proxy (the pal is
    -- within range of them by definition), and player-pawn checks like
    -- playerLevel read that same nearby player ("a player at least this
    -- strong is around"); party/trust/riding conditions never match wild
    -- pals. Authority-side only (host/server); costs never apply to wild
    -- pals.
    primedPals = {
        enabled = true,
        chance = 10,             -- percent chance a wild pal is primed
        hpThreshold = 0.35,      -- evolves when HP fraction drops below this
        scanIntervalSeconds = 2, -- scanner cadence (runs ONLY during combat)
        range = 8000,            -- only pals within this range of a player
        levelGrace = 0,          -- also allow pairs up to N levels above the
                                 -- pal's level ("pushed over the edge")
        maxPerScan = 12,         -- nearby wild candidates fully examined per
                                 -- tick; the sweep stops once this budget is
                                 -- spent, and the rotating start guarantees
                                 -- every pal gets its turn within a few ticks
        telegraphMs = 1800,      -- catch-window staging before the swap
        -- per-environment chance overrides: while the pal itself satisfies
        -- the condition, the HIGHEST matching entry replaces `chance`,
        -- e.g. { inDesert = 25, inCave = 25, night = 15 }
        environmentChance = {},
        -- GLOBAL situational gate, same vocabulary as the per-pair conditions
        -- in `map` ("!" negation included): ALL of `conditions`, plus at least
        -- one member of `anyOf` when that list is non-empty, must hold before
        -- a wild pal can become primed-eligible at all. It sits ON TOP of
        -- hpThreshold, the level gates and the chance roll, and the pair's own
        -- conditions still apply afterwards - this only decides whether the
        -- pal is a candidate. Evaluated against the WILD pal itself (its
        -- moves, gender, status effects, HP); region questions are answered
        -- through the nearby player's position (that player stands in for the
        -- pal, which is within range of them by definition) and day/night and
        -- weather are read from the world. A failing gate is not remembered:
        -- the same pal is reconsidered on the next sweep, so a gate that
        -- describes the world (night, a storm) simply opens when it does.
        -- Player-BODY ids do not describe the wild pal and must not be used
        -- here: isRiding fails closed on every wild pal, isGliding answers for
        -- the nearby player instead of the pal, and inWater answers only from
        -- the pal's own swim state (the player fallback is refused). Empty
        -- lists - the default - change nothing.
        -- e.g. conditions = { "night", "!raining" }, anyOf = { "inDesert",
        -- "inVolcano" }
        conditions = {},
        anyOf = {},
    },

    -- Layered grand finale at the reveal (finale_recipes.lua + finale.lua)
    finale = {
        style = "layered",     -- "layered" | "legacy" (legacy = the old
                               -- 5-point burst rosette)
        maxLiveSystems = 14,   -- cap on simultaneously tracked live systems
        debugLog = false,      -- per-event spawn + anchor logging
    },

    -- Two-stage confirm: first press checks and announces, second press confirms.
    confirmKey = "F2",
    confirmWindowSeconds = 10,
    debounceSeconds = 0.5,

    -- Auto-evolve: the summoned pal evolves on its own - no radial prompt, no
    -- F2 confirm - the moment every gate passes (level, conditions, alpha
    -- form) AND the evolution is completely free: no stone and no materials,
    -- i.e. the resolved cost list is empty. Costed pairs never auto-fire, so
    -- with the default requireStone=true this stays inert until evolutions
    -- are made free. When several free targets are eligible at once the first
    -- in map order wins (evolutions sort before adaptations) - use the radial
    -- menu for a manual pick before the poller fires. Works mid-combat; the
    -- transformation itself is covered by evolveProtection below.
    autoEvolve = {
        enabled = true,
        intervalSeconds = 5,   -- how often the summoned pal is re-checked
        cooldownSeconds = 30,  -- per-individual spacing between attempts; kept
                               -- above the worst-case ~26s dedicated-server
                               -- presentation so chained free evolutions can
                               -- never overlap the previous reveal (failed
                               -- attempts additionally back off exponentially)
        -- Base pals evolve on their own too: a pal ASSIGNED TO A CAMP (not a
        -- party member, not the summoned pal) transforms on the spot the
        -- moment it reaches the level of a FREE pair that has NO conditions.
        -- Conditioned pairs are deliberately excluded - a condition deserves
        -- its moment in front of the player - and costed pairs never
        -- auto-fire, exactly like the summoned-pal poller above. This is an
        -- AUTHORITY feature (single player, listen host, dedicated server):
        -- it runs where the base itself is simulated, and connected clients
        -- just see the result. The transformation rebuilds the pal's body,
        -- which drops its current work assignment - the camp AI re-picks a
        -- task moments later, the same way it does after a world reload.
        basePals = true,
        baseIntervalSeconds = 45, -- camp sweep cadence (clamped to >= 15s);
                               -- deliberately slow - a base evolution has no
                               -- prompt to race and no player waiting on it
    },

    -- Evolution prompts: when one of YOUR pals finishes evolving, you are told
    -- on screen - "Cattiva evolved into Naughty Cat! (Lv 19)". The line goes
    -- into the game's own notice stream (the corner feed that reports catches
    -- and level-ups), so it looks native and never interrupts play. Covers
    -- every owned context: your manual F2/radial evolutions, auto-evolve, and
    -- base-camp workers - which is the whole point, since a camp evolution
    -- happens off-screen. On a server the prompt reaches the pal's OWNER
    -- wherever they are: the host relays the sentence over the mod's own
    -- channel and the owner's client renders its own toast, backed by a private
    -- chat line. Wild and primed evolutions stay silent - those pals are not
    -- yours.
    --
    -- chatFallback (on) sends that private chat line ALONGSIDE the notice, not
    -- only when the notice fails: whether the game actually drew the notice is
    -- not observable from a mod (the widget is spawned Blueprint-side), so the
    -- chat line is what guarantees you are told at all. Turn it off for the
    -- notice alone and no duplicated sentence - on every path, local and
    -- server alike. enabled = false silences both surfaces, and the evolution
    -- is still recorded in the UE4SS log.
    --
    -- On a SERVER the two settings sit on different machines: your own
    -- enabled = false stops the notice being drawn on your screen (the relayed
    -- prompt is checked against YOUR config, not the host's), while the private
    -- chat line that backs it up is the host's call via its chatFallback - the
    -- host cannot read your config, and a mod cannot unsend a system chat line.
    -- The sentence is built on the host, so it arrives in the HOST's game
    -- language (see i18n.lua).
    evolveNotify = {
        enabled = true,
        chatFallback = true,
        -- The anime beat: the moment an evolution is committed, the notice
        -- feed reads "What's this? <name> is evolving?" (adaptation pairs:
        -- "... is adapting to its environment!") and the actual
        -- transformation starts flavorLeadMs later (the pal keeps acting
        -- normally through the pause and freezes when the sequence proper
        -- begins). 0 keeps the flavor line but starts the sequence
        -- immediately; the pause is clamped to 5000ms. Applies to the F2
        -- confirm, the radial pick, a connected client's request (the host
        -- paces the whole sequence, so both sides share the beat) and
        -- auto-evolve. Wild and primed evolutions stay silent as always;
        -- base-camp evolutions skip the beat - nobody is watching a camp
        -- three regions away.
        flavorLine = true,
        flavorLeadMs = 1500,
        -- DarnToasts delivery: when the DarnToasts mod is installed alongside
        -- this one, the notices above are drawn on ITS channel (styled toasts
        -- with a per-mod lane, plus a sticky progress panel through the
        -- transformation) instead of the game's own notice feed - one surface,
        -- never both. Without that mod this switch does nothing at all, which
        -- is why it ships on: the integration is inert without the framework
        -- and costs nothing to leave enabled. Style, position and MUTING live
        -- on DarnToasts' own Toasts page, not here; muting Palvolve there
        -- silences these notices completely (the chat line above and the
        -- UE4SS log entry are unaffected - a mod cannot unsend a chat line
        -- and the log is the record). Off = the vanilla notice feed as before,
        -- even with DarnToasts installed.
        darnToasts = true,
    },

    -- Evolution info on the pal status page: the detail overlay (a pal's
    -- stats screen) lists what the pal can evolve into and what each target
    -- needs - level, conditions, and stone/materials at its current level
    -- (free pairs simply show their level). Placement is in design-
    -- resolution pixels from the page's top-left; nudge x/y if a game
    -- update or another mod moves the layout. Purely cosmetic and fails
    -- closed: any structural surprise collapses the block for the session.
    -- Covers BOTH pal-detail screens: the standalone status overlay and the
    -- main menu's Party tab. Default position is the free centre-bottom
    -- area under the pal model (1920x1080 design space).
    -- SUPERSEDED by palpediaEvolutions below (off by default; flip back on
    -- if you also want the block on the per-pal detail screens).
    statusEvolutions = {
        enabled = false,
        x = 820,         -- left edge of the block
        y = 840,         -- top edge of the block
        lineHeight = 26, -- vertical spacing per line
        maxLines = 8,    -- header + up to 7 targets
    },

    -- The Evolutions tab on the Palpedia: a CLICKABLE tab-style label sits
    -- beside the game's Stats/Habitat tabs (at tabX/tabY); clicking it
    -- opens a panel listing what the selected species evolves into and
    -- what each target needs (level, conditions, costs at the pair's
    -- minimum level - the Paldex shows species, not individuals), each
    -- target tagged as an Evolution or an (element) Adaptation. Clicking
    -- Stats/Habitat closes it; the toggle key is the keyboard shortcut.
    -- Positions are viewport pixels (1920x1080). Cosmetic, fails closed.
    palpediaEvolutions = {
        enabled = true,
        toggleKey = "V", -- keyboard shortcut for the tab
        tabX = 1560,     -- tab-label position (screen-space)
        tabY = 118,
        x = 700,         -- panel top-left (the free area under the model)
        y = 280,
        lineHeight = 30, -- vertical spacing per line (scaled by textScale)
        maxLines = 19,   -- header + up to 6 targets (spacer + name + reqs)
        textScale = 0.8, -- render scale of the panel labels (1 = game default;
                         -- the tab label is never scaled)
        wrapChars = 56,  -- soft-wrap requirement lines longer than this at
                         -- their " + " separators (0 = never wrap)
    },

    -- Withdrawing (recalling) your pal during the dissolve cancels the
    -- evolution: any stone/materials already taken are refunded, and
    -- auto-evolve leaves that pal alone until its next level-up (manual
    -- F2/radial evolution stays available immediately). Single player and
    -- co-op host only - on a dedicated server the species swap commits
    -- before a recall could ever land.
    withdrawCancels = true,

    -- Multiplayer request channel (host-side limits per requesting player)
    net = {
        rateLimitSeconds = 2, -- minimum spacing between evolve requests
        reqIdCacheSize = 32,  -- replay protection window (request ids)
    },

    -- IV bonus per evolution stage (applied to Talent_HP/Melee/Shot/Defense, capped)
    ivBonusPerStage = 5,
    ivCap = 100,

    -- Item costs (stones exist via PalSchema; false = free mode)
    requireStone = true,
    stoneCount = 1,
    stoneItemIds = {
        evolution = "Palvolve_EvolutionStone",
        -- per-element PRIMED evolution stones (crafted from an Unprimed
        -- Evolution Stone + the matching element essence; the unprimed stone
        -- itself is crystal + MeteorDrop + PalFluid)
        adaptation = {
            Normal      = "Palvolve_AdaptationStone_Normal",
            Fire        = "Palvolve_AdaptationStone_Fire",
            Water       = "Palvolve_AdaptationStone_Water",
            Leaf        = "Palvolve_AdaptationStone_Leaf",
            Electricity = "Palvolve_AdaptationStone_Electricity",
            Ice         = "Palvolve_AdaptationStone_Ice",
            Earth       = "Palvolve_AdaptationStone_Earth",
            Dark        = "Palvolve_AdaptationStone_Dark",
            Dragon      = "Palvolve_AdaptationStone_Dragon",
        },
        -- legacy generic stone: kept for stones already in inventories,
        -- accepted whenever the target element cannot be resolved
        adaptationFallback = "Palvolve_AdaptionStone",
    },
    stoneNames = {
        -- primed-stone economy (2026-07-25), the fork's presentation preset:
        -- the plain stone is the crafting base; elemental stones are "primed"
        -- evolution stones (costs.lua appends " (Element)" to the adaptation
        -- name, giving e.g. "Primed Evolution Stone (Fire)"), and the
        -- Palpedia/status lists tag entries by what a pair IS (its category).
        -- primedNaming = false reverts BOTH to the classic upstream
        -- presentation: the names below are replaced by the classic pair and
        -- the list tags follow the STONE a pair charges (pre-economy
        -- behavior). Explicitly set evolution/adaptation strings in
        -- config_user always win over either preset. NOTE: inventory and
        -- bench item names come from the PalSchema data half and keep the
        -- fork's names either way - this switch covers the mod's own prompts,
        -- cost lines and list labels.
        primedNaming = true,
        evolution = "Unprimed Evolution Stone",
        adaptation = "Primed Evolution Stone",
        classicEvolution = "Evolution Stone",
        classicAdaptation = "Adaptation Stone",
    },

    -- Material costs on top of the stone. DERIVED materials come from drop
    -- tables (evolutions price the BASE pal's drops, adaptations the TARGET
    -- form's), and `enabled` gates exactly that derivation. An explicit
    -- per-pair `materials = { { id = "...", count = n }, ... }` is part of
    -- the pair's own design and charges whether the switch is on or off.
    -- Off by default: the stone + essence chain already carries the price.
    costs = {
        enabled = false,
        slots = 2,        -- max distinct material types taken from a drop row
        minRate = 50.0,   -- ignore drop slots rarer than this (percent)
        countScale = 4.0, -- count = ceil(avg(min,max) * countScale), clamped
        maxCount = 30,
        fallbackMaterials = {
            -- species without a drop table row
        },
    },

    -- Eggs only ever hatch base forms (evolved forms are normalized back to
    -- their base species while hatching); funchain results stay allowed.
    eggFilter = {
        enabled = true,
        -- An "adaptation" edge that CHANGES SPECIES (Dinossom -> Braloha)
        -- gates eggs like an evolution: the reached species is earn-only and
        -- its eggs hatch the base family instead. Same-species element
        -- variants (Kelpie -> Kelpie_Fire) are exempt and keep hatching
        -- unchanged - the map's own naming (to = from .. "_Suffix") is the
        -- discriminator. false restores the pre-1.7.3 evolution-chains-only
        -- rule, under which a Braloha egg hatches a Braloha.
        gateCrossAdaptations = true,
    },

    -- Wild level limit: when a WILD pal rolls a species its level could not
    -- legitimately have reached (its rolled level is below the minimum the map
    -- requires to reach that species), the spawn is rewritten BEFORE any actor
    -- exists. "devolve" (default) spawns it as the chain stage its level does
    -- allow; "levelFloor" instead raises the level to that species' floor and
    -- leaves the species alone. Evolution parents always gate; adaptation
    -- parents gate while includeAdaptations is true (funchain links never do).
    -- Alphas (BOSS_) are left alone by default. Authority-side (host/server);
    -- wild pals only (owned pals are never touched).
    --
    -- genderFaithful applies the same idea to gender: gender persists through
    -- evolution, so a species every one of whose ancestry paths demands one
    -- gender (e.g. Vanwyrm, reachable only via an isFemale pair) can only
    -- legitimately exist as that gender - a wild male one is as illegitimate as
    -- an under-levelled one. Those spawns have their rolled gender corrected
    -- before the actor exists. Species with any un-gendered or disagreeing
    -- ancestry path (both a male and a female route) keep their random roll.
    wildLevelLimit = {
        enabled = true,
        mode = "devolve",          -- "devolve" | "levelFloor"
        includeAdaptations = true,
        exemptAlphas = true,
        genderFaithful = true,     -- gender-correct fully gender-gated species
        -- NPC-companion pals (settlement guards', merchants' and faction
        -- NPCs' pals) obey the same level floors and gender rules: they
        -- lottery like wilds but build through their own initializer, which
        -- previously bypassed the filter entirely. A unique (story) NPC's
        -- authored companion is always left untouched. Already-spawned NPC
        -- pals fix themselves on their next area reload - spawn-time rules
        -- never rewrite an existing individual.
        npcOtomo = true,
    },

    -- Map schema version; 5 = negatable conditions ("!" prefix), 4 = per-pair
    -- conditions
    schemaVersion = 5,
    -- Palworld revision: the trailing digits of the title-screen version
    -- (v1.0.1.100619 -> 619), the identifier the official mod loader uses
    gameBuild = 619,

    map = {
    -- ==================== True evolutions (small -> big form) ====================
    {
        from = "Penguin",
        to = "CaptainPenguin",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        enabled = true
    }, -- Pengullet -> Penking
    {
        from = "MopBaby",
        to = "MopKing",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        conditions = { "inParty:MopKing" },
        enabled = true
    }, -- Swee -> Sweepa (inParty:MopKing)
    {
        from = "Alpaca",
        to = "KingAlpaca",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Melpaca -> Kingpaca
    {
        from = "SoldierBee",
        to = "QueenBee",
        category = "evolution",
        minLevel = 35,
        stone = "evolution",
        enabled = true
    }, -- Beegarde -> Elizabee
    {
        from = "MoonChild",
        to = "MoonQueen",
        category = "evolution",
        minLevel = 50,
        stone = "evolution",
        enabled = true
    }, -- Wistella -> Selyne
    {
        from = "SmallYeti",
        to = "Yeti",
        category = "evolution",
        minLevel = 22,
        stone = "evolution",
        enabled = true
    }, -- Snugloo -> Wumpo
    {
        from = "Penguin_Electric",
        to = "CaptainPenguin_Black",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        enabled = true
    }, -- Pengullet Lux -> Penking Lux
    {
        from = "Bastet",
        to = "Sekhmet",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        conditions = { "day", "inDesert" },
        enabled = true
    }, -- Mau -> Sekhmet (day + inDesert)
    {
        from = "Kelpie",
        to = "Umihebi",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "electrified" },
        enabled = true
    }, -- Kelpsea -> Jormuntide (electrified)
    {
        from = "Kelpie",
        to = "Umihebi",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "knowsMove:Dragon" },
        enabled = true
    }, -- Kelpsea -> Jormuntide (knowsMove:Dragon)
    {
        from = "Kelpie_Fire",
        to = "Umihebi_Fire",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "electrified" },
        enabled = true
    }, -- Kelpsea Ignis -> Jormuntide Ignis (electrified)
    {
        from = "Kelpie_Fire",
        to = "Umihebi_Fire",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "knowsMove:Dragon" },
        enabled = true
    }, -- Kelpsea Ignis -> Jormuntide Ignis (knowsMove:Dragon)
    {
        from = "Carbunclo",
        to = "BerryGoat",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        enabled = true
    }, -- Lifmunk -> Caprity
    {
        from = "BerryGoat",
        to = "SkyDragon_Grass",
        category = "evolution",
        minLevel = 42,
        stone = "evolution",
        enabled = true
    }, -- Caprity -> Quivern Botan
    {
        from = "PinkRabbit_Grass",
        to = "FlowerDoll",
        category = "evolution",
        minLevel = 30,
        stone = "evolution",
        enabled = true
    }, -- Ribbuny Botan -> Petallia
    {
        from = "PinkRabbit",
        to = "FlowerDoll_Fire",
        category = "evolution",
        minLevel = 30,
        stone = "evolution",
        enabled = true
    }, -- Ribbuny -> Petallia Ignis
    {
        from = "FlowerRabbit",
        to = "VenusFlytrap",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Flopie -> Carnibora
    {
        from = "LeafPrincess",
        to = "LilyQueen",
        category = "evolution",
        minLevel = 40,
        stone = "evolution",
        enabled = true
    }, -- Lullu -> Lyleen
    {
        from = "LeafMomonga",
        to = "GrassPanda",
        category = "evolution",
        minLevel = 32,
        stone = "evolution",
        enabled = true
    }, -- Herbil -> Mossanda
    {
        from = "CloverFairy",
        to = "GrassMinotaur",
        category = "evolution",
        minLevel = 30,
        stone = "evolution",
        enabled = true
    }, -- Clovee -> Elgrove
    {
        from = "LittleBriarRose",
        to = "SakuraSaurus",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Bristla -> Broncherry
    {
        from = "SakuraSaurus",
        to = "Plesiosaur",
        category = "evolution",
        minLevel = 48,
        stone = "evolution",
        enabled = true
    }, -- Broncherry -> Braloha
    {
        from = "NegativeKoala",
        to = "BadCatgirl",
        category = "evolution",
        minLevel = 36,
        stone = "evolution",
        enabled = true
    }, -- Depresso -> Nyafia
    {
        from = "OctopusGirl",
        to = "SnakeGirl",
        category = "evolution",
        minLevel = 40,
        stone = "evolution",
        enabled = true
    }, -- Gloopie -> Venusa
    {
        from = "WizardOwl",
        to = "BlackGriffon",
        category = "evolution",
        minLevel = 48,
        stone = "evolution",
        enabled = true
    }, -- Hoocrates -> Shadowbeak
    {
        from = "Bastet",
        to = "GhostBlackCat",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        conditions = { "night" },
        enabled = true
    }, -- Mau -> Wispaw (night)
    {
        from = "Bastet",
        to = "GhostBlackCat",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        conditions = { "inCave" },
        enabled = true
    }, -- Mau -> Wispaw (inCave)
    {
        from = "NightFox",
        to = "AmaterasuWolf_Dark",
        category = "evolution",
        minLevel = 36,
        stone = "evolution",
        enabled = true
    }, -- Nox -> Kitsun Noct
    {
        from = "CatBat",
        to = "CatVampire",
        category = "evolution",
        minLevel = 35,
        stone = "evolution",
        enabled = true
    }, -- Tombat -> Felbat
    {
        from = "ElecCat",
        to = "ElecPanda",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        enabled = true
    }, -- Sparkit -> Grizzbolt
    {
        from = "ElecLizard",
        to = "KingSunfish_Thunder",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        enabled = true
    }, -- Slowatt -> Solmora Lux
    {
        from = "ElecPomeranian",
        to = "ThunderDog",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        enabled = true
    }, -- Puffolt -> Rayhound
    {
        from = "ThunderDog",
        to = "ThunderDragonMan",
        category = "evolution",
        minLevel = 42,
        stone = "evolution",
        enabled = true
    }, -- Rayhound -> Orserk
    {
        from = "Penguin_Electric",
        to = "ThunderFluffyBird",
        category = "evolution",
        minLevel = 31,
        stone = "evolution",
        conditions = { "electrified" },
        enabled = true
    }, -- Pengullet Lux -> Dynamoff (electrified)
    {
        from = "Penguin_Electric",
        to = "ThunderFluffyBird",
        category = "evolution",
        minLevel = 31,
        stone = "evolution",
        conditions = { "inSanctuary" },
        enabled = true
    }, -- Pengullet Lux -> Dynamoff (inSanctuary)
    {
        from = "Kitsunebi",
        to = "FlameBuffalo",
        category = "evolution",
        minLevel = 32,
        stone = "evolution",
        enabled = true
    }, -- Foxparks -> Arsox
    {
        from = "SharkKid_Fire",
        to = "StuffedShark_Fire",
        category = "evolution",
        minLevel = 36,
        stone = "evolution",
        enabled = true
    }, -- Gobfin Ignis -> Finsider Ignis
    {
        from = "Kelpie_Fire",
        to = "Suzaku",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "inWater" },
        enabled = true
    }, -- Kelpsea Ignis -> Suzaku (inWater)
    {
        from = "Kelpie",
        to = "Suzaku_Water",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        conditions = { "inWater" },
        enabled = true
    }, -- Kelpsea -> Suzaku Aqua (inWater)
    {
        from = "LavaGirl",
        to = "FoxMage",
        category = "evolution",
        minLevel = 32,
        stone = "evolution",
        enabled = true
    }, -- Flambelle -> Wixen
    {
        from = "FoxMage",
        to = "KabukiMan",
        category = "evolution",
        minLevel = 42,
        stone = "evolution",
        enabled = true
    }, -- Wixen -> Renjishi
    {
        from = "FireKirin",
        to = "Manticore",
        category = "evolution",
        minLevel = 35,
        stone = "evolution",
        enabled = true
    }, -- Pyrin -> Blazehowl
    {
        from = "FireKirin_Dark",
        to = "Manticore_Dark",
        category = "evolution",
        minLevel = 35,
        stone = "evolution",
        enabled = true
    }, -- Pyrin Noct -> Blazehowl Noct
    {
        from = "IceSeal_Ground",
        to = "SumoDog",
        category = "evolution",
        minLevel = 36,
        stone = "evolution",
        enabled = true
    }, -- Polapup Terra -> Bulldosu
    {
        from = "SamuraiDog",
        to = "BrownRabbit",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Pupperai -> Lapiron
    {
        from = "TentacleTurtle_Ground",
        to = "DrillGame",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        enabled = true
    }, -- Turtacle Terra -> Digtoise
    {
        from = "DrillGame",
        to = "CubeTurtle",
        category = "evolution",
        minLevel = 42,
        stone = "evolution",
        enabled = true
    }, -- Digtoise -> Tetroise 
    {
        from = "Kitsunebi_Ice",
        to = "IceFox",
        category = "evolution",
        minLevel = 32,
        stone = "evolution",
        enabled = true
    }, -- Foxparks Cryst -> Foxcicle
    {
        from = "BirdDragon_Ice",
        to = "ThunderBird_Ice",
        category = "evolution",
        minLevel = 38,
        stone = "evolution",
        enabled = true
    }, -- Vanwyrm Cryst -> Beakon Cryst
    {
        from = "Hedgehog_Ice",
        to = "WhiteTiger",
        category = "evolution",
        minLevel = 36,
        stone = "evolution",
        enabled = true
    }, -- Jolthog Cryst -> Cryolinx
    {
        from = "FluffyBird",
        to = "WhiteMoth",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Muffly -> Sibelyx
    {
        from = "Bastet_Ice",
        to = "BlackPuppy_Ice",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        enabled = true
    }, -- Mau Cryst -> Smokie Cryst
    {
        from = "PinkCat",
        to = "LongCat",
        category = "evolution",
        minLevel = 28,
        stone = "evolution",
        enabled = true
    }, -- Cattiva -> Valentail
    {
        from = "SweetsSheep",
        to = "PinkLizard",
        category = "evolution",
        minLevel = 21,
        stone = "evolution",
        enabled = true
    }, -- Woolipop -> Lovander
    {
        from = "CuteFox",
        to = "SifuDog",
        category = "evolution",
        minLevel = 30,
        stone = "evolution",
        enabled = true
    }, -- Vixy -> Dogen
    {
        from = "NightBlueHorse_Neutral",
        to = "LegendDeer",
        category = "evolution",
        minLevel = 50,
        stone = "evolution",
        enabled = true
    }, -- Starryon Primo -> Hartalis
    {
        from = "NegativeOctopus_Neutral",
        to = "OctopusGirl_Neutral",
        category = "evolution",
        minLevel = 25,
        stone = "evolution",
        enabled = true
    }, -- Killamari Primo -> Gloopie Primo
    -- ==================== Fun chains (deliberate jokes) ====================
    {
        from = "MopKing",
        to = "SmallYeti",
        category = "funchain",
        minLevel = 45,
        stone = "evolution",
        enabled = true
    }, -- Sweepa -> Snugloo
    {
        from = "PinkCat",
        to = "BadCatgirl",
        category = "funchain",
        minLevel = 35,
        stone = "evolution",
        enabled = false
    }, -- Cattiva -> Nyafia
    {
        from = "SmallArmadillo",
        to = "DrillGame",
        category = "funchain",
        minLevel = 16,
        stone = "evolution",
        enabled = true
    }, -- Kikit -> Digtoise
    {
        from = "Ganesha",
        to = "GrassMammoth_Ice",
        category = "funchain",
        minLevel = 40,
        stone = "evolution",
        enabled = true
    }, -- Teafant -> Mammorest Cryst
    -- ==================== Element adaptations (same species) ====================
    {
        from = "AmaterasuWolf",
        to = "AmaterasuWolf_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Kitsun -> Kitsun Noct
    {
        from = "Baphomet",
        to = "Baphomet_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Incineram -> Incineram Noct
    {
        from = "Bastet",
        to = "Bastet_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Mau -> Mau Cryst
    {
        from = "BerryGoat",
        to = "BerryGoat_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Caprity -> Caprity Noct
    {
        from = "BirdDragon",
        to = "BirdDragon_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Vanwyrm -> Vanwyrm Cryst
    {
        from = "BlackPuppy",
        to = "BlackPuppy_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Smokie -> Smokie Cryst
    {
        from = "BlueDragon",
        to = "BlueDragon_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Azurobe -> Azurobe Cryst
    {
        from = "BluePlatypus",
        to = "BluePlatypus_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Fuack -> Fuack Ignis
    {
        from = "CactusDoll",
        to = "CactusDoll_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Needoll -> Needoll Noct
    {
        from = "CaptainPenguin",
        to = "CaptainPenguin_Black",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, -- Penking -> Penking Lux
    {
        from = "CatMage",
        to = "CatMage_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Katress -> Katress Ignis
    {
        from = "CubeTurtle",
        to = "CubeTurtle_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Tetroise  -> Tetroise Primo
    {
        from = "DarkScorpion",
        to = "DarkScorpion_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Menasting -> Menasting Terra
    {
        from = "Deer",
        to = "Deer_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Eikthyrdeer -> Eikthyrdeer Terra
    {
        from = "ElecSnail",
        to = "ElecSnail_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Snock -> Snock Ignis
    {
        from = "ElecSnail",
        to = "ElecSnail_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Snock -> Snock Lux
    {
        from = "FairyDragon",
        to = "FairyDragon_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Elphidran -> Elphidran Aqua
    {
        from = "FengyunDeeper",
        to = "FengyunDeeper_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Fenglope -> Fenglope Lux
    {
        from = "FireKirin",
        to = "FireKirin_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Pyrin -> Pyrin Noct
    {
        from = "FlowerDinosaur",
        to = "FlowerDinosaur_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Dinossom -> Dinossom Lux
    {
        from = "FlowerDoll",
        to = "FlowerDoll_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Petallia -> Petallia Ignis
    {
        from = "FlyingManta",
        to = "FlyingManta_Thunder",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Celaray -> Celaray Lux
    {
        from = "FoxMage",
        to = "FoxMage_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Wixen -> Wixen Noct
    {
        from = "GhostAnglerfish",
        to = "GhostAnglerfish_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Ghangler -> Ghangler Ignis
    {
        from = "GhostDragon",
        to = "GhostDragon_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Eidrolon -> Eidrolon Ignis
    {
        from = "GhostRabbit",
        to = "GhostRabbit_Grass",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Nitemary -> Nitemary Botan
    {
        from = "Gorilla",
        to = "Gorilla_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Gorirat -> Gorirat Terra
    {
        from = "GrassGolem",
        to = "GrassGolem_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Dualith -> Dualith Noct
    {
        from = "GrassMammoth",
        to = "GrassMammoth_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Mammorest -> Mammorest Cryst
    {
        from = "GrassMinotaur",
        to = "GrassMinotaur_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Elgrove -> Elgrove Cryst
    {
        from = "GrassPanda",
        to = "GrassPanda_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Mossanda -> Mossanda Lux
    {
        from = "HadesBird",
        to = "HadesBird_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Helzephyr -> Helzephyr Lux
    {
        from = "Hedgehog",
        to = "Hedgehog_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Jolthog -> Jolthog Cryst
    {
        from = "HerculesBeetle",
        to = "HerculesBeetle_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Warsect -> Warsect Terra
    {
        from = "Horus",
        to = "Horus_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Faleris -> Faleris Aqua
    {
        from = "IceHorse",
        to = "IceHorse_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Frostallion -> Frostallion Noct
    {
        from = "IceNarwhal",
        to = "IceNarwhal_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Whalaska -> Whalaska Ignis
    {
        from = "IceSeal",
        to = "IceSeal_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Polapup -> Polapup Terra
    {
        from = "Kelpie",
        to = "Kelpie_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Kelpsea -> Kelpsea Ignis
    {
        from = "KendoFrog",
        to = "KendoFrog_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Croajiro -> Croajiro Noct
    {
        from = "KingAlpaca",
        to = "KingAlpaca_Ice",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, -- Kingpaca -> Kingpaca Cryst
    {
        from = "KingBahamut",
        to = "KingBahamut_Dragon",
        category = "adaptation",
        minLevel = 40,
        stone = "adaptation",
        enabled = true
    }, -- Blazamut -> Blazamut Ryu
    {
        from = "KingSunfish",
        to = "KingSunfish_Thunder",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Solmora -> Solmora Lux
    {
        from = "Kirin",
        to = "Kirin_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Univolt -> Univolt Cryst
    {
        from = "Kitsunebi",
        to = "Kitsunebi_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Foxparks -> Foxparks Cryst
    {
        from = "LazyCatfish",
        to = "LazyCatfish_Gold",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Dumud -> Dumud Gild
    {
        from = "LazyDragon",
        to = "LazyDragon_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        conditions = { "electrified" },
        enabled = true
    }, -- Relaxaurus -> Relaxaurus Lux (electrified)
    {
        from = "LilyQueen",
        to = "LilyQueen_Dark",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, -- Lyleen -> Lyleen Noct
    {
        from = "LizardMan",
        to = "LizardMan_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Leezpunk -> Leezpunk Ignis
    {
        from = "Manticore",
        to = "Manticore_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Blazehowl -> Blazehowl Noct
    {
        from = "Monkey",
        to = "Monkey_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Tanzee -> Tanzee Ignis
    {
        from = "Monkey",
        to = "Monkey_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Tanzee -> Tanzee Cryst
    {
        from = "MushroomDragon",
        to = "MushroomDragon_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Shroomer -> Shroomer Noct
    {
        from = "NegativeOctopus",
        to = "NegativeOctopus_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Killamari -> Killamari Primo
    {
        from = "NightBlueHorse",
        to = "NightBlueHorse_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Starryon -> Starryon Primo
    {
        from = "NightLady",
        to = "NightLady_Dark",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, -- Bellanoir -> Bellanoir Libero
    {
        from = "OctopusGirl",
        to = "OctopusGirl_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Gloopie -> Gloopie Primo
    {
        from = "Penguin",
        to = "Penguin_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Pengullet -> Pengullet Lux
    {
        from = "PinkRabbit",
        to = "PinkRabbit_Grass",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Ribbuny -> Ribbuny Botan
    {
        from = "PlantSlime",
        to = "PlantSlime_Flower",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Gumoss -> Gumoss Botan
    {
        from = "RaijinDaughter",
        to = "RaijinDaughter_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Dazzi -> Dazzi Noct
    {
        from = "RobinHood",
        to = "RobinHood_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Robinquill -> Robinquill Terra
    {
        from = "RockBeast",
        to = "RockBeast_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Pierdon -> Pierdon Cryst
    {
        from = "Ronin",
        to = "Ronin_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Bushi -> Bushi Noct
    {
        from = "SakuraSaurus",
        to = "SakuraSaurus_Water",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Broncherry -> Broncherry Aqua
    {
        from = "ScorpionMan",
        to = "ScorpionMan_Electric",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Prixter -> Prixter Lux
    {
        from = "Serpent",
        to = "Serpent_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Surfent -> Surfent Terra
    {
        from = "SharkKid",
        to = "SharkKid_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Gobfin -> Gobfin Ignis
    {
        from = "SkyDragon",
        to = "SkyDragon_Grass",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Quivern -> Quivern Botan
    {
        from = "StuffedShark",
        to = "StuffedShark_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Finsider -> Finsider Ignis
    {
        from = "Suzaku",
        to = "Suzaku_Water",
        category = "adaptation",
        minLevel = 40,
        stone = "adaptation",
        conditions = { "inWater" },
        enabled = true
    }, -- Suzaku -> Suzaku Aqua (inWater)
    {
        from = "SweetsSheep",
        to = "SweetsSheep_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Woolipop -> Woolipop Terra
    {
        from = "SwordCutlassfish",
        to = "SwordCutlassfish_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Skutlass -> Skutlass Ignis
    {
        from = "TentacleTurtle",
        to = "TentacleTurtle_Ground",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Turtacle -> Turtacle Terra
    {
        from = "ThunderBird",
        to = "ThunderBird_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Beakon -> Beakon Cryst
    {
        from = "ThunderDog",
        to = "ThunderDog_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Rayhound -> Rayhound Cryst
    {
        from = "Umihebi",
        to = "Umihebi_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Jormuntide -> Jormuntide Ignis
    {
        from = "VolcanicMonster",
        to = "VolcanicMonster_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Reptyro -> Reptyro Cryst
    {
        from = "VolcanoDragon",
        to = "VolcanoDragon_Ice",
        category = "adaptation",
        minLevel = 40,
        stone = "adaptation",
        enabled = true
    }, -- Moldron -> Moldron Cryst
    {
        from = "WeaselDragon",
        to = "WeaselDragon_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Chillet -> Chillet Ignis
    {
        from = "Werewolf",
        to = "Werewolf_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Loupmoon -> Loupmoon Cryst
    {
        from = "WhiteDeer",
        to = "WhiteDeer_Dark",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Celesdir -> Celesdir Noct
    {
        from = "WhiteMoth",
        to = "WhiteMoth_Neutral",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Sibelyx -> Sibelyx Primo
    {
        from = "WhiteTiger",
        to = "WhiteTiger_Ground",
        category = "adaptation",
        minLevel = 35,
        stone = "adaptation",
        enabled = true
    }, -- Cryolinx -> Cryolinx Terra
    {
        from = "WindChimes",
        to = "WindChimes_Ice",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Hangyu -> Hangyu Cryst
    {
        from = "WingGolem",
        to = "WingGolem_Fire",
        category = "adaptation",
        minLevel = 30,
        stone = "adaptation",
        enabled = true
    }, -- Knocklem -> Knocklem Ignis
    {
        from = "Yeti",
        to = "Yeti_Grass",
        category = "adaptation",
        minLevel = 45,
        stone = "adaptation",
        enabled = true
    }, -- Wumpo -> Wumpo Botan
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

-- ALL enabled options for a species (evolution + adaptations) - the choice
-- menu presents these filtered by affordability.
function Config.findPairs(characterId)
    local result = {}
    for _, pair in ipairs(Config.map) do
        if pair.enabled and pair.from == characterId then
            table.insert(result, pair)
        end
    end
    return result
end

-- Identity of a tree, as a short hex string. FNV-1a over the canonicalized pair
-- list: sorted, so two configs that hold the same pairs in a different order
-- hash the same, and only the fields that decide what an evolution DOES take
-- part. A host and a client comparing this can tell whether they are playing by
-- the same rules without moving the tree itself across the wire.
--
-- The canonical line EXTENDS upstream's (from>to|category|minLevel|stone|conds)
-- by the three fork-only fields that change what a pair does - free, anyOf and
-- an explicit materials list - because two fork maps differing only in them are
-- different trees and must never hash the same. nil and {} stay distinct for
-- materials (an empty list is a pair's way of buying out of the derived bill),
-- which is what the "-" marker is for. The at-most/counted conditions
-- (hpBelow:N, inParty:Id:N) need nothing extra: they ARE condition ids and
-- travel inside the two sorted lists.
--
-- minLevel prints with %g, never %d: a config_user number can arrive as 2.5 and
-- %d raises on a float in Lua 5.4 (house rule), while %g stays deterministic.
function Config.treeHash(map)
    map = map or Config.map
    if type(map) ~= "table" then return "0" end

    -- a condition list as one sorted term: order inside the list is authoring
    -- noise, not meaning
    local function sortedList(list)
        if type(list) ~= "table" or #list == 0 then return "" end
        local out = {}
        for _, c in ipairs(list) do table.insert(out, tostring(c)) end
        table.sort(out)
        return table.concat(out, ",")
    end

    local lines = {}
    for _, p in ipairs(map) do
        if p.enabled then
            local mats = "-"
            if type(p.materials) == "table" then
                local items = {}
                for _, m in ipairs(p.materials) do
                    table.insert(items, string.format("%s*%g",
                        tostring(m.id), tonumber(m.count) or 0))
                end
                table.sort(items)
                mats = table.concat(items, ",")
            end
            table.insert(lines, string.format("%s>%s|%s|%g|%s|%s|%s|%s|%s",
                tostring(p.from), tostring(p.to), tostring(p.category or ""),
                tonumber(p.minLevel) or 0, tostring(p.stone or ""),
                sortedList(p.conditions),
                p.free and "free" or "",
                sortedList(p.anyOf),
                mats))
        end
    end
    table.sort(lines)

    -- FNV-1a, with the 32-bit multiply split into 16-bit halves. The plain
    -- form overflows into a float on the way, and a float has no integer
    -- representation for the next xor - which means the same tree would hash
    -- differently depending on where it ran.
    -- Hex literals, because a decimal constant past 2^31 can arrive as a float
    -- in a Lua that maps numbers onto doubles, and a float cannot be xored.
    local PRIME = 0x01000193
    local hash = 0x811C9DC5

    local function mix(byte)
        hash = hash ~ byte
        -- every intermediate stays under 2^33 on purpose
        local lo = ((hash & 0xFFFF) * PRIME) & 0xFFFFFFFF
        local hi = ((((hash >> 16) & 0xFFFF) * PRIME) & 0xFFFF) << 16
        hash = (lo + hi) & 0xFFFFFFFF
    end

    for _, line in ipairs(lines) do
        for i = 1, #line do mix(line:byte(i)) end
        mix(10)     -- record separator, so concatenation cannot forge a match
    end
    return string.format("%08x", hash), #lines
end

-- Reverse/forward maps for the egg filter, split by category so eggs follow
-- EVOLUTION chains only. Funchain links are always excluded.
--   evoParents[to]    = { evolution froms }
--   adaParents[to]    = { adaptation froms }
--   adaChildren[from] = { adaptation tos } (element variants of a base)
local evoParentsCache, adaParentsCache, adaChildrenCache = nil, nil, nil
local function eggParents()
    if evoParentsCache == nil then
        evoParentsCache, adaParentsCache, adaChildrenCache = {}, {}, {}
        local function add(map, k, v)
            local list = map[k]
            if not list then list = {}; map[k] = list end
            for _, x in ipairs(list) do if x == v then return end end
            table.insert(list, v)
        end
        -- v1.7.3 (eggFilter.gateCrossAdaptations, default on): an adaptation
        -- that CHANGES SPECIES is an earned form like any evolution and joins
        -- the evolution-parent map, so eggs of it normalize to the base
        -- family. Only same-species element variants (to = from .. "_Suffix",
        -- the map's own naming convention) keep the never-gated adaptation
        -- treatment. With the switch off the classification is bit-identical
        -- to pre-1.7.3.
        local gateCross = not (Config.eggFilter
            and Config.eggFilter.gateCrossAdaptations == false)
        for _, pair in ipairs(Config.map) do
            if pair.enabled then
                if pair.category == "evolution" then
                    add(evoParentsCache, pair.to, pair.from)
                elseif pair.category == "adaptation" then
                    local variant = type(pair.to) == "string"
                        and type(pair.from) == "string"
                        and pair.to:sub(1, #pair.from + 1) == (pair.from .. "_")
                    if variant or not gateCross then
                        add(adaParentsCache, pair.to, pair.from)
                        add(adaChildrenCache, pair.from, pair.to)
                    else
                        add(evoParentsCache, pair.to, pair.from)
                    end
                end
            end
        end
    end
    return evoParentsCache, adaParentsCache, adaChildrenCache
end

-- Raw base candidates for an egg of `characterId`, following EVOLUTION chains
-- only. First, peel the id's own adaptation layers to reach the evolution chain
-- beneath it. Then walk evolution parents STRICTLY below the seeds; every node
-- reached that is an adaptation form OR an evolution root is a "family point".
-- Finally, expand each family point to its base family - the plain base reached
-- by peeling that point's adaptation, plus every element adaptation of that
-- base. So an interleaved chain contributes a base family at every adaptation
-- form it passes through, not only at the very bottom. A pure adaptation with
-- no evolution beneath yields nothing, so element variants hatch unchanged.
-- Config.baseFormsOf below resolves these to terminal forms.
local function rawBaseForms(characterId)
    local evoParents, adaParents, adaChildren = eggParents()

    -- plain base(s) of Y: peel Y's adaptation layers to forms with no adaptation
    -- parent (Y itself when it is not an adaptation form)
    local function plainBases(Y)
        if not adaParents[Y] then return { Y } end
        local out, seen, st = {}, {}, { Y }
        while #st > 0 do
            local cur = table.remove(st)
            local ps = adaParents[cur]
            if ps and #ps > 0 then
                for _, p in ipairs(ps) do
                    if not seen[p] then seen[p] = true; table.insert(st, p) end
                end
            else
                table.insert(out, cur)
            end
        end
        return out
    end

    local family, famSet = {}, {}
    local function addFamily(pointId)
        for _, b in ipairs(plainBases(pointId)) do
            if not famSet[b] then famSet[b] = true; table.insert(family, b) end
            local kids = adaChildren[b]
            if kids then
                for _, k in ipairs(kids) do
                    if not famSet[k] then famSet[k] = true; table.insert(family, k) end
                end
            end
        end
    end

    -- seeds: characterId plus its adaptation ancestors
    local seeds, seedSet, astack = {}, { [characterId] = true }, { characterId }
    while #astack > 0 do
        local cur = table.remove(astack)
        table.insert(seeds, cur)
        local ps = adaParents[cur]
        if ps then
            for _, p in ipairs(ps) do
                if not seedSet[p] then seedSet[p] = true; table.insert(astack, p) end
            end
        end
    end

    -- evolution walk strictly below the seeds; expand every family point
    -- (adaptation form or evolution root) it reaches
    local visited, estack = {}, {}
    for _, s in ipairs(seeds) do
        local ps = evoParents[s]
        if ps then for _, p in ipairs(ps) do table.insert(estack, p) end end
    end
    while #estack > 0 do
        local cur = table.remove(estack)
        if not visited[cur] then
            visited[cur] = true
            if adaParents[cur] or not evoParents[cur] then addFamily(cur) end
            local ps = evoParents[cur]
            if ps then
                for _, p in ipairs(ps) do
                    if not visited[p] then table.insert(estack, p) end
                end
            end
        end
    end

    -- never resolve to the egg's own species
    if famSet[characterId] then
        local filtered = {}
        for _, id in ipairs(family) do
            if id ~= characterId then table.insert(filtered, id) end
        end
        return filtered
    end
    return family
end

-- All distinct base forms an egg of `characterId` may hatch. Resolves the raw
-- candidates to TERMINAL forms: a candidate that is itself an evolution target
-- (an intermediate on an interleaved chain, where an element-adapted form also
-- evolves from something) is replaced by its own base forms. This makes every
-- returned candidate a fixed point, so the egg filter's per-egg pick is stable
-- and repeated hook fires never re-normalize a chosen base to a deeper one.
function Config.baseFormsOf(characterId)
    local result, resultSet, seen = {}, {}, {}
    local worklist = {}
    for _, c in ipairs(rawBaseForms(characterId)) do table.insert(worklist, c) end
    while #worklist > 0 do
        local cur = table.remove(worklist)
        if not seen[cur] then
            seen[cur] = true
            local sub = rawBaseForms(cur)
            if #sub == 0 then
                if cur ~= characterId and not resultSet[cur] then
                    resultSet[cur] = true
                    table.insert(result, cur)
                end
            else
                for _, s in ipairs(sub) do
                    if not seen[s] then table.insert(worklist, s) end
                end
            end
        end
    end
    return result
end

-- Deterministic single base (first reachable) - kept for any caller that does
-- not want the random pick; the egg filter uses baseFormsOf directly.
function Config.baseFormOf(characterId)
    return (Config.baseFormsOf(characterId))[1]
end

-- Set by the stoneNames merge below and read by the preset resolution at the
-- bottom of this file: an explicit user-set name string must survive a
-- primedNaming = false preset flip PER KEY (renaming one stone must not pin
-- the other to the primed default). Module scope - the resolution runs even
-- when no user file exists.
--
-- Also read by costs.lua (same table, filled by the merge below): the primed
-- preset's strings are exactly what the data half registers as the item names,
-- so a cost line can safely take the game's own LOCALIZED name there - but a
-- name the user set explicitly is a deliberate override OF that data half and
-- has to beat it.
local userNamedStones = {}
Config.stoneNames.userNamed = userNamedStones

-- The mod's own folder under the game's Saved tree. ONE definition: the user
-- overlay below, the in-game options cache further down and modoptions.lua's
-- writer all hang off it, so a layout change can never move only half of them.
-- nil when the environment has no LOCALAPPDATA (every caller falls back).
Config.userDir = (function()
    local localAppData = os.getenv("LOCALAPPDATA")
    if not localAppData then return nil end
    return localAppData .. "\\Pal\\Saved\\Palvolve"
end)()

-- Where this mod's own scripts folder would find a config_user.lua, or nil.
-- The AppData copy wins over that one, so an edit there changes nothing and
-- reads as the mod ignoring the config - worth naming in the log.
local function scriptsConfigPath()
    local found = nil
    pcall(function() found = package.searchpath("config_user", package.path) end)
    return found
end

-- Optional user overlay: the configurator at palvolve.doodesch.de generates
-- a config_user.lua. It replaces the pair map wholesale and merges a
-- whitelist of globals. Preferred location (identical on every PC, works for
-- Workshop installs where the mod folder is managed by Steam):
--   %LocalAppData%\Pal\Saved\Palvolve\config_user.lua
-- Fallback: next to this file. Mod updates never touch the user file.
--
-- Returns the table, the path it came from, and every path this pass actually
-- LOOKED at - the fallback notice below names them, so "the mod ignores my
-- config" answers itself from the log instead of from a support thread.
local function loadUserConfig()
    local checked = {}
    local dir = Config.userDir
    if dir then
        local path = dir .. "\\config_user.lua"
        table.insert(checked, path)
        -- existence is probed separately from loadfile so a file that IS there
        -- but does not compile reports its syntax error, instead of falling
        -- through silently as if nothing had been dropped in the folder
        local present = io.open(path, "r")
        if present then
            present:close()
            local chunk, loadErr = loadfile(path)
            if not chunk then
                print(string.format("[Palvolve] user config at %s does not compile: %s\n",
                    path, tostring(loadErr)))
            else
                local okChunk, result = pcall(chunk)
                if okChunk and type(result) == "table" then
                    return result, path, checked
                end
                print(string.format("[Palvolve] user config at %s did not return a table: %s\n",
                    path, tostring(result)))
            end
        else
            -- make the documented drop folder exist so users only have to
            -- paste the path; probe first to avoid a shell call on every start
            local probe = io.open(dir .. "\\.palvolve", "w")
            if probe then
                probe:close()
                os.remove(dir .. "\\.palvolve")
            else
                pcall(os.execute, 'mkdir "' .. dir .. '" >nul 2>nul')
            end
        end
    end
    local fallback = scriptsConfigPath()
    table.insert(checked, fallback or "scripts\\config_user.lua")
    local okReq, result = pcall(require, "config_user")
    if okReq and type(result) == "table" then return result, fallback or "scripts", checked end
    return nil, nil, checked
end

local user, userSource, userChecked = loadUserConfig()
if user then
    if type(user.map) == "table" then
        local cleaned = {}
        for _, p in ipairs(user.map) do
            if type(p) == "table" and type(p.from) == "string" and type(p.to) == "string" then
                p.category = p.category or "evolution"
                p.minLevel = tonumber(p.minLevel) or 1
                p.stone = p.stone or (p.category == "adaptation" and "adaptation" or "evolution")
                if p.enabled == nil then p.enabled = true end
                if p.free ~= nil then p.free = p.free == true end
                -- a scalar in either list-shaped field would sanitize to
                -- empty/empty and vanish with zero console evidence - the one
                -- malformation the drop log below cannot see
                if p.conditions ~= nil and type(p.conditions) ~= "table" then
                    print(string.format("[Palvolve] %s -> %s: conditions must be an array - ignored\n",
                        p.from, p.to))
                    p.conditions = nil
                end
                if p.anyOf ~= nil and type(p.anyOf) ~= "table" then
                    print(string.format("[Palvolve] %s -> %s: anyOf must be an array - ignored\n",
                        p.from, p.to))
                    p.anyOf = nil
                end
                if p.conditions ~= nil then
                    -- unknown ids are dropped (fail open: a config written for
                    -- a newer vocabulary must not brick this pair entirely);
                    -- runtime failures of KNOWN ids fail closed in conditions.lua
                    local clean, dropped = Conditions.sanitize(p.conditions)
                    p.conditions = (#clean > 0) and clean or nil
                    if #dropped > 0 then
                        print(string.format("[Palvolve] %s -> %s: dropped unknown conditions: %s\n",
                            p.from, p.to, table.concat(dropped, ", ")))
                    end
                end
                if p.anyOf ~= nil then
                    -- same fail-open drop as the AND list above; an emptied
                    -- group must go back to nil so the pair reads unconditioned
                    local clean, dropped = Conditions.sanitize(p.anyOf)
                    p.anyOf = (#clean > 0) and clean or nil
                    if #dropped > 0 then
                        print(string.format("[Palvolve] %s -> %s: dropped unknown anyOf conditions: %s\n",
                            p.from, p.to, table.concat(dropped, ", ")))
                    end
                end
                table.insert(cleaned, p)
            end
        end
        if #cleaned > 0 then
            -- Keep the shipped tree reachable. Two processes running the same
            -- mod version ship the same built-in map, so a client that knows
            -- the host runs the built-in tree already holds it byte for byte
            -- and needs nothing transferred. Dropping the reference here would
            -- make that impossible for anyone who loaded their own config.
            Config.builtinMap = Config.builtinMap or Config.map
            Config.map = cleaned
            evoParentsCache = nil
        end
    end
    if type(user.eggFilter) == "table" then
        if user.eggFilter.enabled ~= nil then
            Config.eggFilter.enabled = user.eggFilter.enabled == true
        end
        if user.eggFilter.gateCrossAdaptations ~= nil then
            Config.eggFilter.gateCrossAdaptations = user.eggFilter.gateCrossAdaptations == true
        end
    end
    -- Whitelisted on purpose: the diagnostics that name a CharacterID sit behind
    -- devMode, and the copy next to the mod belongs to Steam on a Workshop
    -- install, where the next update reverts an edit to it.
    if user.devMode ~= nil then
        Config.devMode = user.devMode == true
    end
    if user.diagReveal ~= nil then
        Config.diagReveal = user.diagReveal == true
    end
    if user.requireStone ~= nil then
        Config.requireStone = user.requireStone == true
    end
    if user.withdrawCancels ~= nil then
        Config.withdrawCancels = user.withdrawCancels == true
    end
    if user.techCensus ~= nil then
        Config.techCensus = user.techCensus == true
    end
    -- Integer 1..100, clamped HERE and not at the read site: the read site
    -- REWRITES a data file, so a stray 0, a float or a string must never reach
    -- it. Anything that is not a number leaves the default standing.
    if user.techLevelCap ~= nil then
        local cap = tonumber(user.techLevelCap)
        if cap then
            cap = math.floor(cap)
            if cap < 1 then cap = 1 end
            if cap > 100 then cap = 100 end
            Config.techLevelCap = cap
        end
    end
    if user.worksuitRefresh ~= nil then
        Config.worksuitRefresh = user.worksuitRefresh == true
    end
    if user.unlockCatchTech ~= nil then
        Config.unlockCatchTech = user.unlockCatchTech == true
    end
    if type(user.stoneNames) == "table" then
        if user.stoneNames.primedNaming ~= nil then
            Config.stoneNames.primedNaming = user.stoneNames.primedNaming == true
        end
        for _, k in ipairs({ "evolution", "adaptation" }) do
            if type(user.stoneNames[k]) == "string" and user.stoneNames[k] ~= "" then
                Config.stoneNames[k] = user.stoneNames[k]
                userNamedStones[k] = true
            end
        end
    end
    if type(user.statusEvolutions) == "table" then
        if user.statusEvolutions.enabled ~= nil then
            Config.statusEvolutions.enabled = user.statusEvolutions.enabled == true
        end
        for _, k in ipairs({ "x", "y", "lineHeight", "maxLines" }) do
            if user.statusEvolutions[k] ~= nil then
                Config.statusEvolutions[k] = user.statusEvolutions[k]
            end
        end
    end
    if type(user.palpediaEvolutions) == "table" then
        if user.palpediaEvolutions.enabled ~= nil then
            Config.palpediaEvolutions.enabled = user.palpediaEvolutions.enabled == true
        end
        for _, k in ipairs({ "toggleKey", "tabX", "tabY", "x", "y", "lineHeight", "maxLines",
                             "textScale", "wrapChars" }) do
            if user.palpediaEvolutions[k] ~= nil then
                Config.palpediaEvolutions[k] = user.palpediaEvolutions[k]
            end
        end
    end
    if type(user.costs) == "table" then
        for _, k in ipairs({ "enabled", "slots", "minRate", "countScale", "maxCount" }) do
            if user.costs[k] ~= nil then Config.costs[k] = user.costs[k] end
        end
    end
    if type(user.autoEvolve) == "table" then
        -- booleans coerced like eggFilter/requireStone above; the numeric
        -- keys are tonumber-guarded where they are consumed
        if user.autoEvolve.enabled ~= nil then
            Config.autoEvolve.enabled = user.autoEvolve.enabled == true
        end
        if user.autoEvolve.basePals ~= nil then
            Config.autoEvolve.basePals = user.autoEvolve.basePals == true
        end
        for _, k in ipairs({ "intervalSeconds", "cooldownSeconds", "baseIntervalSeconds" }) do
            if user.autoEvolve[k] ~= nil then Config.autoEvolve[k] = user.autoEvolve[k] end
        end
    end
    if type(user.evolveNotify) == "table" then
        -- both keys are booleans, coerced like the sections above
        if user.evolveNotify.enabled ~= nil then
            Config.evolveNotify.enabled = user.evolveNotify.enabled == true
        end
        if user.evolveNotify.chatFallback ~= nil then
            Config.evolveNotify.chatFallback = user.evolveNotify.chatFallback == true
        end
        if user.evolveNotify.flavorLine ~= nil then
            Config.evolveNotify.flavorLine = user.evolveNotify.flavorLine == true
        end
        if user.evolveNotify.darnToasts ~= nil then
            Config.evolveNotify.darnToasts = user.evolveNotify.darnToasts == true
        end
        -- clamping happens at the read site (startEvolutionWithFlavor)
        local flavorLead = tonumber(user.evolveNotify.flavorLeadMs)
        if flavorLead ~= nil then
            Config.evolveNotify.flavorLeadMs = flavorLead
        end
    end
    if type(user.evolveProtection) == "table" then
        if user.evolveProtection.enabled ~= nil then
            Config.evolveProtection.enabled = user.evolveProtection.enabled == true
        end
        for _, k in ipairs({ "healPumpMs", "maxWindowSeconds" }) do
            if user.evolveProtection[k] ~= nil then Config.evolveProtection[k] = user.evolveProtection[k] end
        end
    end
    if type(user.primedPals) == "table" then
        if user.primedPals.enabled ~= nil then
            Config.primedPals.enabled = user.primedPals.enabled == true
        end
        for _, k in ipairs({ "chance", "hpThreshold", "scanIntervalSeconds",
            "range", "levelGrace", "maxPerScan", "telegraphMs" }) do
            if user.primedPals[k] ~= nil then Config.primedPals[k] = user.primedPals[k] end
        end
        if type(user.primedPals.environmentChance) == "table" then
            Config.primedPals.environmentChance = user.primedPals.environmentChance
        end
        -- the global situational gate, sanitized exactly like the map pairs:
        -- deduped, unknown ids dropped fail-open with a named log line, and a
        -- scalar called out because it would otherwise sanitize to empty and
        -- vanish with no console evidence. An emptied list stays {} - the
        -- no-op default - and never nil: both lists are read unguarded.
        for _, k in ipairs({ "conditions", "anyOf" }) do
            local raw = user.primedPals[k]
            if raw ~= nil and type(raw) ~= "table" then
                print(string.format("[Palvolve] primedPals.%s must be an array - ignored\n", k))
            elseif type(raw) == "table" then
                local clean, dropped = Conditions.sanitize(raw)
                Config.primedPals[k] = clean
                if #dropped > 0 then
                    print(string.format("[Palvolve] primedPals.%s: dropped unknown conditions: %s\n",
                        k, table.concat(dropped, ", ")))
                end
            end
        end
    end
    if type(user.wildLevelLimit) == "table" then
        -- booleans coerced like the sections above
        if user.wildLevelLimit.enabled ~= nil then
            Config.wildLevelLimit.enabled = user.wildLevelLimit.enabled == true
        end
        if user.wildLevelLimit.includeAdaptations ~= nil then
            Config.wildLevelLimit.includeAdaptations = user.wildLevelLimit.includeAdaptations == true
        end
        if user.wildLevelLimit.exemptAlphas ~= nil then
            Config.wildLevelLimit.exemptAlphas = user.wildLevelLimit.exemptAlphas == true
        end
        if user.wildLevelLimit.genderFaithful ~= nil then
            Config.wildLevelLimit.genderFaithful = user.wildLevelLimit.genderFaithful == true
        end
        if user.wildLevelLimit.npcOtomo ~= nil then
            Config.wildLevelLimit.npcOtomo = user.wildLevelLimit.npcOtomo == true
        end
        if user.wildLevelLimit.mode ~= nil then
            -- validate to the two allowed strings; anything else -> "devolve"
            Config.wildLevelLimit.mode =
                (user.wildLevelLimit.mode == "levelFloor") and "levelFloor" or "devolve"
        end
    end
    print(string.format("[Palvolve] user config loaded (%d pairs, %s)\n", #Config.map, tostring(userSource)))
    local shadowed = scriptsConfigPath()
    if shadowed and shadowed ~= userSource then
        print(string.format("[Palvolve] a second config_user.lua sits at %s and is IGNORED while the one above loads\n",
            shadowed))
    end
else
    -- Without this line a config that never arrived is indistinguishable from one
    -- that loaded: the mod just runs its built-in tree, and the only symptom is a
    -- species the player configured showing no evolution at all.
    print(string.format("[Palvolve] no user config found, running the built-in tree (%d pairs). Checked: %s\n",
        #Config.map, table.concat(userChecked or {}, ", ")))
end

-- ===================== In-game options (third layer) =======================
-- Precedence, lowest to highest:
--   config.lua defaults  <-  config_user.lua  <-  in-game options (top)
--
-- The Mod Options Framework publishes its values ASYNCHRONOUSLY, a second or
-- more after this file has finished loading, so the menu cannot be read from
-- here. modoptions.lua therefore mirrors every applied value into
-- options_cache.lua beside config_user.lua, and THIS pass is what makes those
-- values real - which is exactly what "Applies at next launch." means on a
-- menu row. Live rows are written straight into this table at Apply time and
-- ride the cache only to survive the restart.
--
-- Position is load-bearing: AFTER the user merge (the menu is the newer, more
-- deliberate intent and must win over a file the player edited once) and
-- BEFORE the preset resolution below (a primedNaming flip from the menu has to
-- reach that pass exactly like a config_user one).
--
-- The cache is a file on disk like any other and is never trusted: whitelisted
-- keys only, each coerced and clamped in the same style as the user merge, and
-- a key is only written when config.lua already declares it (no invented
-- settings, no invented subtables). The list mirrors modoptions.lua's ROWS -
-- it cannot import them (modoptions requires THIS file), so a key added there
-- and not here simply never survives a restart; it still applies live.
--
-- ONE pcall around the WHOLE pass, not just around the load. The cache is an
-- executable Lua file: a corrupt or hostile copy can return a perfectly valid
-- table whose metatable throws on __index, and every cache[key] read below
-- would then raise INSIDE require("config") - which is the first thing every
-- module does, so it would take the entire mod down at startup. Anything that
-- goes wrong in here costs the in-game options layer one log line and nothing
-- else; config.lua's own defaults and config_user.lua still stand.
do
    local okLayer, errLayer = pcall(function()
        local cache = nil
        if Config.userDir then
            -- loadfile answers nil on a missing OR malformed file and never raises,
            -- and the chunk itself is pcall'd: a corrupted cache is simply ignored
            local chunk = loadfile(Config.userDir .. "\\options_cache.lua")
            if chunk then
                local okChunk, result = pcall(chunk)
                if okChunk and type(result) == "table" then cache = result end
            end
        end
        if cache then
            -- "b" = boolean; { min, max, isInt } = number, clamped (floored when
            -- isInt); { "enum", ... } = one of the listed strings; "k" = a UE4SS
            -- key NAME, which must exist in the live Key table - RegisterKeyBind
            -- is handed Key[name] unguarded, so a bogus name here would take a
            -- module's whole init with it.
            local RULES = {
                ["autoEvolve.enabled"]                = "b",
                ["autoEvolve.basePals"]               = "b",
                ["autoEvolve.cooldownSeconds"]        = { 0, 600, true },
                ["withdrawCancels"]                   = "b",
                ["unlockCatchTech"]                   = "b",
                ["evolveProtection.enabled"]          = "b",
                ["confirmKey"]                        = "k",
                ["primedPals.enabled"]                = "b",
                ["primedPals.chance"]                 = { 0, 100, true },
                ["primedPals.hpThreshold"]            = { 0.05, 1.0, false },
                ["primedPals.telegraphMs"]            = { 400, 10000, true },
                ["wildLevelLimit.enabled"]            = "b",
                ["wildLevelLimit.mode"]               = { "enum", "devolve", "levelFloor" },
                ["wildLevelLimit.genderFaithful"]     = "b",
                ["wildLevelLimit.npcOtomo"]           = "b",
                ["wildLevelLimit.exemptAlphas"]       = "b",
                ["wildLevelLimit.includeAdaptations"] = "b",
                ["eggFilter.enabled"]                 = "b",
                ["eggFilter.gateCrossAdaptations"]    = "b",
                ["evolveNotify.enabled"]              = "b",
                ["evolveNotify.chatFallback"]         = "b",
                ["evolveNotify.flavorLine"]           = "b",
                ["evolveNotify.flavorLeadMs"]         = { 0, 5000, true },
                ["evolveNotify.darnToasts"]           = "b",
                ["finale.style"]                      = { "enum", "layered", "legacy" },
                ["digimon.elementColors"]             = "b",
                ["palpediaEvolutions.enabled"]        = "b",
                ["palpediaEvolutions.toggleKey"]      = "k",
                ["palpediaEvolutions.textScale"]      = { 0.4, 1.5, false },
                ["statusEvolutions.enabled"]          = "b",
                ["requireStone"]                      = "b",
                ["costs.enabled"]                     = "b",
                ["stoneNames.primedNaming"]           = "b",
                ["worksuitRefresh"]                   = "b",
                ["techLevelCap"]                      = { 1, 100, true },
                ["devMode"]                           = "b",
            }
            -- dotted key -> (owning table, final key); nil unless every parent AND
            -- the leaf already exist
            local function slotOf(path)
                local t, last = Config, nil
                for part in path:gmatch("[^.]+") do
                    if last ~= nil then
                        t = t[last]
                        if type(t) ~= "table" then return nil end
                    end
                    last = part
                end
                if last == nil or t[last] == nil then return nil end
                return t, last
            end
            local applied, rejected = 0, 0
            for key, rule in pairs(RULES) do
                local raw = cache[key]
                if raw ~= nil then
                    local value = nil
                    if rule == "b" then
                        if type(raw) == "boolean" then value = raw end
                    elseif rule == "k" then
                        -- pcall'd: Key may not exist at all on some builds, and an
                        -- unusable name must leave the default standing
                        local okKey, code = pcall(function() return Key[raw] end)
                        if type(raw) == "string" and okKey and type(code) == "number" then
                            value = raw
                        end
                    elseif rule[1] == "enum" then
                        for i = 2, #rule do
                            if raw == rule[i] then value = raw end
                        end
                    else
                        local n = tonumber(raw)
                        if n and n == n and n ~= math.huge and n ~= -math.huge then
                            if rule[3] then n = math.floor(n) end
                            if n < rule[1] then n = rule[1] end
                            if n > rule[2] then n = rule[2] end
                            value = n
                        end
                    end
                    local t, last = nil, nil
                    if value ~= nil then t, last = slotOf(key) end
                    if t ~= nil then
                        t[last] = value
                        applied = applied + 1
                    else
                        rejected = rejected + 1
                    end
                end
            end
            print(string.format(
                "[Palvolve] in-game options applied (%d values%s)\n",
                applied,
                rejected > 0 and string.format(", %d rejected", rejected) or ""))
        end
    end)
    if not okLayer then
        print(string.format(
            "[Palvolve] in-game options layer skipped (%s)\n",
            tostring(errLayer)))
    end
end

-- Presentation preset resolution: runs AFTER the defaults, the user merge and
-- the in-game options layer, so a primedNaming flip from EITHER source takes
-- effect (that ordering is why the cache pass sits above), and never overwrites a
-- name string the user set explicitly (userNamedStones). costs.lua and the
-- prompt surfaces only ever read stoneNames.evolution/adaptation, so the
-- whole preset collapses to these two strings plus the kind-tag branch in
-- evolution.lua.
if Config.stoneNames.primedNaming == false then
    if not userNamedStones.evolution then
        Config.stoneNames.evolution = Config.stoneNames.classicEvolution
    end
    if not userNamedStones.adaptation then
        Config.stoneNames.adaptation = Config.stoneNames.classicAdaptation
    end
end

return Config
