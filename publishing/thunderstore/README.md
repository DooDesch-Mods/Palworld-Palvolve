# Palvolve

> Turn a captured Pal into a related form and keep everything it earned - the evolutions Palworld never shipped.

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

## Features

- The default tree starts with **156 transformations**. It has 62 evolution lines like Pengullet to Penking and 87 element adaptations like Pengullet to Pengullet Lux. Seven fun chains include Sweepa to Snugloo.
- Hold 4, then pick Evolve. The evolution sequence plays in front of you, ending in a finale built from the target's elements. F2 skips the wheel after you set `confirmKeyEnabled = true`.
- Pals keep level, nickname, gender, passives, IVs, souls, condenser rank and every learned move. That includes moves the new form could never learn on its own. Alphas stay Alpha. Luckys stay Lucky.
- At the end of an evolution line, a Pal can **prestige**. Level returns to 1, while it keeps its nickname, passives, IVs, souls and every learned move. Each prestige adds one Prestige rank, up to 10. It costs a Prestige Stone. The sequence grows with each rank; the Pal shimmers afterwards.
- An evolution pair may depend on day or night, water, a status effect, a location, a party member, a known move or passive, an item or an amount of gold, a condenser rank, the last thing the Pal was fed, or a trainer-level, trust-rank or IV threshold. Any condition can be inverted. Greyed options name the missing part in your game language.
- Set an evolution to **automatic** and it runs as soon as its conditions are met. The setting starts off. `!palvolve lock` excludes one Pal.
- Evolving adds an **Evolved passive** from I to IV. It raises max HP, movement speed and work speed, with an optional fourth move slot.
- The Palpedia gets an **Evolutions** tab next to Stats and Habitat. It shows what the selected Pal evolves from and into, plus the level, stone and conditions for each step.
- Build your own evolution tree in the [web configurator](https://palvolve.doodesch.de). Rewire pairs, set levels and conditions, share a short link, then download the config. 17 languages.
- Palvolve saves the Pal before an evolution. `!palvolve rollback` restores the previous form. Palvolve refunds the cost if an evolution aborts.
- Each evolution costs an Evolution Stone or a Prestige Stone from the Pal Alchemy Workbench. The optional egg filter keeps eggs hatching base forms.

## Requirements

- **UE4SS Experimental (Palworld)** - use the Palworld-specific build. The generic upstream RE-UE4SS does not work here.
- **PalSchema** provides the Pal Alchemy Workbench, stones and recipes. Its [installation guide](https://okaetsu.github.io/PalSchema/docs/installation) names the matching UE4SS build.

## Installation

1. Install UE4SS Experimental (Palworld) and PalSchema following the [PalSchema installation guide](https://okaetsu.github.io/PalSchema/docs/installation).
2. Unpack the archive so `Mods/Palvolve` and `Mods/PalSchema/mods/Palvolve` land in `Pal/Binaries/Win64/ue4ss/Mods/`.
3. Copy `Pal/Content/Paks/LogicMods/Palvolve.pak` into `Pal/Content/Paks/LogicMods/`, creating the folder if it does not exist. This file carries the Evolutions page in the Palpedia.
4. Add `Palvolve : 1` to `ue4ss/Mods/mods.txt` (above the Keybinds entry).

You can also get Palvolve from the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3766366950) and [Nexus Mods](https://www.nexusmods.com/palworld/mods/3976). The Workshop handles installation and updates.

## Multiplayer

Single player, co-op and dedicated servers all work. Follow these rules.

- Install UE4SS, PalSchema and Palvolve on the host or server **and** on every client. A client-only install does not work.
- Before anything changes, the host or server validates ownership, level, costs and conditions.
- Only the evolving player sees the evolution sequence on a dedicated server. Everyone else sees the normal recall and resummon.

Dedicated server setup:

1. Install UE4SS Experimental (Palworld) and PalSchema on the server ([installation guide](https://okaetsu.github.io/PalSchema/docs/installation)).
2. Install Palvolve from the GitHub release zip. Both folders go into `Pal\Binaries\Win64\ue4ss\Mods\`. Do not copy the Workshop item folder.
3. Add `Palvolve : 1` to `ue4ss\Mods\mods.txt` and restart. Check `UE4SS.log` for `[PalSchema] Added building 'Palvolve_ElementExtractor'`.
4. Put your `config_user.lua` in the mod's `scripts\` folder next to `config.lua`. The next start moves it to `<server>\Pal\Saved\Palvolve\`, out of reach of updates, and logs the move.

Clients join through the normal Workshop install. Since 1.7.0, the server hands its tree and rules to every player who joins. You do not have to copy `config_user.lua`. The client shows what the server runs, then restores its own tree in its own world.

## Configuration

- Build and share your own tree in the [web configurator](https://palvolve.doodesch.de).
- Put the exported `config_user.lua` in the mod's `scripts\` folder beside `config.lua`. It replaces the default tree. The next start moves it out of reach of mod updates and logs the new location.
- The configurator puts 44 grouped, searchable settings beside the tree. They cover the cost of evolving through to the length of the evolution sequence.

## Known issues

- Clean the save at [palvolve.doodesch.de/save-cleaner](https://palvolve.doodesch.de/save-cleaner) before removing the mod. The cleaner runs in your browser and repairs a world that already refuses to load.

## FAQ

**No "Evolve" option in the wheel, even though the workbench and stones work?**
UE4SS is not loading Palvolve. PalSchema supplies the workbench; UE4SS supplies the Evolve button. Check that UE4SS Experimental (Palworld) is installed and Palvolve is enabled. Relaunch if the button vanishes mid-session.

**The workbench will not unlock at level 10, or will not stay unlocked?**
UE4SS or PalSchema is inactive. No UE4SS output in the log confirms it.

**Co-op and dedicated servers - where do I install it?**
Install it on the server **and** every client. UE4SS, PalSchema and Palvolve must run on both sides. A client-only install does not work.

**How do I uninstall it safely? My world crashes after I remove the mod.**
Clean the save at [palvolve.doodesch.de/save-cleaner](https://palvolve.doodesch.de/save-cleaner). The cleaner runs in your browser and repairs a world that already refuses to load. See [UNINSTALL.md](https://github.com/DooDesch-Mods/Palworld-Palvolve/blob/main/UNINSTALL.md) for the full steps.

**Breeding changed, or an evolved variant will not hatch?**
The egg filter starts off, so eggs hatch what they normally would. After you switch it on, eggs hatch base forms only. Turn it off in the config or configurator.

**Evolution vs. adaptation?**
Evolution turns a Pal into a different Pal (Pengullet to Penking). Adaptation changes its element (Pengullet to Pengullet Lux).

**How do I evolve a Pal?**
Build the Pal Alchemy Workbench (unlocks at level 10, adjustable), forge an Evolution Stone from skill-fruit essences, then hold 4 and pick Evolve. `!palvolve rollback` restores the previous form.

**The workbench unlocks too late (or too early) for my run?**
Set `techLevelCap` in the configurator or `config_user.lua` to the player level you want, anywhere from 1 to 100. Palvolve rewrites its technology entry on startup. The setting survives mod updates.

**Why `!palvolve` and not `/palvolve`?**
A leading slash is the game's admin sigil. Palworld answers every such line with "You are not an Admin" before a mod sees it, and mods cannot intercept that reply. `/palvolve` still works. `!palvolve` avoids the reply and matches the prefix used by other Palworld command mods.

**Compatible with other mods?**
Dynamic Pals and PalMagic are known conflicts. Keep every mod updated and send your mod list if an option stays greyed out.

**Custom trees and languages?**
Yes. Build and share trees in the [web configurator](https://palvolve.doodesch.de). The mod and configurator run in 17 languages.

## Support

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

Include your Palvolve version, Palworld version and full `UE4SS.log` with a report. Palvolve logs its version at startup.

## Notes

- Tested with Palworld 1.0.3 build 1283 - single player, co-op and dedicated servers.
- Never use mods on official servers.
- Source and releases: [GitHub](https://github.com/DooDesch-Mods/Palworld-Palvolve)
