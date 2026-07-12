# Palvolve

Evolve your captured Pals into stronger related forms - Pengullet becomes Penking, Swee becomes Sweepa (and maybe even Wumpo). Your Pal keeps its full identity: level, nickname, gender, passive skills, IVs, souls, condenser rank and even its learned moves.

> 🛟 **Need help or found a bug?** Get support at [support.doodesch.de](https://support.doodesch.de).

## Features

- Evolution chains (e.g. Pengullet -> Penking, Swee -> Sweepa -> Wumpo) and element adaptations (e.g. Mau -> Mau Cryst), curated and config-driven.
- Triggered by you, never automatically: reach the level threshold, craft the required stone, summon your Pal and confirm with a keybind.
- Everything individual carries over, including moves the target species could never learn - builds vanilla cannot have.
- +5 to all IV talents per evolution stage (capped at 100).
- Transactional and safe: every evolution snapshots the Pal first; `palvolve rollback last` restores it.

## Installation

- **Steam Workshop (empfohlen):** abonnieren, dann im Spiel Options > Mod Management aktivieren.
- **Manuell (UE4SS):** Ordner `Palvolve` mit `scripts\main.lua` nach
  `<Palworld>\Pal\Binaries\Win64\ue4ss\Mods\` kopieren und in `ue4ss\Mods\mods.txt`
  die Zeile `Palvolve : 1` ergänzen (vor dem Keybinds-Eintrag).

## Kompatibilität

- Palworld-Version: 1.0 (buildid 24088745)
- Benötigt UE4SS (Palworld-Build); im Workshop als Abhängigkeit verlinkt.
- Singleplayer und Co-op-Host. Dedicated Server werden nicht unterstützt (UE4SS läuft dort nicht).
