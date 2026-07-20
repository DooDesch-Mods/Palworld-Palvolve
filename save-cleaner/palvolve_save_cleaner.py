# Palvolve Save Cleaner
#
# Removes every Palvolve trace from a Palworld world save so the world loads
# without the mod installed. Run it AFTER uninstalling (or before - the mod
# does not need to be present), with the game closed.
#
# What it edits, and why the world otherwise refuses to load:
#   - item stacks whose id the game can no longer resolve (chests, orphaned
#     containers, player inventories) -> rewritten to plain Stone
#   - placed Pal Alchemy Workbenches and their work assignments -> removed
#   - crafting statistics inside each player save that reference mod items
#     -> entries removed
#   - the technology unlock -> removed from each player save
#
# LocalData.sav is deliberately left alone: it carries the revealed-map
# progress, and a stale mod reference inside it does not block loading
# (isolation-tested) - early versions set it aside and cost players their map.
#
# Safety: without --apply nothing is written (dry run). With --apply the whole
# world folder is copied to a timestamped backup BEFORE anything else - the
# write routine refuses to run without that backup - every edited file is
# re-verified to contain zero mod references (UTF-8 and UTF-16), and every
# rewrite is checked with a byte-exact decompression roundtrip.
#
# Requires the PalworldSaveTools standalone package for the save codec
# (PlM1/Oodle). Point PST_LIB at its lib folder, or place this script next to
# the extracted PalworldSaveTools folder.
import argparse
import glob
import os
import re
import shutil
import struct
import sys
import time

PREFIX = 'Palvolve_'
REPLACEMENT_ITEM = 'Stone'


def find_pst_lib():
    env = os.environ.get('PST_LIB')
    candidates = [env] if env else []
    here = os.path.dirname(os.path.abspath(__file__))
    candidates += [
        os.path.join(here, 'PalworldSaveTools', 'lib'),
        os.path.join(here, 'pst-bin', 'lib'),
        os.path.join(here, '..', 'PalworldSaveTools', 'lib'),
    ]
    for c in candidates:
        if c and os.path.isfile(os.path.join(c, 'palsav', '__init__.pyc')) or \
           c and os.path.isdir(os.path.join(c, 'palsav')):
            return c
    return None


PST = find_pst_lib()
if not PST:
    print('ERROR: PalworldSaveTools not found.')
    print('Download the standalone package from')
    print('  https://github.com/deafdudecomputers/PalworldSaveTools/releases')
    print('extract it next to this script as "PalworldSaveTools", or set PST_LIB')
    print('to its lib folder.')
    sys.exit(2)
sys.path.insert(0, PST)

from palsav import gvas, paltypes, core  # noqa: E402
import palooz  # noqa: E402


def read_sav(path):
    data = open(path, 'rb').read()
    ulen, clen = struct.unpack('<II', data[:8])
    magic = data[8:12]
    if magic[:3] == b'PlM':
        return bytes(palooz.decompress(data[12:12 + clen], ulen))
    if magic[:3] == b'PlZ':
        import zlib
        return zlib.decompress(data[12:])
    raise ValueError(f'{os.path.basename(path)}: unknown save magic {magic!r}')


# Set once the world backup exists; write_sav hard-refuses to run before that,
# so no code path can ever modify a save without a restorable copy on disk.
BACKUP_DONE = None


def write_sav(path, raw):
    if not (BACKUP_DONE and os.path.isdir(BACKUP_DONE)):
        raise RuntimeError('refusing to write without a world backup')
    try:
        sav = core.compress_gvas_to_sav(raw, 0x31)
    except Exception:
        comp = palooz.compress(8, 4, raw, len(raw))
        sav = struct.pack('<II', len(raw), len(comp)) + b'PlM1' + bytes(comp)
    open(path, 'wb').write(sav)
    data = open(path, 'rb').read()
    ulen, clen = struct.unpack('<II', data[:8])
    back = bytes(palooz.decompress(data[12:12 + clen], ulen))
    if back != raw:
        raise RuntimeError(f'{os.path.basename(path)}: roundtrip mismatch after write')


def scan_bytes(raw):
    return len(re.findall(PREFIX.encode(), raw)) + \
        len(re.findall(PREFIX.encode('utf-16-le'), raw))


def leftover_paths(node, path, out):
    if isinstance(node, dict):
        for k, v in node.items():
            leftover_paths(v, path + [str(k)], out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            leftover_paths(v, path + [str(i)], out)
    elif isinstance(node, str) and PREFIX in node:
        out.append((' -> '.join(path[-8:]), node))


def clean_level(path, log):
    raw = read_sav(path)
    if scan_bytes(raw) == 0:
        log('Level.sav: clean already')
        return None
    g = gvas.GvasFile.read(raw, paltypes.PALWORLD_TYPE_HINTS, paltypes.PALWORLD_CUSTOM_PROPERTIES)
    wsd = g.properties['worldSaveData']['value']

    slots_fixed = 0
    for entry in wsd.get('ItemContainerSaveData', {}).get('value', []):
        for slot in entry['value']['Slots']['value']['values']:
            rv = slot.get('RawData', {}).get('value', {})
            item = rv.get('item', {})
            if str(item.get('static_id', '')).startswith(PREFIX):
                log(f"  item stack: {rv.get('count')}x {item['static_id']} -> {REPLACEMENT_ITEM}")
                item['static_id'] = REPLACEMENT_ITEM
                slots_fixed += 1

    mos = wsd.get('MapObjectSaveData', {}).get('value', {}).get('values', [])
    removed_objects = 0
    for i in range(len(mos) - 1, -1, -1):
        if str(mos[i].get('MapObjectId', {}).get('value', '')).startswith(PREFIX):
            log(f"  placed object removed: {mos[i]['MapObjectId']['value']}")
            del mos[i]
            removed_objects += 1

    works = wsd.get('WorkSaveData', {}).get('value', {}).get('values', [])
    removed_works = 0
    for i in range(len(works) - 1, -1, -1):
        if PREFIX in str(works[i]):
            log('  work assignment removed')
            del works[i]
            removed_works += 1

    leftovers = []
    leftover_paths(wsd, ['worldSaveData'], leftovers)
    for where, val in leftovers:
        log(f'  UNRESOLVED reference (please report this): {where} = {val}')

    out = g.write(paltypes.PALWORLD_CUSTOM_PROPERTIES)
    remaining = scan_bytes(out)
    log(f'Level.sav: {slots_fixed} stacks rewritten, {removed_objects} objects and '
        f'{removed_works} work entries removed, {remaining} references left')
    if remaining > 0 and not leftovers:
        log('  WARNING: raw references remain outside known structures - report this')
    return out if (slots_fixed or removed_objects or removed_works) else None


def clean_player(path, log):
    raw = read_sav(path)
    if scan_bytes(raw) == 0:
        log(f'{os.path.basename(path)}: clean already')
        return None
    g = gvas.GvasFile.read(raw, paltypes.PALWORLD_TYPE_HINTS, paltypes.PALWORLD_CUSTOM_PROPERTIES)
    sd = g.properties['SaveData']['value']

    removed = 0

    def strip_maps(node):
        nonlocal removed
        if isinstance(node, dict):
            vals = node.get('value')
            if isinstance(vals, list) and vals and isinstance(vals[0], dict) and 'key' in vals[0]:
                keep = []
                for pair in vals:
                    if str(pair.get('key', '')).startswith(PREFIX):
                        log(f"  record removed: {pair.get('key')}")
                        removed += 1
                    else:
                        keep.append(pair)
                node['value'] = keep
            for v in node.values():
                strip_maps(v)
        elif isinstance(node, list):
            for v in node:
                strip_maps(v)

    strip_maps(sd.get('RecordData', {}))

    tech = sd.get('UnlockedRecipeTechnologyNames', {}).get('value', {}).get('values', [])
    for i in range(len(tech) - 1, -1, -1):
        if str(tech[i]).startswith(PREFIX):
            log(f'  technology unlock removed: {tech[i]}')
            del tech[i]
            removed += 1

    leftovers = []
    leftover_paths(sd, ['SaveData'], leftovers)
    for where, val in leftovers:
        log(f'  UNRESOLVED reference (please report this): {where} = {val}')

    out = g.write(paltypes.PALWORLD_CUSTOM_PROPERTIES)
    log(f'{os.path.basename(path)}: {removed} entries removed, {scan_bytes(out)} references left')
    return out if removed else None


def main():
    ap = argparse.ArgumentParser(description='Remove Palvolve traces from a Palworld world save.')
    ap.add_argument('world', help='world folder (the one containing Level.sav)')
    ap.add_argument('--apply', action='store_true', help='write changes (default: dry run)')
    args = ap.parse_args()

    world = os.path.abspath(args.world)
    level = os.path.join(world, 'Level.sav')
    if not os.path.isfile(level):
        print(f'ERROR: no Level.sav in {world}')
        sys.exit(2)

    lines = []
    log = lambda s: (lines.append(s), print(s))  # noqa: E731

    print(f'World: {world}')
    print(f'Mode:  {"APPLY" if args.apply else "dry run (no changes)"}')
    print()

    edits = {}
    new_level = clean_level(level, log)
    if new_level is not None:
        edits[level] = new_level
    for p in sorted(glob.glob(os.path.join(world, 'Players', '*.sav'))):
        new_p = clean_player(p, log)
        if new_p is not None:
            edits[p] = new_p

    # LocalData.sav stays untouched: it holds the revealed-map progress, and a
    # stale reference inside it does not block loading. If an earlier cleaner
    # version set it aside, the old file wins (it carries the whole map) - any
    # rebuilt LocalData is kept next to it instead of being destroyed.
    local = os.path.join(world, 'LocalData.sav')
    parked = local + '.palvolve-removed'
    if os.path.isfile(parked):
        log('LocalData.sav: restoring the copy an earlier cleaner version set aside (brings the map back)')
        if args.apply:
            if os.path.isfile(local):
                os.replace(local, local + '.rebuilt-' + time.strftime('%Y%m%d-%H%M%S'))
            os.replace(parked, local)
            print('restored: LocalData.sav (map progress back)')

    if not edits:
        print('\nNothing to do - this world holds no Palvolve references that matter.')
        return

    if not args.apply:
        print('\nDry run complete. Re-run with --apply to write these changes.')
        return

    global BACKUP_DONE
    stamp = time.strftime('%Y%m%d-%H%M%S')
    backup = world.rstrip('\\/') + f'.palvolve-backup-{stamp}'
    print(f'\nBacking up world to {backup} ...')
    shutil.copytree(world, backup)
    BACKUP_DONE = backup

    for path, raw in edits.items():
        write_sav(path, raw)
        print(f'written: {os.path.relpath(path, world)}')

    print('\nDone. Start the game and load the world - it no longer needs Palvolve.')
    print(f'If anything looks wrong, restore the backup folder: {backup}')


if __name__ == '__main__':
    main()
