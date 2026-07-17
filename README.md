# Palvolve

Palvolve adds conditional evolutions to Palworld. It preserves all stats and every learned move when evolving.

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de](https://support.doodesch.de).

## Evolve when you want to

Hold 4, pick Evolve, choose your evolution. Your Pal will evolve right in front of you with hand-picked vanilla effects. Blocked options are greyed out and name exactly what is missing, in the game language.

Learned moves carry over, even when the new form could never learn them on its own. Level, nickname, gender, passives, IVs, souls and condenser rank all stay. Alphas evolve into Alpha forms, Luckys stay Lucky. F2 checks and confirms the summoned Pal without the radial menu.

## Make it yours

143 curated transformations ship as the starting point, curated together with the community: evolution chains like Pengullet to Penking, fun chains like Sweepa to Snugloo and 87 element adaptations. Some default pairs are already conditioned - Mau becomes Sekhmet only in the desert by day and Wispaw only at night or in a cave, and Relaxaurus turns Lux only while electrified.

Every pair can carry conditions that must hold at evolve time: day/night, standing in water, status effects, locations from caves to wildlife sanctuaries, gender, a known move element, a specific Pal in your party, gliding, your own base or mid-combat. Two pairs with the same target and different conditions form an either/or branch - same Pal, different evolution by day and night.

Build your own tree in the [Palvolve Configurator](https://palvolve.doodesch.de): an interactive graph where you rewire pairs, set levels and conditions, share the result as a short link and download the finished config.

## Evolution costs

Evolutions cost stones from the buildable Pal Alchemy Workbench (unlocked in the technology tree at level 10): break skill fruits into element essences, forge Evolution Stones, attune element Adaptation Stones. Optional material costs can be enabled on top. Eggs keep hatching base forms, so evolved Pals stay something you earned.

## In case of an emergency

- Every evolution snapshots your Pal first. Typing `/palvolve rollback` into the normal in-game chat restores the previous form from that snapshot, IVs included.
- Costs are transactional: anything consumed is refunded automatically if a transformation aborts.
- Multiplayer and dedicated servers are fully supported - the server validates ownership, level, costs and conditions before anything changes.

## Installation

### Steam Workshop (recommended)

Subscribe to [Palvolve](https://steamcommunity.com/sharedfiles/filedetails/?id=3766366950) and enable it in-game under **Options > Mod Management**. UE4SS Experimental (Palworld) and [PalSchema](https://steamcommunity.com/sharedfiles/filedetails/?id=3625280368) are pulled in automatically as Workshop dependencies.

### Manual

> ⚠️ Use **UE4SS Experimental (Palworld)** ([Workshop 3625223587](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587)), not the generic upstream RE-UE4SS - the upstream build breaks on Palworld 1.0 (Steam-ID mismatch, mods silently stop loading).

1. Install UE4SS Experimental (Palworld) and PalSchema following the [PalSchema installation guide](https://okaetsu.github.io/PalSchema/docs/installation).
2. Copy `Mods\Palvolve` into `<Palworld>\Pal\Binaries\Win64\ue4ss\Mods\`.
3. Copy `Mods\PalSchema\mods\Palvolve` into `<Palworld>\Pal\Binaries\Win64\ue4ss\Mods\PalSchema\mods\`.
4. Add `Palvolve : 1` to `ue4ss\Mods\mods.txt` (above the Keybinds entry).

Never mix a Workshop UE4SS and a manual UE4SS in the same install - that double-loads UE4SS and crashes the game.

## Configuration

The configurator's `config_user.lua` goes into `%LocalAppData%\Pal\Saved\Palvolve\` (the mod creates the folder on first launch; placing it next to `scripts\config.lua` works too). It fully replaces the default tree and survives mod updates.

Hand-written configs use `conditions = { "night", "knowsMove:Dragon", "inParty:Penguin" }` - all listed conditions must hold at once, either/or branches are two pairs with the same target. Unknown condition ids are dropped at load with a log line; older mod versions ignore the field. Everything else (pairs, levels, costs, egg filter, transformation timings) lives in `scripts\config.lua`.

## Notes

- Tested with Palworld 1.0 build 24181527 - singleplayer, co-op and dedicated servers.
- On a dedicated server, install the mod (and UE4SS + PalSchema) server-side as well.
- Known limitation: on dedicated servers the final reveal effects do not render on the client yet. The evolution itself works.
- Demolish placed Pal Alchemy Workbenches before removing the mod - worlds with placed modded buildings will not load without it (game-side limitation). Modded items in inventories are cleaned up by PalSchema.
- Never use mods on official servers.

## License

MIT - see [LICENSE](LICENSE).
