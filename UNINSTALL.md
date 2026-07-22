# Uninstalling Palvolve

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

A world that used Palvolve stores references to the mod's items in places you cannot reach by hand: item stacks in chests, the placed workbench, and crafting statistics inside each player file. When the mod's definitions disappear, those references stop resolving and the world refuses to load. This guide removes them properly. Nothing here can lose your world - every path below is reversible, and a world that already refuses to load is recovered the same way.

Two ways to go, pick one:

| | Path A: keep the data folder | Path B: Save Cleaner |
|---|---|---|
| Effort | 2 minutes | 10 minutes, one-time |
| Result | Mod fully disabled, one inert folder stays | No trace of Palvolve anywhere |
| Survives game reinstall / new PC | No - you must place the folder again | Yes |

## Before either path: clean the world in-game

With the mod still installed, in single player or as the host:

1. Open the chat and run `/palvolve uninstall`.
2. It deletes every Palvolve item from your inventory for real, removes the technology unlock, scans every container in the world and names the exact spot of every remaining stack, and lists placed workbenches. Do not use the game's own discard for mod items - discarding drops them on the ground, and base pals haul the drops into chests.
3. Collect what it names, empty and demolish the workbenches it lists, pick up what drops, and run the command again.
4. When it reports the world clean: save, then quit.

On a dedicated server, run the command as the host or from the server console; every player should also run it once for their own inventory and statistics.

## Path A: keep the data folder (2 minutes)

1. Remove the Lua half: delete `Pal\Binaries\Win64\ue4ss\Mods\Palvolve` and remove the `Palvolve : 1` line from `ue4ss\Mods\mods.txt`. Workshop users: unsubscribe removes both halves - put the data folder from step 2 back afterwards.
2. Keep `Pal\Binaries\Win64\ue4ss\Mods\PalSchema\mods\Palvolve` installed. This is the data half: it defines the items so your save stays readable, and does nothing else.

The mod is now fully disabled. Remember one thing: Steam syncs savegames, not mods. After a game reinstall, or on another PC that loads this world, put the data folder back before loading. If you forget, the world refuses to load - place the folder again and it loads.

## Path B: Save Cleaner (no trace left)

The Save Cleaner edits the save files themselves, with the game closed, so the world stops needing anything. Use it after the in-game cleanup above, or on a world that already refuses to load.

1. Download `PalvolveSaveCleaner.zip` from the [latest release](https://github.com/DooDesch-Mods/Palworld-Palvolve/releases/latest) and extract it anywhere.
2. Download `PST_standalone_*.7z` from [PalworldSaveTools releases](https://github.com/deafdudecomputers/PalworldSaveTools/releases/latest) and extract it into the cleaner folder as `PalworldSaveTools` (it provides the save file codec).
3. Close Palworld. Double-click `run-cleaner.bat`.
4. Pick your world from the list. The cleaner shows exactly what it would change (dry run) and asks before writing. A full copy of the world folder is created first.
5. Start the game and load the world. Done - the mod can be removed completely, on every machine.

What it changes: item stacks with Palvolve ids become plain Stone at the same stack size, placed workbenches and their work assignments are removed, and Palvolve entries leave each player's crafting statistics and technology unlocks. Your `LocalData.sav` - the revealed map - is never touched. Anything it does not recognize is reported instead of skipped, so a false "clean" cannot happen. A full backup of the world folder is always created before the first write.

For dedicated servers the world folder lives on the server (`.../Pal/Saved/SaveGames/0/<world>`); run the cleaner there with the server stopped.

## My world already refuses to load

Two options, both work:

- Run the Save Cleaner on it (Path B) - it repairs exactly this case.
- Or reinstall the mod (both halves) and the world loads again immediately. Then do the in-game cleanup and pick a path above.

The backup the cleaner creates, and Palworld's own world backups (`backup` folder inside the world), are your safety nets on top.
