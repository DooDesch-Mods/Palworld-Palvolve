# Palvolve

Palvolve adds conditional evolutions to Palworld. It preserves all stats and every learned move when evolving.

[![Steam Workshop](https://img.shields.io/badge/Steam_Workshop-Subscribe-1b2838?logo=steam&logoColor=white)](https://steamcommunity.com/sharedfiles/filedetails/?id=3766366950)
[![Nexus Mods](https://img.shields.io/badge/Nexus_Mods-Download-da8e35?logo=nexusmods&logoColor=white)](https://www.nexusmods.com/palworld/mods/3976)
[![Configurator](https://img.shields.io/badge/Configurator-palvolve.doodesch.de-06b6d4)](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve)
[![GitHub Release](https://img.shields.io/github/v/release/DooDesch-Mods/Palworld-Palvolve?logo=github&label=Release)](https://github.com/DooDesch-Mods/Palworld-Palvolve/releases)

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de](https://support.doodesch.de).

## Evolve when you want to

Hold 4, pick Evolve, choose your evolution. Your Pal will evolve right in front of you with hand-picked vanilla effects. Blocked options are greyed out and name exactly what is missing, in the game language.

Learned moves carry over, even when the new form could never learn them on its own. Level, nickname, gender, passives, IVs, souls and condenser rank all stay. Alphas evolve into Alpha forms, Luckys stay Lucky. F2 checks and confirms the summoned Pal without the radial menu.

## Make it yours

143 transformations ship as the starting point, curated together with the community: evolution chains like Pengullet to Penking, fun chains like Sweepa to Snugloo and 87 element adaptations. Some default pairs are already conditioned - Mau becomes Sekhmet only in the desert by day and Wispaw only at night or in a cave, and Relaxaurus turns Lux only while electrified.

Every pair can carry conditions that must hold at evolve time: day/night, standing in water, status effects, locations from caves to wildlife sanctuaries, gender, a known move element, a specific Pal in your party, gliding, your own base or mid-combat. Two pairs with the same target and different conditions form an either/or branch - same Pal, different evolution by day and night.

Build your own tree in the [Palvolve Configurator](https://palvolve.doodesch.de/?utm_source=github&utm_medium=readme&utm_campaign=palvolve): an interactive graph where you rewire pairs, set levels and conditions, share the result as a short link and download the finished config.

## Evolution costs

Evolutions cost stones from the buildable Pal Alchemy Workbench (unlocked in the technology tree at level 10): break skill fruits into element essences, forge Evolution Stones, attune element Adaptation Stones. Optional material costs can be enabled on top. Eggs keep hatching base forms, so evolved Pals stay something you earned.

## In case of an emergency

- Every evolution snapshots your Pal first. Typing `/palvolve rollback` into the normal in-game chat restores the previous form from that snapshot, IVs included.
- If a transformation aborts, everything it consumed is refunded automatically.
- Multiplayer and dedicated servers are fully supported - the server validates ownership, level, costs and conditions before anything changes.

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

Players keep using the normal Workshop version.

## Configuration

The configurator's `config_user.lua` goes into `%LocalAppData%\Pal\Saved\Palvolve\` (the mod creates the folder on first launch; placing it next to `scripts\config.lua` works too). It fully replaces the default tree and survives mod updates.

Hand-written configs use `conditions = { "night", "knowsMove:Dragon", "inParty:Penguin" }` - all listed conditions must hold at once, either/or branches are two pairs with the same target. Unknown condition ids are dropped at load with a log line; older mod versions ignore the field. Everything else (pairs, levels, costs, egg filter, transformation timings) lives in `scripts\config.lua`.

## Uninstalling

**Step-by-step guide: [UNINSTALL.md](UNINSTALL.md)** - both paths (keep the small data folder, or run the Save Cleaner for a world that needs nothing at all), plus recovery for a world that already refuses to load.

A world that ever used Palvolve keeps references to its items in places you cannot reach - the game even records statistics about every item you crafted or picked up, inside your player save. If those references stop resolving, the world no longer loads. PalSchema advertises a cleanup for such leftovers, but on the current game build its cleanup hook does not attach (it says so in every log), so nothing is cleaned automatically. Two rules follow from this:

1. Run `/palvolve uninstall` in chat (in single player, or as the host) while the mod is still installed. It deletes every Palvolve item from your inventory for real, removes the technology unlock, scans every container in the world - chests, pals, other players - and tells you where remaining stacks sit, and lists placed workbenches. Collect what it names, demolish the benches, run it again until it reports the world clean. Do not use the game's own discard for mod items: discarding drops them to the ground, base pals haul them into chests, and the stacks live on in your save.
2. When you then remove the mod, keep the `PalSchema\mods\Palvolve` folder (the data half) installed. It weighs nothing and does nothing on its own - it only keeps the item definitions resolvable so the crafting statistics in your player save cannot break world loading. Removing the Lua half (`Mods\Palvolve`) disables the mod completely.

This dependency survives reinstalls: Steam syncs your savegames, not your mods. If you reinstall the game or move to a new PC, the cloud brings the world back without the data folder - put `PalSchema\mods\Palvolve` (and PalSchema itself) back in place before loading it. The same applies to friends who host your world from their own save.

To cut the dependency for good, use the **[Save Cleaner](save-cleaner/README.md)** (also attached to each GitHub release): with the game closed, it removes every Palvolve trace from the save itself - remaining item stacks, placed workbenches, and the crafting statistics no running game can touch. After that the world loads with nothing of Palvolve installed, on any machine.

If you removed everything and your world no longer loads: either run the Save Cleaner on it, or reinstall the mod (both halves) and the world loads again. Nothing is lost either way.

## Notes

- Tested with Palworld 1.0 build 619 - singleplayer, co-op and dedicated servers.
- On servers the full transformation cinematic plays for the player who evolves. Bystanders see the regular recall and resummon.
- Never use mods on official servers.

## License

GPL-3.0 - see [LICENSE](LICENSE). Copyright (C) 2026 DooDesch.

You may use and modify this code, including in your own mods - but derived work must be released under the GPL-3.0 as well, with source available and credit kept. Versions up to v1.3.2 were published under MIT and remain so.
