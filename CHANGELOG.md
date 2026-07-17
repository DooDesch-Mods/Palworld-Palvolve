# Changelog

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
