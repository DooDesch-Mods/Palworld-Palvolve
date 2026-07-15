# Changelog

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
