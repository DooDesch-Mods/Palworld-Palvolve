# Changelog

## [Unreleased]

### Fixed

- Evolve rejection notices (missing materials, level or conditions) now arrive as a private system line instead of a chat line attributed to you. On a server the host delivers the reason, so it reads as a system message rather than something you appeared to type in chat.
- After a dedicated server restarts and you reconnect without restarting your game, evolution no longer gets stuck showing "This server does not run Palvolve". The client used to drop the host's re-greet if it arrived before the reconnect finished settling, then time out and disable evolution until a full game restart. It now keeps that greet, so a rejoin re-enables evolution on its own.

### Known issues

- A Pal you only evolved into, never caught, does not unlock its saddle or Pal Gear recipe in the Technology tree. Catch that species once to unlock it.

## [1.3.9] - 2026-07-23

### Added

- Per-stat IV conditions for custom trees: `ivHP:<n>`, `ivMelee:<n>`, `ivShot:<n>` and `ivDefense:<n>`, each an at-least threshold on that single talent (1-100). They sit next to the existing `ivTotal` and `ivEach`, work in hand-written configs and in the web configurator, and name their requirement in the radial menu like every other condition.

### Changed

- The egg filter is now off by default. Eggs hatch the species they normally would; enable the filter in the config or the configurator if you want eggs to only ever hatch base forms. A new guide, `EGG-FILTER.md`, explains what it does with diagrams and a worked example.

### Fixed

- With the egg filter on, the game's special eggs are now left alone. Mutation eggs and the glowing WorldTree eggs hatch what they should; only ordinary evolved-form eggs are turned back into their base. Thanks to the players who flagged the breeding side effect.
- A pair you disabled in a custom tree no longer affects what eggs hatch. The egg filter now respects the enabled switch on each pair.

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
