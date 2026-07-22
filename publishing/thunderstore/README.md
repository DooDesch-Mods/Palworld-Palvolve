# Palvolve

> Turn a captured Pal into a related form, on your terms, and keep every stat, IV and move it already learned - the evolutions Palworld never shipped.

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

## Features

- **143 curated transformations** as the starting point: evolution chains like Pengullet to Penking, fun chains like Sweepa to Snugloo, and 87 element adaptations.
- **Evolve when you want to:** hold 4, pick Evolve, and your Pal transforms in front of you with a finale built from its target elements. F2 checks and confirms the summoned Pal without the menu.
- **Keeps identity and progress:** every learned move carries over, even ones the new form could never learn on its own, and level, nickname, gender, passives, IVs, souls and condenser rank all stay. Alphas evolve into Alpha forms, Luckys stay Lucky.
- **Conditional evolutions:** a pair can require day or night, water, a status effect, a location, a party member, a known move element, or a trainer-level, trust-rank or IV threshold. Greyed options name what is still missing, in your game language.
- **Web configurator:** build your own evolution tree at [palvolve.doodesch.de](https://palvolve.doodesch.de) - rewire pairs, set levels and conditions, share it as a short link, and download the config. 17 languages.
- **Reversible by design:** every evolution is snapshotted first, `/palvolve rollback` restores the previous form, and an aborted transformation refunds what it used.
- **Earned, not free:** evolutions cost stones from the buildable Pal Alchemy Workbench, and an optional egg filter can keep eggs hatching base forms.

## Requirements

- **UE4SS Experimental (Palworld)** - the Palworld-specific build, not the generic upstream RE-UE4SS.
- **PalSchema** - provides the Pal Alchemy Workbench, the stones and the recipes. Follow the [PalSchema installation guide](https://okaetsu.github.io/PalSchema/docs/installation), which pairs the correct UE4SS build.

## Installation

1. Install UE4SS Experimental (Palworld) and PalSchema following the [PalSchema installation guide](https://okaetsu.github.io/PalSchema/docs/installation).
2. Unpack the archive so `Mods/Palvolve` and `Mods/PalSchema/mods/Palvolve` land in `Pal/Binaries/Win64/ue4ss/Mods/`.
3. Add `Palvolve : 1` to `ue4ss/Mods/mods.txt` (above the Keybinds entry).

Also on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3766366950) and [Nexus Mods](https://www.nexusmods.com/palworld/mods/3976), the Workshop version with automatic installation and updates.

## Multiplayer

Single player, co-op and dedicated servers all work. A few rules:

- Install UE4SS, PalSchema and Palvolve on the host or server **and** on every client. A client-only install does not work.
- The host or server validates ownership, level, costs and conditions before anything changes.
- On a dedicated server, only the evolving player sees the full cinematic. Everyone else sees the normal recall and resummon.

Dedicated server setup:

1. Install UE4SS Experimental (Palworld) and PalSchema on the server ([installation guide](https://okaetsu.github.io/PalSchema/docs/installation)).
2. Install Palvolve from the GitHub release zip: both folders go into `Pal\Binaries\Win64\ue4ss\Mods\`. Do not copy the Workshop item folder.
3. Add `Palvolve : 1` to `ue4ss\Mods\mods.txt` and restart. Check `UE4SS.log` for `[PalSchema] Added building 'Palvolve_ElementExtractor'`.

Clients join with the normal Workshop install.

## Configuration

- Build and share your own tree in the [web configurator](https://palvolve.doodesch.de).
- Put the exported `config_user.lua` in `%LocalAppData%\Pal\Saved\Palvolve\`. It replaces the default tree and survives updates.

## Known Issues

- Work suitability shows the pre-evolution form until you relog. Job skill book bonuses are not affected.
- Removing the mod needs a cleanup step: run `/palvolve uninstall`, then keep the `PalSchema\mods\Palvolve` data folder or run the [Save Cleaner](https://github.com/DooDesch-Mods/Palworld-Palvolve/blob/main/UNINSTALL.md).

## FAQ

**No "Evolve" option in the hold-4 menu, even though the workbench and stones work?**
UE4SS is not loading Palvolve. The workbench is PalSchema, the Evolve button is UE4SS. Check that UE4SS Experimental (Palworld) is installed and Palvolve is enabled; relaunch if it vanishes mid-session.

**The workbench will not unlock at level 10, or will not stay learned?**
Same cause: UE4SS or PalSchema is not active. The tell is no UE4SS output in the log.

**Co-op and dedicated servers - where do I install it?**
On the server **and** every client. UE4SS, PalSchema and Palvolve have to be active on both sides; a client-only install does not work.

**How do I uninstall it safely? My world crashes after I remove the mod.**
Run `/palvolve uninstall` first, then keep the `PalSchema\mods\Palvolve` data folder or run the Save Cleaner. Back up your saves first. Full steps: [UNINSTALL.md](https://github.com/DooDesch-Mods/Palworld-Palvolve/blob/main/UNINSTALL.md).

**Breeding changed, or an evolved variant will not hatch?**
The egg filter is off by default, so eggs hatch what they normally would. If you turned it on (it makes eggs hatch base forms only), turn it back off in the config or the configurator.

**Evolution vs. adaptation?**
Evolution turns a Pal into a different Pal (Pengullet to Penking). Adaptation changes its element (Pengullet to Pengullet Lux).

**How do I evolve a Pal?**
Build the Pal Alchemy Workbench (level 10), forge an Evolution Stone from skill-fruit essences, then hold 4 and pick Evolve. `/palvolve rollback` undoes it.

**Compatible with other mods?**
Known conflicts: Dynamic Pals and PalMagic. Keep every mod updated, and send your mod list if an option stays greyed out.

**Custom trees and languages?**
Yes. Build and share trees in the [web configurator](https://palvolve.doodesch.de). The mod and configurator run in 17 languages.

## Support

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

When you report something, include your Palvolve version, your Palworld version and the full `UE4SS.log`. Palvolve writes its version into that log at startup.

## Notes

- Tested with Palworld 1.0 build 619 - singleplayer, co-op and dedicated servers.
- Never use mods on official servers.
- Source and releases: [GitHub](https://github.com/DooDesch-Mods/Palworld-Palvolve)
