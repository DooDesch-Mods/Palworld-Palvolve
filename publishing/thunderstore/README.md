# Palvolve

Evolution for Palworld as a moment you choose: pick the target in the radial menu, watch the staged transformation, and your Pal keeps its identity and learned progress.

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de](https://support.doodesch.de).

## What it does

- **99 curated transformations** as the starting point: evolution chains (Pengullet to Penking), fun chains (Mau to Sekhmet) and 87 element adaptations (Penking to Penking Lux).
- **Conditional evolutions:** pairs can require day/night, standing in water, status effects like electrified or frozen, locations from caves to wildlife sanctuaries, gender, a known move element, a specific Pal in your party, gliding, your own base or mid-combat. Same Pal, different evolutions by day and night; greyed options name what is still missing, in your language (17 supported).
- **Your tree, not ours:** rewire pairs, levels and conditions in the interactive [web configurator](https://palvolve.doodesch.de), share your tree as a short link and download the finished config.
- **Preserves identity and progress:** level, nickname, gender, passives, IVs, souls, condenser rank and every learned move carry over.
- **Earned, not free:** stone costs via the buildable Pal Alchemy Workbench (essences, Evolution Stones, element Adaptation Stones); eggs keep hatching base forms.
- **Rollback, refunds and server validation:** every evolution is snapshotted first; the chat command `/palvolve rollback` restores the previous form from that snapshot. Aborted transformations refund their costs. On dedicated servers the server validates ownership, level, costs and conditions.

## Requirements

- UE4SS Experimental (Palworld) and PalSchema - follow the [PalSchema installation guide](https://okaetsu.github.io/PalSchema/docs/installation), which pairs the correct UE4SS build. Do not use the generic upstream RE-UE4SS.

## Notes

- Tested with Palworld 1.0 build 619; singleplayer, co-op and dedicated servers.
- Known limitation: on dedicated servers the final reveal effects do not render on the client yet; the evolution itself completes correctly.
- Demolish placed Pal Alchemy Workbenches before uninstalling (game-side limitation).
- Never use mods on official servers. Source: [GitHub](https://github.com/DooDesch-Mods/Palworld-Palvolve)

## Dedicated servers

The technology unlock is validated by the server, so the server needs the mod running too - subscribing on the client alone is not enough. Symptom of a missing server half: the workbench relocks every time you reopen the technology tree.

1. Install UE4SS Experimental (Palworld) manually on the server (proxy dll next to the server binary) - the server does not start UE4SS through the Workshop mod loader.
2. Install PalSchema on the server, following its [installation guide](https://okaetsu.github.io/PalSchema/docs/installation).
3. Install Palvolve from the GitHub release zip: both folders inside the zip go into `Pal\Binaries\Win64\ue4ss\Mods\`. Do not copy the Workshop item folder onto a server - its layout is for the game's own loader.
4. Add `Palvolve : 1` to `ue4ss\Mods\mods.txt` and restart the server.
5. Check the server's UE4SS.log for: `[PalSchema] Added building 'Palvolve_ElementExtractor'`
6. Profit.

Players keep using the normal Workshop version - nothing extra is needed client-side.
