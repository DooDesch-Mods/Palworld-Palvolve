# Palvolve

> Turn a captured Pal into a related form, on your terms, and keep every stat, IV and move it already learned - the evolutions Palworld never shipped.

[![Steam Workshop](https://img.shields.io/badge/Steam_Workshop-Subscribe-1b2838?logo=steam&logoColor=white)](https://steamcommunity.com/sharedfiles/filedetails/?id=3766366950)
[![Nexus Mods](https://img.shields.io/badge/Nexus_Mods-Download-da8e35?logo=nexusmods&logoColor=white)](https://www.nexusmods.com/palworld/mods/3976)
[![Configurator](https://img.shields.io/badge/Configurator-palvolve.doodesch.de-06b6d4)](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve)
[![GitHub Release](https://img.shields.io/github/v/release/DooDesch-Mods/Palworld-Palvolve?logo=github&label=Release)](https://github.com/DooDesch-Mods/Palworld-Palvolve/releases)

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

## Features

- **143 curated transformations** as the starting point: evolution chains like Pengullet to Penking, fun chains like Sweepa to Snugloo, and 87 element adaptations.
- **Evolve when you want to:** hold 4, pick Evolve, and your Pal transforms in front of you with a finale built from its target elements. F2 checks and confirms the summoned Pal without the menu.
- **Keeps identity and progress:** every learned move carries over, even ones the new form could never learn on its own, and level, nickname, gender, passives, IVs, souls and condenser rank all stay. Alphas evolve into Alpha forms, Luckys stay Lucky.
- **Conditional evolutions:** a pair can require day or night, water, a status effect, a location, a party member, a known move element, or a trainer-level, trust-rank or IV threshold. Greyed options name exactly what is still missing, in your game language.
- **Web configurator:** build your own evolution tree at [palvolve.doodesch.de](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve) - rewire pairs, set levels and conditions, share it as a short link, and download the config. 17 languages.
- **Reversible by design:** every evolution is snapshotted first, `/palvolve rollback` restores the previous form, and an aborted transformation refunds what it used.
- **Earned, not free:** evolutions cost stones from the buildable Pal Alchemy Workbench, and eggs keep hatching base forms (configurable).

## Requirements

- **UE4SS Experimental (Palworld)** - the Palworld-specific build, not the generic upstream RE-UE4SS (that one breaks on Palworld 1.0: Steam-ID mismatch, mods silently stop loading).
- **PalSchema** - provides the Pal Alchemy Workbench, the stones and the recipes.

## Installation

### Steam Workshop (recommended)

Subscribe to [Palvolve](https://steamcommunity.com/sharedfiles/filedetails/?id=3766366950) and enable it in-game under **Options > Mod Management**. UE4SS Experimental (Palworld) and [PalSchema](https://steamcommunity.com/sharedfiles/filedetails/?id=3625280368) are pulled in automatically as Workshop dependencies.

### Manual

> ⚠️ Use **UE4SS Experimental (Palworld)** ([Workshop 3625223587](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587)), not the generic upstream RE-UE4SS - it breaks on Palworld 1.0 (Steam-ID mismatch, mods silently stop loading).

Grab the release zip from [Nexus Mods](https://www.nexusmods.com/palworld/mods/3976) or the [GitHub releases](https://github.com/DooDesch-Mods/Palworld-Palvolve/releases), then:

1. Install UE4SS Experimental (Palworld) and PalSchema following the [PalSchema installation guide](https://okaetsu.github.io/PalSchema/docs/installation).
2. Copy `Mods\Palvolve` into `<Palworld>\Pal\Binaries\Win64\ue4ss\Mods\`.
3. Copy `Mods\PalSchema\mods\Palvolve` into `<Palworld>\Pal\Binaries\Win64\ue4ss\Mods\PalSchema\mods\`.
4. Add `Palvolve : 1` to `ue4ss\Mods\mods.txt` (above the Keybinds entry).

Never mix a Workshop UE4SS and a manual UE4SS in the same install - that double-loads UE4SS and crashes the game.

### Dedicated servers

The server validates the technology unlock. If the mod is not running on the server, the workbench relocks every time you reopen the technology tree.

1. Install **UE4SS Experimental (Palworld)** on the server (proxy dll next to the server binary).
2. Install **PalSchema** on the server ([installation guide](https://okaetsu.github.io/PalSchema/docs/installation)).
3. Install Palvolve from the [GitHub release zip](https://github.com/DooDesch-Mods/Palworld-Palvolve/releases): both folders inside the zip go into `Pal\Binaries\Win64\ue4ss\Mods\`. Do not copy the Workshop item folder - its layout is for the game's own loader.
4. Add `Palvolve : 1` to `ue4ss\Mods\mods.txt` and restart the server.
5. Check the server's `UE4SS.log` for the line: `[PalSchema] Added building 'Palvolve_ElementExtractor'`
6. ???
7. Profit.

Every player also needs Palvolve, PalSchema and UE4SS active on their own client. The normal Workshop install does that automatically.

## Multiplayer

Single player, co-op and dedicated servers all work. A few rules:

- Install UE4SS, PalSchema and Palvolve on the host or server **and** on every client. A client-only install does not work.
- The host or server validates ownership, level, costs and conditions before anything changes.
- On a dedicated server, only the evolving player sees the full cinematic. Everyone else sees the normal recall and resummon.

## Configuration

Build your tree in the [web configurator](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve) and drop the exported `config_user.lua` into `%LocalAppData%\Pal\Saved\Palvolve\` (created on first launch). It replaces the default tree and survives mod updates.

Hand-written configs use `conditions = { "night", "knowsMove:Dragon", "inParty:Penguin", "playerLevel:25" }`: all conditions must hold at once, and either/or branches are two pairs with the same target. Numeric thresholds are at-least checks:

- `playerLevel:<n>` - trainer level, 1-80
- `trustRank:<n>` - trust rank, 1-10
- `ivTotal:<n>` - sum of the four IVs, 1-400
- `ivEach:<n>` - every IV, 1-100
- `ivHP:<n>` / `ivMelee:<n>` / `ivShot:<n>` / `ivDefense:<n>` - one specific IV, 1-100

Everything else (pairs, levels, costs, egg filter, timings) lives in `scripts\config.lua`.

## Uninstalling

Run `/palvolve uninstall` in chat (single player or host) while the mod is still installed, then keep the small `PalSchema\mods\Palvolve` data folder, or run the [Save Cleaner](save-cleaner/README.md) for a world that needs nothing at all.

**Full guide, including recovery for a world that no longer loads: [UNINSTALL.md](UNINSTALL.md).**

## Known Issues

- Work suitability shows the pre-evolution form until you relog. Job skill book bonuses are not affected.
- Removing the mod needs the cleanup step above first, or the world can fail to load.

## FAQ

**No "Evolve" option in the hold-4 menu, even though the workbench and stones work?**
UE4SS is not loading Palvolve. The workbench is PalSchema, the Evolve button is UE4SS. Check that UE4SS Experimental (Palworld) is installed and Palvolve is enabled; relaunch if it vanishes mid-session.

**The workbench will not unlock at level 10, or will not stay learned?**
Same cause: UE4SS or PalSchema is not active. The tell is no UE4SS output in the log.

**Co-op and dedicated servers - where do I install it?**
On the server **and** every client. UE4SS, PalSchema and Palvolve have to be active on both sides; a client-only install does not work.

**How do I uninstall it safely? My world crashes after I remove the mod.**
Run `/palvolve uninstall` first, then keep the `PalSchema\mods\Palvolve` data folder or run the Save Cleaner. Back up your saves first. Full steps: [UNINSTALL.md](UNINSTALL.md).

**Breeding changed, or an evolved variant will not hatch?**
Eggs hatch base forms on purpose. Turn the egg filter off in `scripts\config.lua` if you want otherwise.

**Evolution vs. adaptation?**
Evolution turns a Pal into a different Pal (Pengullet to Penking). Adaptation changes its element (Pengullet to Pengullet Lux).

**How do I evolve a Pal?**
Build the Pal Alchemy Workbench (level 10), forge an Evolution Stone from skill-fruit essences, then hold 4 and pick Evolve. `/palvolve rollback` undoes it.

**Compatible with other mods?**
Known conflicts: Dynamic Pals and PalMagic. Keep every mod updated, and send your mod list if an option stays greyed out.

**Custom trees and languages?**
Yes. Build and share trees in the [web configurator](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve). The mod and configurator run in 17 languages.

## Support

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

When you report something, include your Palvolve version, your Palworld version and the full `UE4SS.log`. Palvolve writes its version into that log at startup, so it is usually all I need to place the problem.

## Notes

- Tested with Palworld 1.0 build 619 - singleplayer, co-op and dedicated servers.
- Never use mods on official servers.

## License

GPL-3.0 - see [LICENSE](LICENSE). Copyright (C) 2026 DooDesch.

You may use and modify this code, including in your own mods - but derived work must be released under the GPL-3.0 as well, with source available and credit kept. Versions up to v1.3.2 were published under MIT and remain so.
