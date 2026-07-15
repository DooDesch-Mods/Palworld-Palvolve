# Palvolve

Evolve your captured Pals into stronger related forms and adapt them into their element variants - Pengullet becomes Penking, Penking becomes Penking Lux. Your Pal keeps its full identity: level, nickname, gender, passive skills, IVs, souls, condenser rank and even its learned moves.

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de](https://support.doodesch.de).

## Features

- **99 curated transformations:** evolution chains (e.g. Pengullet -> Penking, Mau -> Sekhmet), fun chains and 87 element adaptations (e.g. Penking -> Penking Lux), all config-driven with per-pair level thresholds.
- **Radial menu integration:** hold 4, pick "Evolve" and choose from your Pal's options in a submenu - unaffordable options are greyed out with the reason, backing out is always one click away. Entries follow the game language.
- **A transformation worth watching:** your Pal spins up, shrinks into a blinding light and re-emerges growing from a spark to full size, with the game's own element effects - the old element while it dissolves, the new one when it reveals. Dual-element Pals pulse in both.
- **Alphas and Luckys stay special:** an Alpha evolves into the Alpha form of its target species, a Lucky stays Lucky - the status survives every transformation.
- **Stones as the price of power:** every transformation costs its stone - Evolution Stones forged from Paldium Fragments, Meteor Fragments and Pal Fluids, element Adaptation Stones attuned with the matching essence. Optional drop-based material costs can be enabled on top.
- **The Pal Alchemy Workbench:** an own buildable bench (technology level 10) that breaks skill fruits down 1:1 into element essences (or 10x matching drops like Flame Organs, Wool or Horns), forges Evolution Stones and attunes them into element Adaptation Stones.
- **Egg filter:** eggs only hatch base forms, so evolved forms stay something you earn (on by default, configurable).
- **Web configurator:** explore every transformation as an interactive graph at [palvolve.doodesch.de](https://palvolve.doodesch.de), toggle categories or build your own tree, and download a ready-to-use config.
- **Identity preserved, and then some:** everything individual carries over, including moves the target species could never learn - builds vanilla cannot have. +5 to all IV talents per stage (capped at 100).
- **Transactional and safe:** every evolution snapshots the Pal first and refunds all costs if anything aborts before the transformation completes.
- Keyboard fallback: F2 checks and confirms the summoned Pal's next evolution without the radial menu.

## Installation

### Steam Workshop (recommended)

Subscribe, then enable the mod in-game under Options > Mod Management. UE4SS is installed automatically as a Workshop dependency; PalSchema is required as well.

### Manual (UE4SS + PalSchema)

1. Install [UE4SS for Palworld](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587) and [PalSchema](https://pwmodding.wiki/).
2. Copy `Mods\Palvolve` (with `scripts\main.lua`) into `<Palworld>\Pal\Binaries\Win64\ue4ss\Mods\`.
3. Copy `Mods\PalSchema\mods\Palvolve` into `<Palworld>\Pal\Binaries\Win64\ue4ss\Mods\PalSchema\mods\`.
4. Add the line `Palvolve : 1` to `ue4ss\Mods\mods.txt` (above the Keybinds entry).

## Compatibility

- Palworld 1.0 (buildid 24088745).
- Singleplayer and co-op host. Dedicated servers are not supported yet (UE4SS does not run there); server support is on the roadmap.
- Requires UE4SS (Palworld build) and PalSchema.

## Before you uninstall

**Demolish every placed Pal Alchemy Workbench before removing the mod.** Worlds containing placed modded buildings will not load once the mod is gone (a known game-side limitation). Modded items left in inventories are cleaned up automatically by PalSchema.

## Configuration

The easy way: open the **[Palvolve Configurator](https://palvolve.doodesch.de)**, explore every transformation in an interactive graph, toggle whole categories or build your own tree, then drop the downloaded `config_user.lua` into `%LocalAppData%\Pal\Saved\Palvolve\` (create the folder if it does not exist - the mod also creates it on its first launch). The file survives mod updates and works for Workshop installs; placing it next to `scripts\config.lua` works as well.

For hand-tuning, everything lives in `scripts\config.lua`: individual pairs, level thresholds, cost scaling, the egg filter and the transformation timings.

## License

MIT - see [LICENSE](LICENSE).
