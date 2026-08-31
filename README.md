# Palvolve

> Turn a captured Pal into a related form, on your terms, and keep every stat, IV and move it already learned - the evolutions Palworld never shipped.

[![Steam Workshop](https://img.shields.io/badge/Steam_Workshop-Subscribe-1b2838?logo=steam&logoColor=white)](https://steamcommunity.com/sharedfiles/filedetails/?id=3766366950)
[![Nexus Mods](https://img.shields.io/badge/Nexus_Mods-Download-da8e35?logo=nexusmods&logoColor=white)](https://www.nexusmods.com/palworld/mods/3976)
[![Configurator](https://img.shields.io/badge/Configurator-palvolve.doodesch.de-06b6d4)](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve)
[![GitHub Release](https://img.shields.io/github/v/release/DooDesch-Mods/Palworld-Palvolve?logo=github&label=Release)](https://github.com/DooDesch-Mods/Palworld-Palvolve/releases)

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

## Features

- **143 transformations to start with:** evolution chains like Pengullet to Penking, fun chains like Sweepa to Snugloo, and 87 element adaptations.
- **Evolve when you want to:** hold 4, pick Evolve, and your Pal transforms in front of you with a finale built from its target elements. F2 does the same without the menu once you switch it on (`confirmKeyEnabled = true`).
- **Keeps identity and progress:** every learned move carries over, even ones the new form could never learn on its own, and level, nickname, gender, passives, IVs, souls and condenser rank all stay. Alphas evolve into Alpha forms, Luckys stay Lucky.
- **Prestige at the end of a line:** a Pal with nowhere left to evolve can start over. Level goes back to 1, everything it earned stays, and each prestige adds a rank of the Prestige passive up to 10. The show gets bigger with each rank, and a prestiged Pal shimmers from then on.
- **Conditional evolutions:** an evolution can require day or night, water, a status effect, a location, a party member, a known move or passive, an item or an amount of gold, a condenser rank, the last thing the Pal was fed, or a trainer-level, trust-rank or IV threshold. Every condition can also be flipped to the opposite. Greyed options name what is still missing, in your game language.
- **Evolutions that happen on their own:** set an evolution to automatic and it runs as soon as its conditions are met. It costs the same and can be undone the same way. `!palvolve lock` keeps one Pal out of it, `!palvolve unlock` puts it back.
- **Evolution tree in the Palpedia:** a third tab, "Evolutions", shows what the selected Pal evolves from and into, with the level, the stone and the conditions each step needs. Click a Pal inside the tree to make it the new centre and walk a whole line without leaving the screen.
- **Web configurator:** build your own evolution tree at [palvolve.doodesch.de](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve) - change which Pal becomes which, set levels and conditions, share it as a short link, and download the config. 17 languages.
- **Every evolution can be undone:** the Pal is saved beforehand, `!palvolve rollback` brings the old form back, and an evolution that breaks off refunds what it used.
- **Evolutions cost something:** stones from the Pal Alchemy Workbench you build yourself. An optional egg filter can keep eggs hatching base forms.

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
4. Copy `Pal\Content\Paks\LogicMods\Palvolve.pak` into `<Palworld>\Pal\Content\Paks\LogicMods\`, creating the folder if it does not exist. It carries the Evolutions page in the Palpedia; without it that tab stays empty.
5. Add `Palvolve : 1` to `ue4ss\Mods\mods.txt` (above the Keybinds entry).

Never mix a Workshop UE4SS and a manual UE4SS in the same install - that double-loads UE4SS and crashes the game.

### Dedicated servers

The server checks the technology unlock. If the mod is not running on the server, the workbench relocks every time you reopen the technology tree.

1. Install **UE4SS Experimental (Palworld)** on the server (proxy dll next to the server binary).
2. Install **PalSchema** on the server ([installation guide](https://okaetsu.github.io/PalSchema/docs/installation)).
3. Install Palvolve from the [GitHub release zip](https://github.com/DooDesch-Mods/Palworld-Palvolve/releases): both folders inside the zip go into `Pal\Binaries\Win64\ue4ss\Mods\`. Do not copy the Workshop item folder - its layout is for the game's own loader.
4. Add `Palvolve : 1` to `ue4ss\Mods\mods.txt` and restart the server.
5. Put your `config_user.lua` in `<server>\Pal\Saved\Palvolve\`, the folder Palvolve creates next to the world saves on the first start.
6. Check the server's `UE4SS.log` for the line: `[PalSchema] Added building 'Palvolve_ElementExtractor'`
7. ???
8. Profit.

Every player also needs Palvolve, PalSchema and UE4SS active on their own client. The normal Workshop install does that automatically.

#### Where the config belongs

A server looks in `<server>\Pal\Saved\Palvolve\config_user.lua` first, then in `%LocalAppData%\Pal\Saved\Palvolve\`, which on a rented server belongs to the hosting company rather than to you.

Since 1.8.0 you can also just drop the file in the mod's own `scripts\` folder. On the next start it is moved to whichever of those two paths applies, a note is left behind saying where it went, and any config already there is kept as `config_user.lua.bak`. That folder is the one most people find first, and a mod update replaces it, so nothing is meant to stay there.

Since 1.6.3 the log names the file it loaded, so one line tells you which tree the server is running:

```
[Palvolve] user config loaded (166 pairs, .../Pal/Saved/Palvolve/config_user.lua)
```

Since 1.7.0 the server hands its tree to every player who joins, so nobody has to copy `config_user.lua` around any more. You see and use what the server runs, and get your own tree back in a world of your own. The server's tree is on loan: it is never saved to your disk, and your Survival Guide keeps describing your own.

The rules travel with it as well - whether a stone is required and how many, the material costs, the workbench level and how talkative the mod is in chat - so the numbers you see are the ones the server uses.

One gap: going straight from a Palvolve server to a server without Palvolve keeps the first server's tree until you enter a world of your own.

## Multiplayer

Single player, co-op and dedicated servers all work. A few rules:

- Install UE4SS, PalSchema and Palvolve on the host or server **and** on every client. A client-only install does not work.
- The host or server checks ownership, level, costs and conditions before anything changes.
- On a dedicated server, only the evolving player sees the full cinematic. Everyone else sees the normal recall and resummon.

## Configuration

Build your tree in the [web configurator](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve) and drop the exported `config_user.lua` into `%LocalAppData%\Pal\Saved\Palvolve\` (created on first launch). It replaces the default tree and survives mod updates. On a dedicated server the folder is `<server>\Pal\Saved\Palvolve\` instead.

Hand-written configs use `conditions = { "night", "knowsMove:Dragon", "inParty:Penguin", "playerLevel:25" }`: all conditions must hold at once, and either/or branches are two pairs with the same target. Numeric thresholds are at-least checks:

- `playerLevel:<n>` - trainer level, 1-80
- `trustRank:<n>` - trust rank, 1-10
- `ivTotal:<n>` - sum of the four IVs, 1-400
- `ivEach:<n>` - every IV, 1-100
- `ivHP:<n>` / `ivMelee:<n>` / `ivShot:<n>` / `ivDefense:<n>` - one specific IV, 1-100

A leading `!` turns any condition into its opposite: `"!night"` (must not be night), `"!knowsMove:Dragon"` (knows no Dragon move). Negated thresholds are strict below-checks - `"!trustRank:4"` means trust rank 1-3, and `"!ivEach:70"` means at least one IV is below 70. One `!` per condition. Two pairs like `{ "trustRank:4" }` and `{ "!trustRank:4" }` split one Pal into a high-trust and a low-trust branch. Mod versions before 1.3.10 ignore `!` conditions (the pair still works, just without that requirement).

Everything else (pairs, levels, costs, egg filter, timings) lives in `scripts\config.lua`.

The egg filter is off by default. When on, eggs of evolved forms hatch base forms instead. Full walkthrough with diagrams: [EGG-FILTER.md](EGG-FILTER.md).

## Uninstalling

Close the game and clean the save at **[palvolve.doodesch.de/save-cleaner](https://palvolve.doodesch.de/save-cleaner?utm_source=github&utm_medium=readme&utm_campaign=palvolve)**. It runs in your browser, nothing is uploaded, and it works on a world that already refuses to load.

**Full guide, including the two-minute alternative and dedicated servers: [UNINSTALL.md](UNINSTALL.md).**

## Known issues

- Removing the mod without cleaning the save first can stop the world from loading. The [Save Cleaner](https://palvolve.doodesch.de/save-cleaner?utm_source=github&utm_medium=readme&utm_campaign=palvolve) repairs that world as well.
- A rollback does not lock a technology again. Evolving into a species unlocks its saddle and Pal Gear the way catching one does, and `!palvolve rollback` gives the Pal and the materials back but leaves that unlock in place. Taking it away again would also take it from someone who had caught the species themselves, which is the worse mistake of the two.

## FAQ

**Evolve is greyed out on one species, while other Pals work?**
Update to 1.5.3 or newer. Palworld spells 42 of its own Pal ids two ways, which could stop one species from matching the tree while every other Pal kept working. HenryFrost spent an evening on this with a Lamball that refused to evolve while its Lucky counterpart did. If it still happens on 1.5.3, move Palvolve up in the in-game Mod Management list: that list is ordered, and another mod can take Palvolve's evolutions out for one species with no error showing up.

**No "Evolve" option in the hold-4 menu, even though the workbench and stones work?**
UE4SS is not loading Palvolve. The workbench is PalSchema, the Evolve button is UE4SS. Check that UE4SS Experimental (Palworld) is installed and Palvolve is enabled; relaunch if it vanishes mid-session.

**The workbench will not unlock at level 10, or will not stay learned?**
Same cause: UE4SS or PalSchema is not active. The tell is no UE4SS output in the log.

**Co-op and dedicated servers - where do I install it?**
On the server **and** every client. UE4SS, PalSchema and Palvolve have to be active on both sides; a client-only install does not work.

**How do I uninstall it safely? My world crashes after I remove the mod.**
Clean the save at [palvolve.doodesch.de/save-cleaner](https://palvolve.doodesch.de/save-cleaner?utm_source=github&utm_medium=readme&utm_campaign=palvolve). It runs in your browser and repairs a world that already refuses to load. Full steps: [UNINSTALL.md](UNINSTALL.md).

**Breeding changed, or an evolved variant will not hatch?**
The egg filter is off by default, so eggs hatch what they normally would. If you turned it on, eggs of evolved forms hatch base forms instead. Turn it back off in the configurator or in your `config_user.lua`. What it does and why, with diagrams: [EGG-FILTER.md](EGG-FILTER.md).

**Where do I change a setting that is not on the quick setup page?**
All of them are at [palvolve.doodesch.de/simple](https://palvolve.doodesch.de/simple?utm_source=github&utm_medium=readme&utm_campaign=palvolve), under the four switches: grouped and searchable, each one marked as belonging in the server's file or in a player's own. Load your running `config_user.lua` there to start from what your server does today. Editing `scripts\config.lua` also works, but the next mod update replaces that file.

**Evolution vs. adaptation?**
Evolution turns a Pal into a different Pal (Pengullet to Penking). Adaptation changes its element (Pengullet to Pengullet Lux).

**How do I evolve a Pal?**
Build the Pal Alchemy Workbench (unlocks at level 10, adjustable), forge an Evolution Stone from skill-fruit essences, then hold 4 and pick Evolve. `!palvolve rollback` undoes it.

**How do I prestige a Pal?**
Take a Pal to the end of its evolution line and to the level `prestigeMinLevel` asks for, then hold 4: the entry reads Prestige instead of Evolve. It costs a Prestige Stone, crafted at the Pal Alchemy Workbench from an Evolution Stone and Nightstar Sand. On a server both settings come from the host.

**Why does a Pal I expected to prestige only offer Evolve?**
It still has an evolution ahead of it, and those come first. A Pal with no evolution at all can prestige straight away when `prestigeMinEvolutions` is 0.

**How do I turn prestige off?**
Set `prestigeEnabled = false` in `config_user.lua`. No Pal is offered a prestige any more, and the Prestige Stone leaves the workbench with it. `prestigeAutoLink = false` keeps prestige but stops the mod working out connections for you, so only the ones drawn in the editor count.

**The workbench unlocks too late (or too early) for my run?**
Set `techLevelCap` in the configurator or in `config_user.lua` to the player level you want, anywhere from 1 to 100. The setting survives mod updates.

**How do I turn the chat messages off?**
Set `chatMessages = "replies"` in `config_user.lua` to keep only what answers something you did, or `"off"` to keep only the answers to `!palvolve` commands. On a server the admin's setting reaches every player. The version check between you and the server is always shown.

**F2 does nothing.**
Since 1.6.4 the mod claims no key unless you ask it to: set `confirmKeyEnabled = true` in `config_user.lua`. Evolving works through the wheel (hold 4) and `!palvolve evolve` either way.

**Why `!palvolve` and not `/palvolve`?**
A leading slash belongs to the game's admin commands: Palworld answers every such line with "You are not an Admin" before any mod sees it, and no mod can stop that reply. `/palvolve` still works if that is what you are used to - `!palvolve` is the quiet one, and the same prefix the other Palworld command mods use.

**I evolved a Pal but its saddle is missing from the Tech Tree and Pal Gear Workbench?**
Since 1.4.0 the mod unlocks those recipes for you when you evolve a Pal into that species. If the saddle still does not show up, the native component behind it is not loading. Check the UE4SS log for a line starting with `[PalvolveNative]`, and make sure your UE4SS build matches the one the mod was built against. If you prefer the vanilla rule that only catching a species unlocks its gear, set `unlockCatchTech = false` in your `config_user.lua`. Before 1.8.0 that line was only read from the mod's own copy, which every update replaced.

**Compatible with other mods?**
Mostly, with a few known conflicts - see [Known mod conflicts](#known-mod-conflicts) below. Keep every mod updated, and send your mod list if an option stays greyed out.

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
| Existing Pal Editor | Evolve entry missing from the radial menu | 2026-07-20, Nexus | Likely fixed in 1.3.3 |
| Technology Tree Overhaul | Evolution stones missing from the Pal Alchemy Workbench | 2026-08-25, Discord (Shas Hakomairos) | Fixed in 1.9.0 |

The Existing Pal Editor report matched a Palvolve bug of its own: the radial menu could lose its
Evolve entry for a whole session because the wheel's interface classes load late. That was fixed in
1.3.3 and nobody has reported the combination since. If you still see it on 1.3.3 or newer, that is
a separate problem - please report it.

## Support

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

When you report something, include your Palvolve version, your Palworld version and the full `UE4SS.log`. Palvolve writes its version into that log at startup, so it is usually all I need to place the problem.

## Notes

- Tested with Palworld 1.0.3 build 1283 - singleplayer, co-op and dedicated servers.
- Never use mods on official servers.

## License

GPL-3.0 - see [LICENSE](LICENSE). Copyright (C) 2026 DooDesch.

You may use and modify this code, including in your own mods - but derived work must be released under the GPL-3.0 as well, with source available and credit kept. Versions up to v1.3.2 were published under MIT and remain so.
