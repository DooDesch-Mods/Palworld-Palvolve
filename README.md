# Palvolve

> Turn a captured Pal into a related form and keep everything it earned - the evolutions Palworld never shipped.

[![Steam Workshop](https://img.shields.io/badge/Steam_Workshop-Subscribe-1b2838?logo=steam&logoColor=white)](https://steamcommunity.com/sharedfiles/filedetails/?id=3766366950)
[![Nexus Mods](https://img.shields.io/badge/Nexus_Mods-Download-da8e35?logo=nexusmods&logoColor=white)](https://www.nexusmods.com/palworld/mods/3976)
[![Configurator](https://img.shields.io/badge/Configurator-palvolve.doodesch.de-06b6d4)](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve)
[![GitHub Release](https://img.shields.io/github/v/release/DooDesch-Mods/Palworld-Palvolve?logo=github&label=Release)](https://github.com/DooDesch-Mods/Palworld-Palvolve/releases)

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

## Features

- The default tree starts with **156 transformations**. It has 62 evolution lines like Pengullet to Penking and 87 element adaptations like Pengullet to Pengullet Lux. Seven fun chains include Sweepa to Snugloo.
- Hold 4, then pick Evolve. The evolution sequence plays in front of you. It ends in a finale built from the target's elements. F2 skips the wheel after you set `confirmKeyEnabled = true`.
- Pals keep level, nickname, gender, passives, IVs, souls, condenser rank and every learned move. That includes moves the new form could never learn on its own. Alphas stay Alpha. Luckys stay Lucky.
- At the end of an evolution line, a Pal can **prestige**. Level returns to 1. The Pal keeps its nickname, passives, IVs, souls and every learned move. Each prestige adds one Prestige rank, up to 10. The prestige sequence grows with each rank. The Pal shimmers afterwards.
- An evolution may depend on day or night, water, a status effect, a location, a party member, a known move or passive, an item or an amount of gold, a condenser rank, the last thing the Pal was fed, or a trainer-level, trust-rank or IV threshold. Any condition can be inverted. Greyed options name the missing part in your game language.
- Set an evolution to **automatic** and it runs as soon as its conditions are met. The cost and rollback stay the same. `!palvolve lock` excludes one Pal; `!palvolve unlock` puts it back.
- The Palpedia gets an **Evolutions** tab next to Stats and Habitat. It shows what the selected Pal evolves from and into, plus the level, stone and conditions for each step. Click any Pal in the tree to centre it and follow the line without leaving the screen.
- Build your own evolution tree in the [web configurator](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve). Change pairs, set levels and conditions, share a short link, then download `config_user.lua`. 17 languages.
- Palvolve saves the Pal before an evolution. `!palvolve rollback` restores the previous form. Palvolve refunds the cost if an evolution aborts.
- Each evolution costs an Evolution Stone or a Prestige Stone from the Pal Alchemy Workbench. The optional egg filter keeps eggs hatching base forms.

## Requirements

- **UE4SS Experimental (Palworld)** - use the Palworld-specific build. The generic upstream RE-UE4SS breaks on Palworld 1.0. Its Steam ID does not match, so mods do not load and nothing says why.
- **PalSchema** provides the Pal Alchemy Workbench, stones and recipes.

## Installation

### Steam Workshop (recommended)

Subscribe to [Palvolve](https://steamcommunity.com/sharedfiles/filedetails/?id=3766366950), then enable it under **Options > Mod Management**. The Workshop pulls in UE4SS Experimental (Palworld) and [PalSchema](https://steamcommunity.com/sharedfiles/filedetails/?id=3625280368) as dependencies.

The order in that list decides whether any of it works. Put them in this order, top to bottom:

1. UE4SS Experimental (Palworld)
2. PalSchema
3. Palvolve

With PalSchema above UE4SS the workbench and the stones never appear, and nothing says why. HenryFrost spent two days ruling out everything else before finding it.

### Manual

> ⚠️ Use **UE4SS Experimental (Palworld)** ([Workshop 3625223587](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587)). The generic upstream RE-UE4SS breaks on Palworld 1.0. Its Steam ID does not match, so mods do not load and nothing says why.

Download the release zip from [Nexus Mods](https://www.nexusmods.com/palworld/mods/3976) or the [GitHub releases](https://github.com/DooDesch-Mods/Palworld-Palvolve/releases), then follow these steps.

1. Install UE4SS Experimental (Palworld) and PalSchema following the [PalSchema installation guide](https://okaetsu.github.io/PalSchema/docs/installation).
2. Copy `Mods\Palvolve` into `<Palworld>\Pal\Binaries\Win64\ue4ss\Mods\`.
3. Copy `Mods\PalSchema\mods\Palvolve` into `<Palworld>\Pal\Binaries\Win64\ue4ss\Mods\PalSchema\mods\`.
4. Copy `Pal\Content\Paks\LogicMods\Palvolve.pak` into `<Palworld>\Pal\Content\Paks\LogicMods\`. Create the folder if it does not exist. This file carries the Evolutions page in the Palpedia. Without it, that tab stays empty.
5. Add `Palvolve : 1` to `ue4ss\Mods\mods.txt` (above the Keybinds entry).

A Workshop UE4SS and a manual UE4SS in the same install load UE4SS twice and crash the game.

### Dedicated servers

The server checks the technology unlock. Without Palvolve on the server, the workbench relocks each time you reopen the technology tree.

1. Install **UE4SS Experimental (Palworld)** on the server (proxy dll next to the server binary).
2. Install **PalSchema** on the server ([installation guide](https://okaetsu.github.io/PalSchema/docs/installation)).
3. Install Palvolve from the [GitHub release zip](https://github.com/DooDesch-Mods/Palworld-Palvolve/releases): both folders inside the zip go into `Pal\Binaries\Win64\ue4ss\Mods\`. Do not copy the Workshop item folder - its layout is for the game's own loader.
4. Add `Palvolve : 1` to `ue4ss\Mods\mods.txt` and restart the server.
5. Put your `config_user.lua` in the mod's `scripts\` folder next to `config.lua`. The next start moves it out of reach of updates and logs the new location.
6. Check the server's `UE4SS.log` for this line: `[PalSchema] Added building 'Palvolve_ElementExtractor'`
7. Join the server.
8. Profit.

Every player also needs Palvolve, PalSchema and UE4SS active on their client. The normal Workshop install handles this.

#### Where the config belongs

Drop the file in the mod's `scripts\` folder next to `config.lua`. A mod update replaces that folder. On the next start, Palvolve moves the file to a location an update cannot reach and leaves a note with the new path. A file already there becomes `config_user.lua.bak`. A `config_user.lua` that does not compile stays where it is, so a typo does not cost you the tree you had.

A dedicated server uses `<server>\Pal\Saved\Palvolve\`. A client uses `%LocalAppData%\Pal\Saved\Palvolve\`. Palvolve searches both, so you can still put a file there by hand. On a rented server, `%LocalAppData%` belongs to the hosting company. Use the server path.

Since 1.6.3, one log line names the loaded file and tells you which tree the server runs:

```
[Palvolve] user config loaded (166 pairs, .../Pal/Saved/Palvolve/config_user.lua)
```

Since 1.7.0, the server hands its tree to every player who joins. You do not have to copy `config_user.lua`. You use the server's tree there, then get your own tree back in your own world. Palvolve never saves the server's tree to your disk, and your Survival Guide keeps describing your tree.

The server also sends whether a stone is required and how many, the material costs, the workbench level and the chat setting. The numbers you see match the server.

One gap remains. If you go straight from a Palvolve server to a server without Palvolve, the first server's tree stays until you enter your own world.

## Multiplayer

Single player, co-op and dedicated servers all work. Follow these rules.

- Install UE4SS, PalSchema and Palvolve on the host or server **and** on every client. A client-only install does not work.
- Before anything changes, the host or server checks ownership, level, costs and conditions.
- Only the evolving player sees the evolution sequence on a dedicated server. Everyone else sees the normal recall and resummon.

## Configuration

Build a tree in the [web configurator](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve), then put the exported `config_user.lua` in the mod's `scripts\` folder beside `config.lua`. It replaces the default tree. On the next start, Palvolve moves it out of reach of mod updates. Clients and dedicated servers use the same step; [where the config belongs](#where-the-config-belongs) gives the paths.

A hand-written `config_user.lua` uses `conditions = { "night", "knowsMove:Dragon", "inParty:Penguin", "playerLevel:25" }`. All conditions must hold at once. For either/or branches, write two pairs with the same target. Numeric thresholds use at-least checks:

- `playerLevel:<n>` - trainer level, 1-80
- `trustRank:<n>` - trust rank, 1-10
- `ivTotal:<n>` - sum of the four IVs, 1-400
- `ivEach:<n>` - every IV, 1-100
- `ivHP:<n>` / `ivMelee:<n>` / `ivShot:<n>` / `ivDefense:<n>` - one specific IV, 1-100

A leading `!` inverts a condition. `"!night"` requires anything except night. `"!knowsMove:Dragon"` requires no Dragon move. An inverted threshold means strictly below the number. `"!trustRank:4"` means trust rank 1-3. `"!ivEach:70"` means at least one IV is below 70. Use one `!` per condition. Two pairs such as `{ "trustRank:4" }` and `{ "!trustRank:4" }` split one Pal into a high-trust and a low-trust branch. Mod versions before 1.3.10 ignore `!` conditions (the pair still works, without that requirement).

Everything else (pairs, levels, costs, egg filter, timings) lives in `scripts\config.lua`.

The egg filter starts off. Switch it on and eggs of evolved forms hatch base forms. [EGG-FILTER.md](EGG-FILTER.md) has the full walkthrough and diagrams.

## Uninstalling

Close the game and clean the save at **[palvolve.doodesch.de/save-cleaner](https://palvolve.doodesch.de/save-cleaner?utm_source=github&utm_medium=readme&utm_campaign=palvolve)**. The cleaner runs in your browser and uploads nothing. It works on a world that already refuses to load.

**Full guide, including the two-minute alternative and dedicated servers: [UNINSTALL.md](UNINSTALL.md).**

## Known issues

- Removing the mod without cleaning the save first can stop the world from loading. The [Save Cleaner](https://palvolve.doodesch.de/save-cleaner?utm_source=github&utm_medium=readme&utm_campaign=palvolve) repairs that world as well.
- A rollback does not lock a technology again. Evolving into a species unlocks its saddle and Pal Gear the way catching one does. `!palvolve rollback` returns the Pal and materials, leaving that unlock in place. Removing it could also affect someone who caught the species themselves.

## FAQ

**Evolve is greyed out on one species, while other Pals work?**
Update to 1.5.3 or newer. Palworld spells 42 of its Pal ids two ways. That could stop one species from matching the tree while the rest still worked. HenryFrost found it with a Lamball that refused to evolve while its Lucky counterpart worked. If it still happens on 1.5.3, move Palvolve up in the in-game Mod Management list. Load order lets another mod remove Palvolve's evolutions for one species without showing an error.

**No "Evolve" option in the wheel, even though the workbench and stones work?**
UE4SS is not loading Palvolve. PalSchema supplies the workbench; UE4SS supplies the Evolve button. Check that UE4SS Experimental (Palworld) is installed and Palvolve is enabled. Relaunch if the button vanishes mid-session.

**The workbench will not unlock at level 10, or will not stay unlocked?**
UE4SS or PalSchema is inactive. If the log has no UE4SS output at all, that confirms it. On the Workshop, check the order under **Options > Mod Management** first: UE4SS, then PalSchema, then Palvolve. Since 1.9.4 Palvolve writes a line into `UE4SS.log` when the PalSchema half did not arrive, naming what will be missing.

**Palvolve appears twice in the log, or the log says nothing about a session I just played?**
There are two UE4SS installs in the same game. The one under `Pal\Binaries\Win64` wins; the one under `Mods\NativeMods` never starts and keeps writing an old log. Since 1.9.4 Palvolve names both at startup and says which one is running.

**Co-op and dedicated servers - where do I install it?**
Install it on the server **and** every client. UE4SS, PalSchema and Palvolve must run on both sides. A client-only install does not work.

**How do I uninstall it safely? My world crashes after I remove the mod.**
Clean the save at [palvolve.doodesch.de/save-cleaner](https://palvolve.doodesch.de/save-cleaner?utm_source=github&utm_medium=readme&utm_campaign=palvolve). The cleaner runs in your browser and repairs a world that already refuses to load. See [UNINSTALL.md](UNINSTALL.md) for the full steps.

**Breeding changed, or an evolved variant will not hatch?**
The egg filter starts off, so eggs hatch what they normally would. After you switch it on, eggs of evolved forms hatch base forms. Turn it off in the configurator or in your `config_user.lua`. [EGG-FILTER.md](EGG-FILTER.md) explains the behaviour with diagrams.

**Where do I change a setting that is not on the quick setup page?**
Find all settings at [palvolve.doodesch.de/simple](https://palvolve.doodesch.de/simple?utm_source=github&utm_medium=readme&utm_campaign=palvolve), under the four switches. They are grouped, searchable and marked for either the server's file or a player's own. Load your running `config_user.lua` to start from the server's current setup. You can edit `scripts\config.lua`, though the next mod update replaces it.

**Evolution vs. adaptation?**
Evolution turns a Pal into a different Pal (Pengullet to Penking). Adaptation changes its element (Pengullet to Pengullet Lux).

**How do I evolve a Pal?**
Build the Pal Alchemy Workbench (unlocks at level 10, adjustable), forge an Evolution Stone from skill-fruit essences, then hold 4 and pick Evolve. `!palvolve rollback` restores the previous form.

**How do I prestige a Pal?**
Take a Pal to the end of its evolution line and reach the level in `prestigeMinLevel`, then hold 4. The entry reads Prestige instead of Evolve. A Prestige Stone costs an Evolution Stone and Nightstar Sand at the Pal Alchemy Workbench. The host supplies both settings on a server.

**Why does a Pal I expected to prestige only offer Evolve?**
An evolution still lies ahead, and evolution takes priority. With `prestigeMinEvolutions` at 0, a Pal with no evolution can prestige straight away.

**How do I turn prestige off?**
Set `prestigeEnabled = false` in `config_user.lua`. Palvolve stops offering prestige and removes the Prestige Stone from the workbench. With `prestigeAutoLink = false`, prestige remains available only for connections drawn in the configurator.

**The workbench unlocks too late (or too early) for my run?**
Set `techLevelCap` in the configurator or in `config_user.lua` to the player level you want, anywhere from 1 to 100. The setting survives mod updates.

**How do I turn the chat messages off?**
Set `chatMessages = "replies"` in `config_user.lua` to keep answers to your actions. Set it to `"off"` to keep only answers to `!palvolve` commands. The server admin's setting reaches every player. Palvolve still shows the version check between you and the server.

**F2 does nothing.**
Since 1.6.4, Palvolve claims no key by default. Set `confirmKeyEnabled = true` in `config_user.lua`. The wheel (hold 4) and `!palvolve evolve` work with either setting.

**Why `!palvolve` and not `/palvolve`?**
A leading slash belongs to the game's admin commands. Palworld answers every such line with "You are not an Admin" before a mod sees it, and mods cannot stop that reply. `/palvolve` still works. `!palvolve` avoids the reply and matches the prefix used by other Palworld command mods.

**I evolved a Pal but its saddle is missing from the Tech Tree and Pal Gear Workbench?**
Since 1.4.0, Palvolve unlocks those recipes when a Pal evolves into that species. A missing saddle means the native component is not loading. Check the UE4SS log for a line starting with `[PalvolveNative]` and use the UE4SS build Palvolve was built against. Set `unlockCatchTech = false` in your `config_user.lua` if you want the vanilla rule, where catching a species unlocks its gear. Before 1.8.0, Palvolve read that setting only from the mod's own copy, which every update replaced.

**Compatible with other mods?**
See [Known mod conflicts](#known-mod-conflicts) below. Keep every mod updated and send your mod list if an option stays greyed out.

**Custom trees and languages?**
Yes. Build and share trees in the [web configurator](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve). The mod and configurator run in 17 languages.

## Known mod conflicts

**Try the load order first.** The in-game Mod Management list is ordered, and moving Palvolve to
the top has fixed a case where evolutions stayed greyed out for one species with no error anywhere
(HenryFrost, Discord, 2026-07-31). Rule that out before anything below. Both greyed-out entries in
the table were reported before anyone knew order mattered, so they may well be the same thing.

These come from player reports. I do not run these mods myself, so each entry says "someone hit
this" rather than passing judgement on the other mod. If you use one of them and everything works,
tell me and I will correct the entry.

| Mod | Symptom | Reported | Status |
|---|---|---|---|
| Dynamic Pals | Not fully compatible, evolve options can stay greyed out | 2026-07-20, Nexus | Open, unverified |
| PalMagic | Not fully compatible, evolve options can stay greyed out | 2026-07-20, Nexus | Open, unverified |
| Existing Pal Editor | Evolve entry missing from the wheel | 2026-07-20, Nexus | Likely fixed in 1.3.3 |
| Technology Tree Overhaul | Evolution stones missing from the Pal Alchemy Workbench | 2026-08-25, Discord (Shas Hakomairos) | Fixed in 1.9.0 |
| Final Boss Unlock | The game crashes when you summon one of its pals and press 4 | 2026-08, Steam comments (StrongFish91) | Open, unverified |

The Existing Pal Editor report matched a Palvolve bug of its own: the wheel could lose its
Evolve entry for a whole session when part of the wheel loaded late. That was fixed in
1.3.3 and nobody has reported the combination since. If you still see it on 1.3.3 or newer, that is
a separate problem - please report it.

## Support

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

Include your Palvolve version, Palworld version and full `UE4SS.log` with a report. Palvolve logs its version at startup, so the file usually dates the problem for me.

## Notes

- Tested with Palworld 1.0.3 build 1283 - single player, co-op and dedicated servers.
- Never use mods on official servers.

## License

GPL-3.0 - see [LICENSE](LICENSE). Copyright (C) 2026 DooDesch.

You may use and modify this code, including in your own mods. Release derived work under the GPL-3.0 with source available and credit kept. Versions up to v1.3.2 were published under MIT and remain so.
