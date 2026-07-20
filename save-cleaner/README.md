# Palvolve Save Cleaner

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de](https://support.doodesch.de).

Removes every Palvolve trace from a Palworld world save, so the world loads on a machine that has no Palvolve installed - or never had it. The full uninstall guide, including the simpler keep-the-data-folder path, is [UNINSTALL.md](../UNINSTALL.md).

## When you need this

A world that used Palvolve keeps references to the mod's items in its save files: item stacks in chests, the placed workbench, and crafting statistics inside each player file. Without the mod's item definitions those references stop resolving and the world refuses to load. That hits you when you uninstall the mod completely, reinstall the game (Steam syncs saves, not mods), or move to another PC.

The in-game command `/palvolve uninstall` cleans what a running game can reach. This tool cleans what it cannot: the crafting statistics, stacks in containers whose chest no longer exists, and a placed workbench on a save you can no longer open.

## Usage

1. Close Palworld.
2. Download `PST_standalone_*.7z` from [PalworldSaveTools releases](https://github.com/deafdudecomputers/PalworldSaveTools/releases/latest) and extract it into this folder as `PalworldSaveTools` (this provides the save file codec).
3. Double-click `run-cleaner.bat`. It fetches a private Python runtime on first use, lists your worlds, shows what it would change (dry run), and only writes after you confirm.
4. Start the game and load the world.

Before anything is written, always and automatically, a full copy of the world folder is created next to it (`<world>.palvolve-backup-<timestamp>`) - the write routine refuses to run without it. If anything looks wrong afterwards, delete the world folder and rename the backup back.

## What it changes

- Item stacks with Palvolve ids become plain Stone (same stack size).
- Placed Pal Alchemy Workbenches and their work assignments are removed.
- Palvolve entries in each player's crafting statistics and technology unlocks are removed.
- `LocalData.sav` is never touched - it carries your revealed map, and a stale reference inside it is harmless. If an earlier cleaner version set it aside and cost you the map, running the cleaner again restores it.

Anything it does not recognize is reported instead of skipped silently - if you see an `UNRESOLVED reference` line, please send it to support.

## Command line

```
python palvolve_save_cleaner.py <world-folder>          # dry run
python palvolve_save_cleaner.py <world-folder> --apply  # write (backup first)
```

Requires Python 3.12 and the PalworldSaveTools standalone package (`PST_LIB` may point at its `lib` folder). Works on the save format of Palworld 1.0 (PlM1).
