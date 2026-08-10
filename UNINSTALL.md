# Uninstalling Palvolve

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de/palvolve](https://support.doodesch.de/palvolve).

A world that used Palvolve keeps references to the mod's items in places you cannot reach by hand: item stacks in chests, the placed workbench, and crafting records inside each player file. Take the mod's definitions away and those references stop resolving, so the world refuses to load.

The Save Cleaner takes them out: **[palvolve.doodesch.de/save-cleaner](https://palvolve.doodesch.de/save-cleaner)**. It runs in your browser, on the PC where the save lives, and it works on a world that already refuses to load. Nothing below can lose your world.

## Run the Save Cleaner

Close Palworld, then open [palvolve.doodesch.de/save-cleaner](https://palvolve.doodesch.de/save-cleaner) on the PC where the game is installed.

1. Choose the folder that holds your world folders.
2. Pick the world.
3. Read what it found: item stacks, the placed Pal Alchemy Workbench, its work assignment, the crafting records and the technology unlock, each with its own item icon.
4. Start it: "Back up and clean" in Chrome and Edge, "Clean and download" in Firefox and Safari.
5. Start the game and load the world.

Nothing is uploaded. The page reads and writes the save folder on your own PC.

Chrome and Edge copy the world folder first, check the copy against the original by file count and byte total, and write the cleaned files only once that matches. The copy lands inside the world folder as `palvolve-backup-<timestamp>`, and a button hands you the whole backup as a zip for your downloads folder too.

Firefox and Safari cannot write to disk. There you confirm that you copied the world folder yourself, and the cleaned files arrive as a zip to unpack back over the world.

What it changes: item stacks with Palvolve ids become plain Stone at the same stack size, the placed workbench and its work assignment are removed, and Palvolve entries leave each player's crafting records and technology unlocks. `LocalData.sav`, your revealed map, is never touched. Anything it does not recognize is reported instead of skipped, so a false "clean" cannot happen.

After this the world needs nothing from Palvolve on any machine. Measured on a dedicated server: an affected world without UE4SS or PalSchema never finishes loading, and the same world cleaned by this tool autosaves 35 seconds in.

## Two minutes instead: keep the data folder

If you only want the mod switched off and the world stays on this PC:

1. Delete `Pal\Binaries\Win64\ue4ss\Mods\Palvolve` and remove the `Palvolve : 1` line from `ue4ss\Mods\mods.txt`. Workshop users: unsubscribing removes both halves, so put the data folder from point 2 back afterwards.
2. Keep `Pal\Binaries\Win64\ue4ss\Mods\PalSchema\mods\Palvolve` installed. It defines the items so your save stays readable, and does nothing else.

The mod is now disabled. Steam syncs savegames, not mods: after a game reinstall, or on another PC that loads this world, the data folder has to be in place before the world loads. If it is not, the world refuses to load until you put it back or clean the save.

## Dedicated servers

A server's files are not reachable from a browser. `PalvolveSaveCleaner.zip` from the [latest release](https://github.com/DooDesch-Mods/Palworld-Palvolve/releases/latest) does the same job from the command line, with the server stopped; the world folder sits at `.../Pal/Saved/SaveGames/0/<world>`. Steps: [save-cleaner/README.md](save-cleaner/README.md).

## My world already refuses to load

Run the Save Cleaner on it. Reinstalling both halves of the mod also brings the world back, and from there you can pick either path above.

Either way the backup the cleaner writes is there, and so are Palworld's own world backups in the `backup` folder inside the world.
