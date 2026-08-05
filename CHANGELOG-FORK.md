# Changelog

## [1.10.0] - 2026-08-05 (community build, with the author's permission)

Full upstream sync: everything from DooDesch's Palvolve 1.4.3 and 1.5.0 now lives in the fork. All of the ported behavior below is his work; the credit is his.

### Added

- **Work suitability follows the evolution at the Pal itself** (upstream 1.5.0). Evolve a hauler into a miner and the base camp hands out mining, not a relog later - the answer the game asks through a path scripts can never reach now comes from the mod's native companion, which locates that path at startup, checks it against the game's own answers across every work type, and leaves it alone (saying so in the log) if a game update moves it. The bundled companion is updated to upstream's 1.5.0 build. The fork keeps its own measured refresh pipeline from the 1.8.x investigation as the fallback when the companion is absent - and as developer-mode forensics, where its receipts still measure only what the mod's own writes changed, never what the native override serves.
- **The Survival Guide carries the evolution tree your world actually runs** (upstream 1.5.0): every species that can evolve, what each target needs, and what it costs, in the game's own guide screen. Pages regenerate from your configuration and appear at the next game start, like every guide entry. The fork builds its pages in small time-budgeted slices - this tree runs hundreds of routes, and upstream's single build would hitch the game thread - and waits for the game's text tables to wake before the first slice, so pages never carry raw internal ids.
- **The evolve wheel names what a target asks for** (upstream 1.5.0): hovering a target shows its level, conditions and materials in the middle of the wheel. Every native call this adds inside the wheel-injection window joins the crash-forensics breadcrumb ladder, in vocabulary the ladder's reading rules cannot confuse with its own.
- **`!palvolve tree`** (upstream 1.5.0) answers which tree a world runs: a short identity hash, the pair count, and whether it is the built-in one. The fork's hash also covers its own pair fields (free, either/or groups, explicit materials), so two fork trees differing only there still read apart.
- **A greyed-out Evolve entry tells the player why** (upstream 1.4.3/1.5.0), once per cause per session - host not confirmed, no Pal out, someone else's Pal, or nothing configured for the species - and the log names the reason whenever it changes.
- **Config loading diagnostics** (upstream 1.5.0): a missing `config_user.lua` now says so and names the folders it checked; one that does not compile reports its syntax error instead of being skipped in silence; a second copy sitting next to the mod's scripts is named and ignored.
- **`devMode = true` can go into your own `config_user.lua`** (upstream 1.5.0), where it survives updates - it used to require editing a mod file that every sync overwrote. The reveal-diagnostics switch (`diagReveal`) rides along.

### Fixed

- Evolution material and stone names in the new guide pages and wheel text resolve at message time in your game language, and the new text is localized in all 17 languages via upstream's own catalog.

### Fixed

- **Breadcrumbs for a crash-to-desktop on opening the radial menu.** A player's game died the instant the wheel was opened, and the log ends mid-sequence: the mod's own census line is written, the "Evolve entry injected" line never arrives. A fault in any native call in that window takes the process down without a Lua error or a log flush - so the log can never say which one. Every native call in the window is now bracketed to a small file beside the mod's state file (`radial_stage.txt`): both injection paths, the submenu build, and every touch of the label widgets the wheel keeps across opens - the last "entering" line with no matching "survived" line names the culprit outright, every closer carries the call's actual verdict rather than a blind success, a skipped stale widget leaves a record instead of a silent gap, and a completed pass writes a positive "window complete" line so survival is a fact, never an inference. This build changes no behavior; it exists to convict on the next occurrence. The same technique retired the technology census in 1.7.7 after one session.

## [1.9.8] - 2026-08-01 (community build, with the author's permission)

### Added

- **Primed Pals answer to the weather now.** Two new config keys, `primedPals.conditions` and `primedPals.anyOf`, gate ALL wild primed evolutions on world and pal state - same vocabulary as the evolution map's conditions (day/night, weather, regions, the wild pal's own gender, moves, status, HP; `!` negation included). Everything in `conditions` plus at least one of `anyOf` must hold, on top of the usual low-HP, level and chance gates - so `conditions = { "night" }, anyOf = { "thunderstorm", "raining" }` means the wild only stirs on stormy nights. A blocked pal stays eligible - deny it at noon and it may rise at dusk. Empty lists (the default) change nothing. Region questions are answered from the nearby player's position exactly like the map's wild conditions; the three player-body ids (`inWater`, `isRiding`, `isGliding`) don't describe a wild pal meaningfully and should stay out of this gate. When the gate is set, the log says so at arming, and developer logging counts what it blocks.

### Changed

- **`inParty` no longer counts the aspirant itself - and takes a count.** The condition always walked every party slot including the evolving pal's own, so a same-species requirement (`inParty:Alpaca` on Melpaca, the Swee retinue, the Depresso entourage) was satisfied by the pal matching *itself*. It now excludes the evolving individual - by identity, not species - so "in party with an Alpaca" finally means *another* Alpaca. And the new counted form `inParty:<Pal>:<n>` (n up to 4) demands a proper posse: `inParty:NegativeKoala:2` wants two fellow Depressos beyond the aspirant. Menus and refusal reasons render it honestly ("2+ Depresso in party"), and an unreadable party identity satisfies nothing in either polarity, per the house rule. If a map somewhere genuinely relied on a pal being its own entourage, that pair now needs a real companion - which is almost certainly what it meant all along.

## [1.9.7] - 2026-07-31 (community build, with the author's permission)

### Changed

- **A named price is always a real price.** A pair in the evolution map can carry an explicit `materials = { { id = "...", count = n }, ... }` list - its own bill of goods, in whatever items the tree's author names. Until now that list only charged while the Material Costs switch was on, which conflated two different things: the switch generates material bills *derived from drop tables* across every costed pair, while a per-pair list is a deliberate piece of one evolution's design. They are now properly separate - an explicit list charges whether the switch is on or off (and such a pair is never treated as free, so it can never auto-fire), while the switch keeps gating exactly what it generates: the derived bills. An empty list (`materials = {}`) remains the documented buy-out that silences the derived bill for one pair. No shipped configuration changes price; this matters only to maps that name their own materials - say, an alien line that demands meteorite fragments.

## [1.9.6] - 2026-07-31 (community build, with the author's permission)

### Added

- **"Require Evolution Stones" joins both in-game settings pages.** It was the one switch the original mod lets you toggle from your config file that neither menu carried: the master lever that makes costed evolutions charge their stone (off = everything is free, and anything free may auto-fire). It now sits at the top of Costs & Naming on the Mod Options Framework page and the DarnMenu page alike, honestly labelled "Next launch." - the price of an evolution is computed once and remembered for the session, so a mid-session flip cannot take effect and the row does not pretend it could.

### Fixed

- **Material Costs no longer pretends to apply immediately.** The switch lives inside the same remembered price computation as the stone lever above, so flipping it mid-session would leave every already-priced evolution charging the old bill until relaunch. It is now a "Next launch." row like its neighbour - same behavior at startup, no more stale prices in between.

## [1.9.5] - 2026-07-31 (community build, with the author's permission)

### Added

- **Either/or conditions.** A pair in the evolution map can now carry `anyOf = { ... }` next to `conditions = { ... }`: everything in `conditions` must still hold, and at least one entry of `anyOf` must too. Same vocabulary, same `!` negation, and the same fail-closed rule - a condition the game cannot answer satisfies nothing, so a group whose members all fail to evaluate stays unmet. The menus, the Paldex panel and refusal reasons render the group as a single term - "Knows a Ground move + (Muddy or In the desert)" - in all 17 languages. Unknown ids inside a group are dropped at load with a log line naming the pair, a non-array value for either field now warns instead of vanishing silently, and base camps treat an either/or pair as conditioned - workers never take it on their own. One authoring rule: a hard gender demand belongs in `conditions`; inside a group it is an alternative, not a requirement (a single-member group, being no alternative at all, counts as the hard demand it is - including for wild-spawn gender fixing).

## [1.9.4] - 2026-07-31 (community build, with the author's permission)

### Added

- **DarnToasts + Panels support.** With [DarnToasts](https://steamcommunity.com/sharedfiles/filedetails/?id=3769416678) installed, Palvolve's notices - the evolution prompt, the "What's this?" beat, rollback confirmations - arrive as proper toasts in a "Palvolve" lane you can style, move and mute from the DarnToasts page (the lane and its mute toggle appear from the second launch, which is how DarnToasts works). And the transformation finally has a face: a progress panel with the pal's name and a bar walking Dissolving, Reforming, Returning, Revealing - closing cleanly on every outcome including aborts and recalls. Muting Palvolve there really mutes it (no vanilla notice sneaks through; the chat line, if you have it on, remains the guaranteed surface). Without DarnToasts nothing changes, and a new switch (`evolveNotify.darnToasts`) turns the whole thing off regardless.
- **DarnMenu support.** With [DarnMenu](https://steamcommunity.com/sharedfiles/filedetails/?id=3769456391) installed, Palvolve registers its own settings page there - the same 35 settings as the Mod Options Framework page, generated from the same definitions, with dependent rows greying out when their parent is off. Both menus write through one store, per key: whichever menu you touched a setting in last wins, and neither can revert the other's choices - not mid-session, not across sessions. Registration is careful with the shared index other mods also live in: a corrupt index is never overwritten (other mods' pages are never at risk from us), and the page repairs itself from DarnMenu's own backup when one exists.

## [1.9.3] - 2026-07-31 (community build, with the author's permission)

### Fixed

- Every in-game settings description now fits a single rendered line, giving the page real breathing room - the framework's row height is fixed, so shorter text is the one lever that adds whitespace. The dimmer look of descriptions is the framework's font sizing (11pt vs 18pt labels, same colour), which a consuming mod cannot change.

## [1.9.2] - 2026-07-31 (community build, with the author's permission)

### Fixed

- The in-game settings page no longer crowds itself. The framework gives every setting's explanation a fixed two-line slot and simply draws over the row beneath when the text runs longer - so a three-line explanation was swallowing the next setting's name. Every explanation now fits, the restart marker is the shorter "Next launch.", and the page header no longer overlaps the first section heading. The settings, their values and everything they do are unchanged.

## [1.9.1] - 2026-07-31 (community build, with the author's permission)

### Added

- **In-game settings via Mod Options Framework.** If you have [Mod Options Framework](https://steamcommunity.com/sharedfiles/filedetails/?id=3771664251) installed, Palvolve now appears in its Esc-menu page with 34 settings across eight sections - Evolution, Wild World, Eggs, Prompts, Presentation, Menus, Costs & Naming, and Advanced - so the switches that used to need a text editor are a few clicks away. The framework is entirely optional: without it the mod behaves exactly as before and says so in one log line, and nothing about your `config_user.lua` changes.
  - **Settings that can safely change mid-session do so immediately** (prompts, the flavor beat's timing, primed-pal chance and telegraph window, finale style, panel text scale). Anything that arms a hook at startup - auto-evolve, the wild-spawn filter, the egg filter, the Paldex tab, the evolve key - is labelled "Next launch." rather than pretending to take effect, and it genuinely does apply next launch: applied values are mirrored to `options_cache.lua` beside your config file, which is read during startup before any hook is armed. Delete that file to hand control back to `config_user.lua`.
  - **Precedence** is `config.lua` defaults, then your `config_user.lua`, then the in-game menu on top - and the menu only takes over once you press Apply. Until then your file is untouched, and the menu opens showing your file's current values.
  - **Options are per-client and carry no authority**, which is the framework's design, so the settings that only the host's world can honour (the wild filter, the egg filter) are labelled "Host only". Your evolution map itself stays a config-file feature - it is far too large for a settings page.

## [1.9.0] - 2026-07-30 (community build, with the author's permission)

Full upstream sync: everything remaining from DooDesch's Palvolve 1.4.1 and 1.4.2 now lives in the fork. All of the ported behavior below is his work; the credit is his.

### Added

- Rolling back an evolution returns what it cost (upstream 1.4.2): the exact items charged are recorded with the restore point at evolution time - material costs depend on the pal's level right then - and handed back to the pal's owner on rollback, with the chat line saying so ("Rollback: Foxcicle -> Foxparks - items returned"). Restore points are now session-only: one that outlived the session would refund level-drifted costs for a pal that may have been levelled, bred or traded since, so the old file-loaded restore points are discarded at launch. And the rolled-back pal shows its restored form immediately - if it is your active summon, it is recalled and re-summoned by its party slot a moment later, instead of standing there in the evolved body until you resummon it yourself.
- The Pal Alchemy Workbench unlock level is configurable (`techLevelCap`, default 10, settable from `config_user.lua`): the mod rewrites its own data-half building file through a write-verify-swap that can never truncate the live file, and the change applies at the next game start - the honest limit of data loaded before any script runs. The fork adds a recovery step upstream lacks: if a crash ever lands in the swap's narrow window, the set-aside backup is restored automatically on the next launch.
- Evolution material names come from the game's own item catalog in your language (upstream 1.4.1): cost lines resolve names at message time - never during world load, when the text system is not yet up and a too-early lookup would bake fallbacks in permanently - and the cost-line and rollback texts are localized in all 17 languages. The fork's stone-naming presets keep their meaning: your own configured names always win, the classic preset speaks upstream's names, and no label ever grows a doubled element suffix.
- The catch-tech unlock understands dedicated servers (upstream 1.4.1): the unlock call now names the player's own PlayerState so the server can resolve the true identity even when the replicated id is stale or empty - the failure mode that left saddles locked for connected players. A player whose unlock genuinely fails is told once, privately, in chat; species that share a Paldeck slot with their base form are correctly not treated as failures; and an unlock with no resolvable owner is skipped outright rather than landed on whoever the server would guess. Works with both the bundled native companion and upstream's updated one.

### Fixed

- The Evolve entry in the radial wheel survives UE4SS tearing down its own timer machinery mid-session (upstream 1.4.2): a heartbeat watches the registration loop, and if the loop has died the existing widget callback registers the wheel entry inline on the next menu open - the wheel no longer stays empty until a game restart.
- A non-integral material count in a hand-edited config (say 2.5 Wood) no longer crashes the cost line or the abort message - counts are floored wherever they are printed, and the failure path releases the evolution properly.

## [1.8.9] - 2026-07-30 (community build, with the author's permission)

Partial upstream sync: the three small fixes from DooDesch's Palvolve 1.4.1/1.4.2 that apply immediately (his work, his credit). The larger 1.4.2 features (rollback refunds and instant re-summon, the configurable workbench level, localized material names, the multiplayer unlock fix with its updated native component) are staged for a full sync build.

### Fixed

- Weather conditions calibrated against the game's own presets (upstream 1.4.2): `snowing` now sees the lightest snowfall state (its value sits far below the old bar), and `foggy` no longer fires on every clear night or during heavy snow - fog density alone overlaps everything, so the check now demands a dry sky and a genuinely foggy density. `raining` and `thunderstorm` were already correct.
- Chat commands answer to `!palvolve` (upstream 1.4.2): dedicated servers intercept `/`-prefixed chat with "You are not an Admin" before any mod can see it, so `!` is now the primary form everywhere - in the command matcher, the startup banners, the help and uninstall texts in all 17 languages, and the docs. `/palvolve` still works where the game allows it (singleplayer and listen hosts). Commands also match exactly now (`/palvolvefoo` no longer triggers) and replies are delivered a tick after the chat frame so they can't be swallowed or crash on a freed sender.
- Rollback replies on dedicated servers no longer answer twice (upstream 1.4.2): the chat hook runs on both sides of a connection, and the client's copy - which has no snapshots - would wrongly answer "no snapshot to restore"; replies now come only from the side that actually evaluated the command.

### Changed

- The FORK FEATURES index now documents the saddle-tech tree sync as what it is: a data-half feature with no runtime switch (PalSchema loads it before any Lua runs), removable by deleting its generated file - and the retired saddle-tech census is marked retired where the index lists its inert switch.

## [1.8.8] - 2026-07-30 (community build, with the author's permission)

### Changed

- The suitability investigation reaches its verdict, and the receipts now tell it straight. 1.8.6's discriminator ran on a live evolution and settled the three-way question in one pass: the rank rewrite genuinely lands in the pal's save structure - a completely fresh read of the array shows the new ranks, still there a second later - but the number the game displays comes from a native-side copy built once when the pal was constructed, and no data write from a mod can reach it on this game build. In-session, the panel simply cannot be told; at the next save & reload the game rebuilds everything from the species and all of it is correct. The receipt for this case no longer says "write did not stick" (it sticks fine): it now reports exactly what was measured - ranks written to the save struct, display is a native copy, panel updates at reload. The groundwork is all real and stays: the moment a future game build (or a native companion hook) exposes the display path, the whole pipeline behind it already works.

## [1.8.7] - 2026-07-30 (community build, with the author's permission)

### Added

- New evolution condition for custom trees: `hpBelow:<n>` - met while the pal's current HP is at most n percent of its maximum (1-99). It is the vocabulary's first at-MOST threshold (every other numeric reads at-least), built for death's-door evolutions: a free pair gated on `"hpBelow:1"` fires the moment a pal that should have died comes out of the fight alive. Negation follows the house rule - `"!hpBelow:25"` means HP above 25% - and an unreadable HP never satisfies either polarity. Named in the menus like every condition ("HP at most 1%", English for now with the standard fallback), validated by the same sanitizer as the other numeric thresholds.

## [1.8.6] - 2026-07-30 (community build, with the author's permission)

### Fixed

- The suitability hunt narrows to its last question. 1.8.5's receipts produced a genuine contradiction: the rank write now provably lands - re-reading the same array slot shows the new value, both fields - and yet the game's rank getter and the party panel still read the old ranks. Exactly one of three things can be true: the array handle the mod writes through is a detached copy, the getter reads a native-side cache the array doesn't feed, or the engine overwrites the array right after the evolution's reveal. This build tells them apart in one evolution: after the write it re-reads the array through a brand-new property access, attempts a whole-array write-back when that fresh read disagrees (the one deeper lever left, breadcrumb-bracketed like every unproven call), and checks once more a second later to catch an overwrite window. Every outcome is a named log line; nothing is left to interpretation. Also per its own review: an unreadable rank can never trigger the write-back - unmeasured is not evidence, in either direction.

## [1.8.5] - 2026-07-30 (community build, with the author's permission)

### Fixed

- The suitability rewrite now actually lands. 1.8.4's first live evolution produced the perfect diagnostic: the species ranks resolved from the new table, the write ran - and the read-back showed nothing moved, because the write went through an unwrapped copy of the array element and modified a temporary. Writes now go through a measured variant ladder - a direct field write on the raw element first, a whole-element assignment second - and each individual write is confirmed by re-reading that slot before it counts; the first variant that provably sticks is preferred for the rest of the session. The receipts stop guessing too: 1.8.4's no-change line said "already correct" when the truth was "the write vanished" - there are now three measured outcomes (refreshed with the delta list, ranks already match, or write did not stick), the comparison accounts for Applied-Technique ranks a pal has paid for, and a partial success flags that some ranks still need a save & reload. Also fixed on the evidence of the same session: an empty rank array (the mirror copy sits at zero rows mid-evolution while the engine refills it) is skipped instead of having rows grown into it, and a grown row now has its field values verified - the array getting longer never counted as the data being right.

## [1.8.4] - 2026-07-30 (community build, with the author's permission)

### Added

- Evolved and adapted pals now genuinely gain their new form's work suitabilities in the same session - the promise 1.8.1 made and could not keep. The missing piece was a rank source the game refuses to provide at runtime (every readable route came back empty or crash-convicted on this build), so the ranks now ship with the mod: a generated table of every obtainable species' vanilla work suitabilities - 299 of them, current through the latest content - (`scripts/worksuit_static.lua`, built by `tools/gen-worksuit.js` from datamined game data, exactly the saddle-tech approach; the only roster ids without rows are quest/tower/rig NPC variants no evolution map can produce). At the moment an evolution's new body is confirmed, the mod rewrites the cached rank array in place from that table - the census proved the array is dense, so this is pure rank rewrites, no risky array growth - and verifies by reading all thirteen ranks back: an Elphidran that adapts into an Elphidran Aqua starts Watering immediately, and the receipt says so ("refreshed via craftspeeds rebuild: Watering 0->4"). Alpha pals share their base form's ranks; condensation stars and rank-up books sit on top exactly as before, untouched. A species missing from the table degrades to the old behavior (new styles at save & reload) with an honest line naming it; the table only needs regenerating when the game itself adds new pals - your evolution map can change freely.

## [1.8.3] - 2026-07-30 (community build, with the author's permission)

### Fixed

- A crash-to-desktop on evolving, introduced by 1.8.2 and closed the same night by its own forensics. The real defect was older than 1.8.2: the evolution sequence's reveal step arms a repeating timer that was trusted to fire once because its body always finished within the 100ms reveal delay - 1.8.2's suitability work made that body slower than the delay, the timer re-fired every tick, and the reveal finale re-ran on top of itself until a fourth concurrent pass read freed memory. The timer now carries an explicit fired-once latch (matching its remote-presentation twin, which always had one), and the suitability refresh guards itself against ever being re-entered for the same pal - turned away before it touches anything. The breadcrumb file did its job on first use: it ends mid-census with every riskier step marked clean, which both located the fault and exonerated the new bridge calls of crashing. A full audit of all 27 such timers in the sequence engine found two more carrying the same latent assumption - the dissolve-to-teardown handoff (whose delay an effects prototype supplies with no lower bound, and whose double-run could refund a completed evolution) and the primed-pal telegraph - both now carry the same latch.
- The two experimental bridge probes from 1.8.2 are retired on the evidence of that same session: the species-rank database read runs cleanly but returns nothing on this game build (the same dead-end family as the retired tech census), and the replication-handler nudge visibly re-entered the game's replication reconciliation for zero measured benefit - manually invoking replication handlers on live objects is now on the banned list. One genuinely useful census result survives: the suitability cache is a dense 13-slot array on this build, so the in-place rank rewrite alone can fully retarget an evolved pal - no risky array growth needed, ever. The rank source will return as a generated static table (the saddle-tech approach: no runtime reads at all); until then the refresh honestly reports it has no rebuild source and new work styles arrive at the next save & reload, exactly as before 1.8.1.

## [1.8.2] - 2026-07-30 (community build, with the author's permission)

### Fixed

- The in-session work-suitability refresh now rebuilds the actual cache. 1.8.1's attempt was honest but wrong about the mechanism: its database re-apply call ran cleanly and changed nothing - proven live the same evening by an Elphidran that became an Elphidran Aqua and kept showing only Lumbering (the receipt said "no rank changed" and the panel agreed). The real story, from the SDK: the ranks the party screen draws live in a transient per-pal array (`CraftSpeeds`) inside the save-parameter struct - two full copies of it - stamped once at construction and never touched by a species change. The refresh now goes at that array directly: it reads the new species' true ranks from the game's own character database (with a fallback for Alpha pals whose BOSS row carries no suitability block), rewrites every existing row in both copies, and appends rows for genuinely new work types - an Elphidran Aqua gains Watering 4 on the spot, keeps Lumbering 3, and a paid Applied-Technique rank stays where the save put it. Every step is measured, never trusted: the thirteen ranks are read back through the same call the UI uses, the first proven refresh logs in any mode, a rank that moves without our write is reported as exactly that instead of being claimed, and the save-and-reload fallback remains the honest last line. The two genuinely unproven bridge shapes involved (a map-valued out-parameter and growing an array from Lua) are crumb-bracketed to `worksuit_stage.txt` - if either ever kills the game, the file names the culprit next session. New switch: `worksuitRefresh` (default on, settable from `config_user.lua`); `false` restores stock behavior, where new work styles arrive at the next save & reload.

## [1.8.1] - 2026-07-29 (community build, with the author's permission)

### Fixed

- Evolved and adapted pals now gain their new form's work suitabilities in the same session - an Elphidran that becomes an Elphidran Aqua starts Watering without waiting for a reload. The old behavior rested on an inherited upstream note claiming nothing could refresh the suitability cache in-session; re-investigation showed that note was never verified by reading values back, and that the game's own construction-time stat-stamping routine is directly callable. The mod now invokes it the moment the evolved pal's new body is confirmed alive, verifies by reading all thirteen suitability ranks before and after, and reports the first proof in the log ("refreshed via database re-apply: Watering 0->3"). Where no change is observed it says so honestly, and the save-and-reload fallback always remains (the save data was always correct - suitabilities re-derive from the new species at every load). The full heal is re-applied after the refresh so a re-derived maximum is topped up properly. Deliberately NOT included: a second refresh trick through the rank-up item machinery - it writes a field that persists into the save and its exact behavior cannot be read from the SDK, so it stays out until a proper probe session clears it.

## [1.8.0] - 2026-07-29 (community build, with the author's permission)

### Added

- **Saddle-tech sync**: every saddle and Pal Gear technology now appears in the Technology tree at the level its species first becomes reachable under your evolution map - the level the evolution or adaptation begins. Strict both ways (a late vanilla saddle drops to your map's level; an early one rises to it) and element variants included: Chillet Ignis at 30, Elphidran Aqua at 30, Vanwyrm at 32, Braloha at 33, all 73 of your map's gear-bearing species. Ships as a generated data-half override (`raw/palvolve_saddletech.jsonc`), so it applies to existing saves the moment it is installed - already-unlocked techs stay unlocked, and the catch requirement is untouched (evolving into a species still counts as catching it via the native companion). Regenerate after editing your map with `node tools/gen-saddletech.js` and reinstall the data half. Species whose gear tech could not be confirmed to exist are deliberately left at vanilla levels and listed by the generator; sixteen deep-endgame saddles inherit map levels above 60 - exactly as aspirational as the evolutions they mirror.

## [1.7.7] - 2026-07-29 (community build, with the author's permission)

### Fixed

- The saddle-tech census is retired - permanently on this game build. Its 1.7.6 breadcrumb ladder did exactly what it was built for: the crumb file ended at "entering probe" with no survival line, convicting the game's by-value technology-row read of both crash-to-desktops (and a follow-up run showed even the row-NAME reads return no usable content from Lua on this build). The module now no-ops with a one-line notice, and the conviction record lives in its header so nobody re-walks this path until a new game build revalidates it. The saddle-sync feature loses nothing: the technology row keys follow a plain naming convention (confirmed against community databases), so the level overrides can be generated straight from your evolution map with no runtime reads at all.

## [1.7.6] - 2026-07-29 (community build, with the author's permission)

### Fixed

- The saddle-tech census no longer runs its whole table read in one first pass - 1.7.5's single-shot read landed in the same second as a crash-to-desktop, and a native marshaling fault is exactly the kind of failure Lua cannot catch. The census now climbs a ladder, one rung per 15 seconds: row names first (which already yields a usable keys-only dump), then a single trial row read, then the full table - and it waits a real 45-60 seconds of continuous, settled world before touching anything, so it can never fire while you are spawning in or opening menus. Every risky step writes a crash-proof breadcrumb to `Saved\Palvolve\techcensus_stage.txt` before and after it runs: if a step ever kills the game, the file names it outright next session instead of leaving another silent mystery. A kill switch ships too (`techCensus = false` in your config_user turns the whole diagnostic off).

## [1.7.5] - 2026-07-29 (community build, with the author's permission)

### Added

- Groundwork for saddle-tech sync (planned: each rideable species' saddle appears in the Technology tree at the level your evolution map first makes the species reachable - strict both-ways sync, element variants included). This build ships the census half: in `devMode`, once per session, the recipe-unlock technology table is dumped - every tech row's key, level requirement, tier, cost and linked recipes - to `Saved\Palvolve\saddletech_dump.tsv`, read-only and hook-free, about thirty seconds after the world loads. That file is the input for the generator that will write the actual level overrides into the mod's data half. One log line reports the row count; a build where the table cannot be read says so instead of staying silent.

## [1.7.4] - 2026-07-29 (community build, with the author's permission)

### Fixed

- Eggs already incubating - or already sitting ready to hatch - when a save loads now obey the egg filter too. A ready egg restored from a save had already passed the moment the filter watched (its incubation finished before the save), and collecting it went through a game path the filter never saw - which is how a Braloha egg hatched a Braloha on a world that gates them. Two layers close it: once per world, as soon as the save has settled, every incubator is swept and its eggs normalized in place; and the multi-egg incubator's collect buttons are now intercepted directly, normalizing every slot before the game builds the pal. Nothing is left to the timing of who clicks what.
- Evolution prompts respect a chat-free setup: with `evolveNotify.chatFallback = false` the "Evolving into ..." progress lines no longer appear in chat either - the notice-feed toast is the one surface, and the auto-evolve line no longer names the evolution target during the "What's this?" beat's pause.
- The egg filter narrates itself properly in `devMode`: every hook prints budgeted fire receipts with the incubator class, a hook that finds no readable egg data says so, a hook that fails to register is named in the log, and the load sweep reports how many incubators it walked. "It hatched wrong and the log says nothing" cannot happen again.

## [1.7.3] - 2026-07-29 (community build, with the author's permission)

### Changed

- Eggs now respect cross-species adaptations (`eggFilter.gateCrossAdaptations`, on by default). The egg filter has always turned evolved forms back into their base species at hatch - but it followed **evolution** edges only, and an "adaptation" that leads to a whole different species (Dinossom's Earth branch into Braloha, say) slipped through: a Braloha egg hatched a Braloha in a world where Braloha is supposed to be earned. Now an adaptation edge that changes species gates eggs exactly like an evolution - a Braloha egg hatches Dinossom (or its Electric variant, as base families always worked) - while same-species element variants (Kelpie into Kelpie Ignis) keep hatching unchanged, so variant breeding stays possible. The map's own naming tells the two apart; set the switch to `false` for the old evolution-chains-only rule. The startup line now names the mode it is running.
- The egg filter explains itself in `devMode`: one line per distinct species that passes through unfiltered despite appearing in your map ("pass-through X (no gated ancestry)") and one per special egg left alone (WorldTree / Mutation eggs, or an egg whose item type cannot be read). The Braloha question - "did the filter miss this egg or judge it?" - is now answered by a single log line instead of an investigation.

## [1.7.2] - 2026-07-29 (community build, with the author's permission)

### Added

- Evolutions announce themselves before they happen (`evolveNotify.flavorLine`, on by default): the moment you commit an evolution - F2 confirm, radial pick, a connected client's request, or auto-evolve firing - the notice feed reads **"What's this? Cattiva is evolving?"**, and the transformation itself begins about a second and a half later (`evolveNotify.flavorLeadMs`, default 1500, up to 5000; 0 keeps the line and skips the pause). Adaptation pairs get their own sentence - "What's this? Fuack is adapting to its environment!" - decided by what the pair IS, not by which stone it charges. The pal keeps acting normally through the pause and the result line ("Cattiva evolved into Naughty Cat! (Lv 19)") still lands at the commit, so an off-screen evolution loses nothing. Recalling the pal during the beat cancels it exactly like recalling it during the dissolve - and since nothing has been charged yet, there is nothing to refund. Wild and primed evolutions stay silent as always, and base-camp workers skip the beat: nobody is watching a camp three regions away.
- NPC-companion pals obey your evolution map (`wildLevelLimit.npcOtomo`, on by default): the pals accompanying settlement guards, wandering merchants and faction NPCs now pass through the same level floors and gender rules as wild spawns. They always lotteried their species and level exactly like wilds, but they are built through a separate game path the filter never saw - which is how a male Katress could stroll through a village in a world whose map makes every Katress female. A unique (story) NPC's authored companion is always left untouched, and pals that already exist fix themselves on their next area reload - spawn-time rules never rewrite an existing individual. If the game build does not expose the NPC spawn path, the extension simply reports itself unavailable and the proven wild coverage is unaffected.

### Fixed

- Pressing the evolve key while a sequence (or the new pre-evolution beat) is already running now answers in chat instead of only in the log - a dead keypress during the beat looked like the mod ignoring input.
- An evolution that fails to start on the host after a connected client's request (for example, the cost item vanished in the meantime) now tells the requester why, instead of leaving them with a flavor line and silence.

## [1.7.1] - 2026-07-26 (community build, with the author's permission)

### Added

- Every fork feature is now switchable, and the top of `scripts/config.lua` carries the full index: each thing this build adds over stock Palvolve, next to the switch that turns it off - all of them settable from your `config_user.lua`, so a stock-Palvolve-plus-nothing session is one user file away. Most features always had their switch; the one hold-out was the primed-stone presentation, which now has `stoneNames.primedNaming`. Set it `false` and the mod's prompts and cost lines speak the classic names again ("Evolution Stone", "Adaptation Stone (Fire)") while the Palpedia and status lists go back to tagging entries by the stone a pair charges instead of by what the pair is. Your own explicitly-set stone name strings always win over either preset. One honest limit: the item names you see in the inventory and on the bench come from the mod's data half, which loads before any Lua config runs - those keep the fork's names either way.

## [Unreleased]

## [1.7.0] - 2026-07-26 (community build, with the author's permission)

Upstream sync: everything DooDesch shipped in Palvolve 1.3.9, 1.3.10, 1.3.11 and 1.4.0 now lives in the fork, on top of the fork's own line. All of the below is his work; the credit is his.

### Added

- Evolving into a species unlocks its saddle and Pal Gear recipes in the Technology tree, the same way catching one would (`unlockCatchTech`, on by default) - on every owned path, whether you triggered it with F2, through the radial wheel, or a camp worker grew into its next form while you were away. This was the mod's longest-standing gap: a Helzephyr you evolved into a Helzephyr Lux was yours, but its saddle stayed uncraftable forever, because Palworld ties those recipes to having CAUGHT the species. **The unlock needs a native component that this fork does not install** - upstream ships a compiled `main.dll` alongside its scripts, and wiring a binary into your game is a decision you make deliberately, not something a Lua sync does for you. Without it nothing breaks: the evolution runs exactly as before and the unlock step steps aside, writing one line to the log ("Native companion missing - catch-gated technologies stay locked for this session") the first time it is asked. If you do add upstream's `dlls\main.dll` to the fork's mod folder yourself: the component registers its Lua functions into every UE4SS Lua mod that starts, without filtering on a mod name, so the fork's differently-named folder is not in its way - but the fork's install rule does not carry a `dlls` folder, so re-add it after any mod-loader reinstall, and confirm `[PalvolveNative] lua bindings registered` in `UE4SS.log`. Set `unlockCatchTech = false` if you would rather keep the catch requirement even after adding the component.
- Every condition can be negated with a leading `!`: `"!night"` requires it not to be night, `"!knowsMove:Dragon"` requires knowing no Dragon move. Negated thresholds check strictly below - `"!trustRank:4"` means trust rank 1-3, `"!ivEach:70"` means at least one IV under 70 - which makes opposite branches possible, like a Depresso that becomes Katress at trust rank 4+ and Daedream below it. The radial menu names them the readable way ("Trust rank < 4", "not Daytime"), in all 17 languages. Negation cannot loosen anything: a condition whose game reading fails is still unmet, whichever polarity it carries. Your existing config needs no changes - it is read exactly as before, `!` or no `!`.
- Per-stat IV conditions for custom trees: `ivHP:<n>`, `ivMelee:<n>`, `ivShot:<n>` and `ivDefense:<n>`, each an at-least threshold on that single talent (1-100), sitting alongside the existing `ivTotal` and `ivEach` and named in the radial menu like every other condition.

### Fixed

- The native companion (`dlls/main.dll`) now ships with the fork after all - byte-identical to the one in DooDesch's official workshop 1.4.0 release (SHA256-verified) and added on explicit user approval. Heads-up: the binary appears to register itself under the mod name `Palvolve`, so under the fork's folder the catch-tech unlock may stay a no-op until upstream offers a name-agnostic build - the startup log line ("Native companion missing" or the unlock lines) tells you which world you are in. Everything else is unaffected either way.
- The `inWater` condition now also counts when YOU are swimming, not only the summoned pal. Hovering and flying species like Suzaku float above the surface and never enter the swim state, which made water evolutions (Suzaku into Suzaku Aqua) impossible to trigger. Wild pals are judged on their own body only - a swimmer passing by does not water-evolve a Kelpsea standing on the shore.
- Evolve rejections you reach through the radial wheel, and the confirm press on a pal you cannot afford, arrive as a private system line instead of a chat line that looked like something you typed: on a server the host delivers the reason, and rejects without consuming anything. (Pressing the evolve key on a pal that has no evolution at all, or is under-levelled, still answers locally - that check finds no option to hand the host in the first place.)
- The egg filter leaves the game's special eggs alone. Mutation eggs and the glowing WorldTree eggs hatch what they should; only ordinary evolved-form eggs are turned back into their base. An egg whose item type cannot be read is left untouched rather than guessed at.
- A pair you disabled in a custom tree no longer affects what eggs hatch - the egg filter respects the enabled switch on each pair.
- After a dedicated server restarts and you reconnect without restarting your game, evolution no longer gets stuck on "This server does not run Palvolve". The client used to drop the host's re-greet when it arrived before the reconnect had settled, then time out and disable evolution until a full game restart; it now keeps the greet, so a rejoin re-enables evolution on its own. A kept greet cannot leak across servers: one that did its job is dropped on the spot, and the reconnect copy only lives for a few seconds - so hopping straight from a Palvolve server to a vanilla one cannot inherit either.
- `"!isMale"` and `"!isFemale"` steer the gender-faithful wild filter exactly as the bare forms do. Written the negated way, the filter used to see no gender demand on that branch, so wild spawns of the target kept a random gender and the branch never produced one in the wild.

### Deliberate deviations from upstream

- **The egg filter stays ON by default here.** Upstream turned it off in 1.3.9; in this fork it is a feature you run on purpose, so `eggFilter.enabled` remains `true`. The two egg fixes above apply either way.
- **The fork keeps its own version line.** This is 1.7.0 of the fork, not 1.4.0 - the fork is 20-odd releases past the 1.3.8 it branched from. Host and client still have to match each other, as always.
- **`./dlls` is not in the install rule.** Upstream added it in 1.4.0 so its loader deploys the native component; the fork ships no `dlls` folder, and pointing an install rule at a path that is not in the package is not something to ship untested. Consequence: a `dlls\main.dll` you added by hand is outside the fork's install surface and has to be re-added after a mod-loader reinstall.
- **`inWater` reads only the pal's own body on wild pals.** Upstream has no wild-evolution path, so its new "the player counts too" leg has no owner to read there - the fork's wild sweep hands conditions a nearby player as a stand-in for positional questions (region, base, weather). Letting `inWater` use that stand-in would have water-evolved wild pals on dry land whenever anyone nearby went swimming, so it is skipped on that context.
- **A client's "you cannot afford this" still needs the confirm press before it reaches the host.** Upstream forwards it on the first press. The client's own inventory read fails closed to zero, so a read that breaks only on your machine would have turned a first press into a real, charged evolution on the host. Press one names what is missing locally and arms the confirm as usual; press two carries it to the host for the authoritative answer.
- **Rejections that cannot reach the host are still shown.** Upstream replaces the reason with "waiting for the server check" in that window; the fork logs the pending state and shows the actual reason.

## [1.6.1] - 2026-07-26 (community build, with the author's permission)

### Added

- Your pals tell you when they evolve (`evolveNotify`, on by default): the moment an evolution commits, a line lands in the game's own notice feed - the corner stream that reports catches and level-ups - reading "Cattiva evolved into Naughty Cat! (Lv 19)". It fires for every pal you own and every way one can change: the F2 confirm, the radial pick, auto-evolve, and the camp worker that transformed between hauls while you were three regions away. Wild and primed evolutions stay silent, as they should - those pals are nobody's. On a server the prompt follows the pal's OWNER rather than the machine doing the work: the host relays the sentence over the mod's own channel and your client renders it locally. A private chat line carries the same sentence alongside the notice (`evolveNotify.chatFallback`, on): no mod can see whether the game actually drew the notice, so the chat line is what guarantees you are told - set it to `false` for the notice alone. Turn the whole thing off and an evolution is still written to the log, as before. And when an evolution commits but the pal does not come back (a rare respawn failure), you now get told to resummon it instead of watching it vanish.

### Fixed

- A guest evolving a pal on a listen host used to see absolutely nothing - no prompt, no chat line, no phase signals - and had to open the pal's page to discover it had worked. That path now announces like every other one.
- Base-camp evolution notices come from the message catalog. They were the one player-facing line in the mod still hardcoded inline; they now go through the same lookup as the rest, so a translation only has to land in the catalog. The English text is what ships today - like several newer lines, these keys are not translated yet.

## [1.6.0] - 2026-07-26 (community build, with the author's permission)

### Added

- Base pals evolve too (`autoEvolve.basePals`, on by default, cadence `autoEvolve.baseIntervalSeconds`): a pal assigned to a base camp now auto-evolves when it reaches the level for a free evolution that demands no special conditions - the working Cattiva that hits 19 simply becomes a Naughty Cat between hauls. Condition-gated pairs are deliberately excluded (their moments belong to play), costed pairs never auto-fire, and a withdraw-cancelled evolution stays cancelled even if the pal is then sent to work. Evolved workers get the full treatment - IV bonus, full heal, protection through the swap, a rollback snapshot owned by the pal's owner, and a log/notify line since it happens off-screen. The camp may hand the evolved pal a different job afterwards (its work suitabilities changed, after all). Authority-side; respects the master `autoEvolve.enabled`; a background base evolution always yields to any player's manual evolution or rollback, including connected guests'.

## [1.5.1] - 2026-07-26 (community build, with the author's permission)

### Changed

- The Palpedia Evolutions panel fits the page: labels render at a configurable scale (`palpediaEvolutions.textScale`, default 0.8 - the tab label stays full-size), line spacing follows the scale, and long requirement lines soft-wrap at their natural separators into indented continuation lines (`wrapChars`, default 56; 0 turns wrapping off) instead of running across the screen into the game's own panels.
- The status-page evolution surface now narrates every trigger in `devMode` - groundwork for diagnosing why the Party tab stays blank on current builds.

## [1.5.0] - 2026-07-26 (community build, with the author's permission)

### Added

- Gender-faithful wild spawns (`wildLevelLimit.genderFaithful`, on by default): when every ancestry path to a species demands one gender - and gender persists through evolution here - a wild spawn of that species now rolls in AS that gender, corrected before the Pal ever exists. With a gender-split tree (say Kelpsea Ignis: females become Vanwyrm, males become Moldron), every wild Vanwyrm is female and every wild Moldron male, while species both genders can reach stay mixed. The banner shows how many species your map constrains; a map whose links loop or contradict simply leaves those species unconstrained rather than guessing. The very first correction of a session writes one log line stating whether the engine accepted the write - if your build refuses it, the feature announces itself off instead of pretending.

### Changed

- The stone economy speaks its new role: the plain stone is now the **Unprimed Evolution Stone** (inert on its own - prime it at the Pal Alchemy Workbench with an elemental essence, which was always the recipe), and the elemental stones are **Primed Evolution Stones** - "Primed Evolution Stone (Fire)" and kin - in the bench, the inventory, and every cost prompt. Pair this with a user config that prices evolutions as `stone = "adaptation"` and evolutions charge the primed stone matching their target's element while adaptations run stoneless on conditions alone.
- The Palpedia and status-page evolution lists now label entries by what they ARE (Evolution vs Adaptation), not by which stone they charge - so a costed evolution paying a primed stone no longer masquerades as an "(Adaptation)".

## [1.4.9] - 2026-07-25 (community build, with the author's permission)

### Fixed

- The Pal Alchemy Workbench showed blank recipe tiles after 1.4.7: the fork's item and building icons are registered under the mod's folder name, and the 1.4.7 rename to `Palvolve-Fork` left the item definitions pointing at the old `Palvolve` icon namespace. All 21 icon references now use the new namespace and the bench renders its stones, essences and the extractor normally again.

## [1.4.8] - 2026-07-25 (community build, with the author's permission)

### Fixed

- The periodic stutter during normal play is gone. The auto-evolve and Primed Pals background checks used to sweep the game's entire object list every few seconds - and a second, bigger sweep ran every two seconds during combat, exactly when framerate matters most. Both checks now keep quiet references to what they need (players, the battle state, and a live register of wild Pals that updates itself as they spawn), so the steady-state cost is a handful of validity checks and one boolean. Behaviour is unchanged: the same Pals evolve under the same rules at the same moments - it just no longer costs frames. With `devMode` on, the log now prints per-check timing every minute so the improvement is measurable on your own machine.

## [1.4.7] - 2026-07-25 (community build, with the author's permission)

### Changed

- The fork now installs as its own mod, **`Palvolve-Fork`**, instead of replacing the original's `Palvolve` folder - both script halves carry the new name (`UE4SS\Mods\Palvolve-Fork` and `PalSchema\mods\Palvolve-Fork`), so the Steam Workshop original and this build can be installed side by side and switched in `mods.txt`. Enable exactly one at a time (`Palvolve-Fork : 1` / `Palvolve : 0` or the reverse) - both at once would double every hook. Rollback snapshots (`palvolve_state.lua`) live inside the mod folder and move with it; your `config_user.lua` under `Saved\Palvolve` is shared by both builds, which is intended - the original simply ignores the fork-only settings. No gameplay changes.

## [1.4.6] - 2026-07-24 (community build, with the author's permission)

### Added

- Wild level limit (`wildLevelLimit` in `scripts\config.lua`, on by default): a wild Pal can no longer spawn as a species its level could not legitimately have reached. When the spawn lottery rolls, say, a level 12 Direhowl in a world where Direhowl requires level 30, the spawn is rewritten **before the Pal ever exists** into the chain stage its level does allow - so low-level zones now show you base forms (which Primed Pals can then evolve in front of you), and meeting an evolved form in the wild actually means something about its level. The default `mode = "devolve"` picks the right chain stage; `mode = "levelFloor"` instead keeps the species and raises its level to the minimum the map requires. Evolution requirements always gate; Adaptation requirements gate too unless `includeAdaptations = false`; joke-evolution (funchain) links never do. Alphas are left untouched by default (`exemptAlphas`), owned Pals and hatched eggs are never affected, and the whole thing runs only where the world is simulated (single player, co-op host, dedicated server) - clients just see the result. A custom map whose links form a loop gets a log warning and the affected species are simply left un-gated rather than guessed at.

## [1.4.5] - 2026-07-23 (community build, with the author's permission)

### Fixed

- The Palpedia Evolutions tab now actually responds to clicks. The game's menus consume mouse clicks before they reach the layer the mod was polling, so clicking the tab did nothing and only the toggle key worked; the click is now read at the same raw input level that makes the toggle key work inside menus (with the old polling kept as a fallback). Clicking Stats or Habitat still closes the panel, and the panel no longer reopens on its own when you close and reopen the Palpedia - a fresh Palpedia always starts on Stats, like a real tab.
- A transient failure while looking up a species' evolutions (for example during a world transition) no longer blanks that species' panel for the rest of the session - the panel simply retries.

### Changed

- Each evolution target in the panel is now labelled with what kind of change it is: an **(Evolution)** or an **(element Adaptation)** - so "Fuack Ignis  (Fire Adaptation)" tells you at a glance it wants an Adaptation Stone rather than an Evolution Stone. Element names follow your game language.
- The panel breathes: a blank line between targets, wider default line spacing (`lineHeight` 30), and when a species has more targets than `maxLines` can show, the cut is marked with a visible "..." instead of silently dropping entries.
- The native-look cloned tab is gone for good: the game's own tab widget always renders as an empty shell when cloned from script (its looks are injected by internals that packed assets keep out of reach), so the labelled overlay tab - previously the fallback - is now the only mode, and the code carries no dead clone path.

### Changed

- The Palpedia Evolutions tab is now a real, clickable tab: a clone of the game's own tab widget joins the Stats/Habitat strip (native look, native position). Clicking it opens the evolutions panel, clicking Stats or Habitat closes it, and the toggle key remains the keyboard shortcut. Click detection is geometry-based (widget rectangles + mouse state), so no game widget events are touched; if a game patch ever breaks the tab cloning, a labelled fallback keeps the feature working.

## [1.4.3] - 2026-07-23 (community build, with the author's permission)

### Changed

- The Palpedia evolution info is now an **Evolutions pseudo-tab**: a tab-style label sits beside Stats/Habitat and the toggle key (default `V`, shown on the label, configurable) opens the panel - target name on one line, requirements indented beneath, in the free area under the Pal model. The panel hides on the Habitat tab, when toggled off, and whenever the Palpedia closes. (A literal third button inside the game's own tab strip is not reachable from script - its widget internals live in packed assets - so the key-toggled equivalent is the robust version of the same idea.)
- The panel renders as a screen-space overlay instead of attaching into the Palpedia's widget tree (which has no reachable canvas - the cause of 1.4.2's invisible block), and the selection watch now reuses captured references instead of scanning the object array every tick, fixing a stutter the 1.4.2 diagnostics build introduced.

## [1.4.2] - 2026-07-23 (community build, with the author's permission)

### Changed

- Evolution info moved to the Palpedia (`palpediaEvolutions` in `scripts\config.lua`, on by default): every species entry now lists what it evolves into and what each target needs - level, conditions, and costs priced at the pair's minimum level (the Palpedia shows species, not individuals). The block renders over the detail card and refreshes as you browse entries; position is adjustable, and it fails closed like every UI feature here.
- The per-pal status-page block from 1.4.1 (`statusEvolutions`) is superseded and now OFF by default - flip it back on if you want both surfaces.

## [1.4.1] - 2026-07-23 (community build, with the author's permission)

### Added

- Evolutions on the status page (`statusEvolutions` in `scripts\config.lua`, on by default): a Pal's detail screen now lists what it can evolve into and what each target needs - level, conditions, and the stone/materials priced at its current level. Either/or branches collapse into one line, exactly like the radial menu. The block is purely cosmetic and fails closed: if a game update rearranges the page, it disappears rather than breaking anything, and its position is adjustable (`x`/`y`) since the page layout lives inside the game's packed assets.
- Withdraw to cancel (`withdrawCancels`, on by default): recalling your Pal while the transformation is still dissolving now cancels the evolution - any stone or materials already taken are refunded in full, and auto-evolve leaves that Pal alone until its next level-up (manual F2/radial evolution stays available immediately). Previously a mid-dissolve recall was misread as the sequence's own teardown and the evolution went through anyway. Single player and co-op host; on a dedicated server the swap commits before a recall could land.
- Per-pair free evolutions (`free = true` on any pair in the map or your `config_user.lua`): mark individual evolutions as costing nothing - no stone, no materials - while the rest of the tree keeps its price. Free pairs are exactly the ones auto-evolve triggers on its own; costed pairs always keep the prompt. This makes mixed trees possible: `{ from = "Penguin", to = "CaptainPenguin", minLevel = 20, free = true }` evolves on level alone, while a stone-gated pair next to it still asks for its Evolution Stone. (The global `requireStone = false` free mode still exists and now reads as "every pair is free".)

### Notes

- The status-page block's header is English-only for now ("Evolves into:"); Pal names, conditions and requirements follow your game language as usual.

## [1.4.0] - 2026-07-23 (community build, with the author's permission)

### Added

- Primed Pals (`primedPals` in `scripts\config.lua`, on by default): a wild Pal whose level already satisfies one of its species' evolutions has a chance (10% by default) to be primed to evolve - when a fight pushes its HP below the threshold (35%), it evolves right in front of you. Whether a given Pal is primed is decided deterministically from its identity, so the same individual is a Primed Pal in every session without any saved state. Pairs with environment conditions take part wherever the Pal itself satisfies them (a Mau only becomes Sekhmet in the desert by day), and `environmentChance` lets specific environments use their own encounter chance (say, caves at 25%). Evolving wild Pals get the full player treatment - IV bonus, full heal, protection through the reveal - and keep level, gender, Lucky and Alpha status; evolutions cost wild Pals nothing.
- The catch decision: through the short telegraph before the transformation (about 2 seconds of flash and freeze) the Pal keeps its low HP and stays fully catchable - sphere it then, at low-HP catch odds, and the capture wins: the evolution cancels and you keep the UN-evolved form. Let it finish and you face a full-HP evolved Pal instead - better prize, harder fight, worse sphere odds. A capture that lands anywhere mid-sequence cancels the evolution the same way; the transformation never overrides a catch.
- The scanner behind this runs only while a player is actually in combat (out of combat it costs a single boolean check), only on the world authority (host or server; clients simply see the result), examines only nearby Pals with a per-tick cap, and eases off on an empty server.

### Notes

- Primed Pal evolutions are not snapshotted for `/palvolve rollback` (they are not the player's to roll back); an evolved Primed Pal you then catch behaves exactly like any caught Pal.
- The wild respawn path uses the character manager's own handle respawn (`SpawnCharacterByHandle`), verified against the game's SDK headers and the shipping build's symbol table - but not yet play-tested in-game; if it misbehaves, set `primedPals.enabled = false` in `scripts\config.lua`.

## [1.3.9] - 2026-07-23 (community build, with the author's permission)

### Added

- Auto-evolve (`autoEvolve` in `scripts\config.lua`, on by default): a summoned Pal now evolves on its own - no radial prompt, no F2 confirm - the moment every gate passes (level, conditions, alpha form) and the evolution is completely free: no stone and no materials. Costed evolutions never fire on their own and keep the usual prompt flows, so with the default `requireStone = true` nothing changes until evolutions are made free (`requireStone = false`, or a free custom tree). When several free targets are eligible at once the first in map order wins; pick manually through the radial menu before the poller fires (checks every 5 seconds by default) if you want a different branch - auto-evolve always yields for a few seconds after any manual F2 press or radial pick, and while an F2 confirm is armed. Works in single player, co-op and on dedicated servers: each client checks its own Pal and asks the host, and the request is flagged free-only, so a host whose cost config differs rejects it instead of silently charging stones. Failed or rejected attempts back off exponentially. All keys of both new sections can be overridden from `config_user.lua`.
- Transformation protection (`evolveProtection` in `scripts\config.lua`, on by default): an evolving Pal can no longer die mid-transformation. The staging always froze the Pal but left it damageable, and no stage checked for death - in combat, a kill during the dissolve read as a successful despawn, and the freshly revealed form could be shot down during the grow. The Pal (old body, the actor-less gap, and the new body alike) is now undamageable for the whole window, from the very first frame, and its HP is re-topped throughout. On every path where the world still exists the window closes cleanly; an evolution that actually happened additionally ends with a final full heal (aborted attempts skip that heal, so aborting is never a free heal on top of the refund).

### Notes

- Evolving mid-combat was never blocked by the mod (the `inCombat` condition even requires it for some custom pairs) - it was just lethal to attempt. With the protection window it is now safe: hold 4 and pick Evolve, press F2 twice, or let auto-evolve trigger a free evolution the moment its conditions hold, fight raging or not.
- Mixed versions: joining a stock 1.3.8 server with this build shows the usual version-mismatch notice (harmless - the wire protocol is unchanged), and auto-evolve requests are simply ignored by a 1.3.8 host. Manual evolution works as before.

## [1.3.8] - 2026-07-22

### Fixed

- On a busy dedicated server the host's join greet can arrive a few seconds after you enter the world. When that happened the client gave up too early, showed "This server does not run Palvolve" and disabled evolution for a moment - even though the server ran Palvolve and evolution still worked. The wait before that verdict is now longer, and reaching it no longer pops the warning on its own. The message shows only if you reach for evolution before the server has answered, and a late greet re-enables everything quietly.

## [1.3.7] - 2026-07-21

### Added

- Four new evolution conditions for custom trees: `playerLevel:<n>` (your trainer level), `trustRank:<n>` (the pal's trust rank, 1-10), `ivTotal:<n>` (the four IVs combined) and `ivEach:<n>` (every single IV). All are at-least thresholds, work in hand-written configs and in the web configurator, and show their requirement in the radial menu like every other condition.
- Palvolve now writes its version to the UE4SS log at startup, next to the existing loaded marker, on both the server and the client. This makes support logs identify the running build at a glance, which matters most on servers where the version was previously not visible anywhere in the log.

### Fixed

- Closing the radial menu with ESC committed the hovered entry anyway - only the radial key itself counted as a cancel gesture. ESC now cancels cleanly and nothing triggers.
- On dedicated servers, replies to `/palvolve` chat commands showed up twice: once as the private system line from the server and once as a line attributed to the player, produced by their own client. The client half now only writes to the log; the server's system line is the single visible reply.

## [1.3.6] - 2026-07-20

### Fixed

- The Save Cleaner set `LocalData.sav` aside and cost players their revealed map - the file carries the map fog, and the rebuilt one starts black. The stale mod reference inside it turned out to be harmless (isolation-tested), so the cleaner no longer touches the file at all. If an earlier cleaner run took your map, run the new cleaner once on the world: it restores the set-aside file and brings the map back, keeping the rebuilt one next to it. Reported on Nexus within hours - thank you.

### Changed

- The cleaner's write routine now refuses to run unless the automatic full world backup exists, as a hard guarantee instead of a convention. The backup was always created first; now nothing can write without it.

## [1.3.5] - 2026-07-20

### Fixed

- The uninstall assistant spoke English regardless of your game language. Everything it says in chat - the findings, the workbench locations, the clean verdict, the keep-the-data-folder reminder - now uses the same seventeen languages as the rest of the mod, as do the rollback messages and the help line. Log lines for support stay English.

## [1.3.4] - 2026-07-20

### Added

- A guided uninstall: run `/palvolve uninstall` in chat (single player or host) while the mod is still installed. It deletes every Palvolve item from your inventory for real, removes the technology unlock from your save, scans every container in the world - chests, pals, other players - and names the exact spot of every remaining stack, and lists placed workbenches. Run it until it reports the world clean. Background: the game keeps references to mod items in places nobody can reach by hand, discarding an item only drops it for base pals to haul into chests, and a destroyed chest can leave its contents alive inside the save. Reported by MADMIKEYMAN and Joryuu, whose chest find led straight to the deepest of these cases.
- The Save Cleaner, a small offline tool (in `save-cleaner/`, also attached to the GitHub release): with the game closed it removes every Palvolve trace from a world's save files - remaining item stacks become plain Stone, placed workbenches and their work assignments go away, and the crafting statistics inside each player file lose their mod entries. After it runs, the world loads on a machine with no Palvolve at all - including a save the cloud synced to a PC that never had the mod, and a world that already refuses to load.
- When you join a server that runs Palvolve with the same version as your client, the chat now also shows your own client version right under the server's line, so a match is visible at a glance. A version difference keeps showing the existing warning.

### Fixed

- On rented game servers Palvolve could fail to notice it was running on a dedicated server, and started the parts of the mod that only belong on a player's machine. Those parts then kept searching for menus that never exist on a server, which wears on the server the longer it runs. The mod recognized a server by the name of the folder it was installed in, but a host may name that folder anything it likes - GPortal names it exactly like a player's installation. Palvolve now looks for the dedicated server's own program file, which no game client ever has.
- Messages meant for a single player - evolution confirmations, costs, rejections - appeared in the global chat attributed to that player, readable by everyone on the server. They now arrive as a private system line only the addressed player sees.

### Known issues

- A running game cannot clean its own crafting statistics, so `/palvolve uninstall` alone does not make a world independent of the mod. Two supported ways close the gap: keep the small `PalSchema\mods\Palvolve` data folder installed (it defines the items so the save stays readable, and does nothing else - remember it again after a game reinstall, since Steam syncs saves but not mods), or run the offline Save Cleaner once and the world needs nothing at all. The README has both procedures; a world that no longer loads recovers with either.

## [1.3.3] - 2026-07-20

### Added

- Palvolve now checks whether the server you join runs it. On a server without Palvolve the mod tells you once and disables evolution for that session, instead of letting you unlock the technology and craft stones that the server then discards. On a server that does run Palvolve you get a chat line naming the version it runs, plus a warning if that version differs from your own. Single player and hosted games are unaffected and never show a message. Reported by Learoyjenkins.

### Fixed

- The game could crash when leaving for the title screen, or disconnecting from a server, while a transformation was still playing. The recall scheduled for the end of the dissolve kept running after the world was already gone and reached for characters the game had freed in the meantime. Every stage of the transformation now confirms the world is still there before it touches anything, and an interrupted transformation ends where it stood.
- The Evolve entry could be missing from the hold-4 wheel for a whole session, and only came back after a restart. The wheel's interface classes load late in some sessions, and registration used to give up after a fixed number of attempts. It now waits for those classes to appear.
- A retry loop that installs the egg filter never noticed it had succeeded and kept running for the entire session, on servers as well. It now stops once the filter is in place.

### Changed

- License changed from MIT to GPL-3.0. Derived mods must be released under the GPL-3.0 as well, with source available and credit kept. Releases up to v1.3.2 remain MIT.

### Known issues

- Work suitability keeps the values of the form a Pal evolved from until you reload. The base suitability shown in the team and Palbox screens is built once when a Pal is loaded and is not rebuilt when its species changes, and it cannot be rebuilt from a mod while the world is running. Job skill book bonuses are unaffected. Relogging shows the correct values, and Pals evolved in earlier sessions are already correct. Reported by mat pet telo tiga.

## [1.3.2] - 2026-07-19

### Fixed

- Eggs that would hatch an evolved form hatched nothing at all - the egg was consumed and no Pal appeared. The filter rewrote only the model's replicated hatch copy, not the egg's own stored save parameter that the game builds the hatched Pal from, so the mismatched hatch produced an empty result. The egg's stored species is now normalized server-side at hatch-complete, before the Pal is built, so a base form hatches as intended. Reported by Catch 34.
- The "X was born" message named the evolved form while a different base-form Pal was received. That message reads the replicated hatch parameter, which is now written to the same base form as the Pal, so the notification and the hatched Pal always match (previously mismatched on dedicated servers, where the two replicate separately).

### Changed

- Eggs follow evolution chains only. An egg of an evolved form hatches a base form; a pure element adaptation (the same Pal in a different element) hatches unchanged. Where the chain runs through an element-adapted form, or a base carries element variants, the egg hatches one of the whole base family - the plain base or any of its element variants - and where several lineages or variants qualify, one is chosen with equal chance.

## [1.3.1] - 2026-07-18

### Fixed

- Fix attempt for installs that lost the Pal Alchemy Workbench, the level 10 technology entry and every stone. Affected logs point to a load-order problem in the modding frameworks: when the game boots faster than UE4SS finishes initializing, the session's first text conversion fails and stays failed (a one-time lookup cache in the UE4SS library), and PalSchema then drops the whole schema half of the mod. This could not be reproduced locally, so it is the best-supported theory from the reports rather than a proven diagnosis. Item and building names now live in the translation files alone, so those loaders run without the fragile conversion; unaffected setups behave exactly as before (verified).
- On sessions with that broken text conversion the Evolve entry in the hold-4 wheel showed Japanese template text. The label now falls back to the engine's own text converter.

## [1.3.0] - 2026-07-18

### Changed

- The transformation finale is rebuilt around the target form's elements. A light beam wraps the growing Pal while element bursts climb around it; the moment it snaps to full size, its primary element fires a centerpiece - a flame explosion, a lightning strike, a water geyser, ice blades or a dark pillar wrapped in a darkness shroud - while the second element rings the body. Dual types alternate both elements through the accents, adaptations reveal in the element they change into, and every effect scales with the size of the target species.
- Transformations now sit exactly on the ground. Placement follows the engine's own collision capsule and floor measurements instead of species table values, which used to sink large evolutions into the floor, float effects far above small ones and let the growing Pal jitter against gravity.
- On dedicated servers the full transformation cinematic plays for the evolving player, correct heights included. Bystanders see the regular recall and resummon.
- No effect ever plays above the new form's head, and the finale goes quiet right before the Pal lands facing you.

### Fixed

- Aborted transformations no longer leave effect systems running or the Pal hovering at the wrong height.
- If a game update removes one of the effect assets, the finale falls back to simpler bursts for that element instead of failing.

## [1.2.1] - 2026-07-17

### Fixed

- Steam Workshop installs were missing the entire PalSchema half of the mod (Pal Alchemy Workbench, stones, technology entry): the official mod loader copies the contents of the PalSchema install target into `PalSchema\mods\Palvolve\`, and the package carried an extra inner folder, so everything landed one level too deep and PalSchema loaded nothing. The Workshop package now ships the schema content directly under its install target. Manual installs from the GitHub zip were never affected.
- Info.json `MinRevision` now follows the official revision convention (trailing digits of the title-screen version, currently 619) instead of the Steam buildid, which the loader could reject as an impossible requirement.

## [1.2.0] - 2026-07-17

### Changed

- New default tree, curated with the community (DooDesch + Patman): 143 transformations, up from 99. Every v1.1.0 pair is kept; 45 pairs join, including full crossover families (Kelpsea to Jormuntide/Suzaku Aqua, Ribbuny to Petallia, Hoocrates to Shadowbeak, Depresso to Nyafia).
- The default tree now uses conditions: Mau becomes Sekhmet only in the desert by day and Wispaw only at night or in caves; Pengullet Lux branches into Penking Lux or - while electrified or in a wildlife sanctuary - Dynamoff; Kelpsea reaches Suzaku Aqua in water and Jormuntide while electrified or knowing a Dragon move; Relaxaurus turns Lux only while electrified (just like the Paldeck tells it); Suzaku needs water for Aqua; a Swee is only promoted to Sweepa with a Sweepa in the party.
- Balance pass on the new pairs: Petallia routes 21 -> 30, Lyleen 28 -> 40, Shadowbeak 44 -> 48, Cryolinx 28 -> 36, Grizzbolt 35 -> 38, Kelpsea crossovers 33 -> 38; Teafant -> Mammorest Cryst is labeled the fun chain it is (level 40).

### Compatibility

- Existing config_user.lua files and share links keep working unchanged - a user config fully replaces the default tree, and material costs stay opt-in.

## [1.1.0] - 2026-07-17

### Added

- Multiplayer and dedicated server support: a connected client can evolve on a dedicated server. The server validates ownership, level and cost, performs the species swap authoritatively and consumes the stones from the requesting player, and the client plays back the transformation. Singleplayer and co-op host keep the identical in-process path. Info.json ships separate server-side install rules (`IsServer`), so dedicated servers using the official Workshop flow install the mod as well.
- Conditional evolutions: every pair can carry `conditions = { ... }` (AND semantics) that must hold at evolve time - day/night, in water, status effects (burning, electrified, frozen, wet, poisoned, stunned, sleeping, muddy, blinded, toxic gas), locations (cave, desert, volcano, snow, grassland, forest, sakura, dark island, sky islands, mushroom island, World Tree, oil rig, wildlife sanctuary), gender, gliding, own base, in combat, plus parameterized `knowsMove:<Element>` and `inParty:<CharacterID>`. Either/or branches (X/Y evolutions) are two pairs with the same target and different conditions; the radial menu merges them into one entry that unlocks when any variant holds.
- Configurator support: conditions are editable per pair (with a duplicate button for either/or branches), travel through share links (payload v2; old v1 links keep working) and the exported `config_user.lua`.
- Blocked radial options now name the missing conditions ("Dynamoff needs: Electrified or In a wildlife sanctuary"); the level-up hint names conditions as "(when: ...)".
- Chat command `/palvolve rollback`: typed into the normal in-game chat, it restores your last evolved Pal to its previous form (IVs included) from the automatic pre-evolution snapshot. Works in singleplayer, co-op and on dedicated servers, scoped to the requesting player.
- All chat messages, blocked reasons and menu entries follow the game language (17 languages), including localized Pal names; on dedicated servers each client gets messages in its own language.

### Compatibility

- Older mod versions ignore the `conditions` field entirely (those pairs behave as unconditional); unknown condition ids from newer configs are dropped at load with a log line.
- Config schema version 4 (mod) / emitted `config_user.lua` schema 2 (web).

### Known issues

- Dedicated servers: the final reveal effects (target element bursts + evolution flash) do not render on the client yet; the evolution itself completes correctly and preserves the Pal's identity.

## [1.0.0] - 2026-07-15

### Added

- Evolution chains, fun chains and 87 element adaptations, curated and config-driven, with per-pair level thresholds.
- Radial menu integration: an "Evolve" entry in the hold-4 wheel opens a submenu with every available option plus cancel; unavailable entries are greyed out and entries follow the game language.
- Staged transformation sequence: spin-up, shrink into light, growth reveal, with the game's element effects (old element while dissolving, target element at the reveal; dual-element Pals alternate).
- Alpha and Lucky preservation: Alphas evolve into the Alpha form of the target species, Luckys stay Lucky.
- Stone-based cost system: Evolution Stones and per-element Adaptation Stones, fully transactional with refunds on abort; optional drop-based material costs on top.
- Pal Alchemy Workbench: an own buildable crafting bench (technology level 10) for element essences (skill fruits 1:1 or 10x elemental parts) and for forging Evolution and Adaptation Stones, with a recipe list ordered stone > adaptation stones > essences.
- Egg filter: eggs hatch base forms only (on by default, configurable).
- Identity preservation across transformations: level, nickname, gender, passives, IVs, souls, condenser rank and learned moves; +5 to all IV talents per stage.
- Snapshots before every transformation with automatic cost refunds on abort.
- Configuration overlay: the [Palvolve Configurator](https://palvolve.doodesch.de) exports a `config_user.lua` that loads from `%LocalAppData%\Pal\Saved\Palvolve\` (or next to `config.lua`) and survives mod updates.
- F2 keyboard fallback for check and confirm without the radial menu.
