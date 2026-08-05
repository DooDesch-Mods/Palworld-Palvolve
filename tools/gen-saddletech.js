// Saddle-tech sync generator (v1.8.0).
// Reads the user's evolution map (config_user.lua), computes each species'
// reachability floor (the wildfilter fixpoint: floor(to) = min over enabled
// in-edges of max(floor(from), minLevel); roots = 0), and emits a PalSchema
// raw-table override that moves every mapped species' SkillUnlock tech to
// its floor - strict coincide, element variants included (user rulings
// 2026-07-29). Only rows in KNOWN_GEAR are emitted: PalSchema's raw loader
// UPSERTS, and inventing a row for a species with no gear tech would plant
// a broken node in the tech tree. Mapped targets skipped for that reason
// are listed so the known-gear set can be extended deliberately.
//
// Usage: node tools/gen-saddletech.js
//   (paths are resolved relative to this script / LOCALAPPDATA)
// Re-run whenever the map changes, then reinstall the data half.
const fs = require("fs");
const path = require("path");

const repo = path.resolve(__dirname, "..");
const mapPath = path.join(process.env.LOCALAPPDATA, "Pal", "Saved", "Palvolve", "config_user.lua");
const elementsPath = path.join(repo, "Mods", "Palvolve-Fork", "scripts", "elements_static.lua");
const outPath = path.join(repo, "Mods", "PalSchema", "mods", "Palvolve-Fork", "raw", "palvolve_saddletech.jsonc");

// SkillUnlock_<id> rows confirmed to exist (lowercased id part), from the
// community technology index (palworld.th.gl, 2026-07-29). Extend as more
// are confirmed; never emit outside this set.
const KNOWN_GEAR = new Set(("boar kitsunebi kitsunebi_ice garm alpaca weaseldragon weaseldragon_fire carbunclo " +
  "monkey monkey_fire deer deer_ground kirin birddragon serpent colorfulbird penguin penguin_electric " +
  "hawkbird flamebuffalo naughtycat kingalpaca fairydragon purplespider mopking bluedragon bluedragon_ice " +
  "flowerdinosaur iceseal fengyundeeper thunderdog hadesbird icedragon featherostrich grassmammoth firekirin " +
  "thunderbird ghostanglerfish icedeer manticore redarmorbird sakurasaurus bluethunderhorse icehorse " +
  "icehorse_dark poseidonorca kingsunfish kingsunfish_thunder thunderfluffybird darkmechadragon ghostdragon " +
  "ghostdragon_fire legenddeer snowtigerbeastman cubeturtle cubeturtle_neutral volcanodragon volcanodragon_ice " +
  "sumodog thiefbird blueskydragon lotusdragon whitedeer whitedeer_dark domearmordragon jetdragon goldenhorse " +
  "nightbluehorse nightbluehorse_neutral amaterasuwolf amaterasuwolf_dark horus horus_water whiteshielddragon " +
  "saintcentaur blackcentaur umihebi umihebi_fire plesiosaur blackmetaldragon mushroomdragon mushroomdragon_dark " +
  "suzaku suzaku_water volcanicmonster volcanicmonster_ice skydragon skydragon_grass icenarwhal icenarwhal_fire " +
  "kingbahamut kingbahamut_dragon grassgolem_dark " +
  // individually probed 2026-07-29 (missing from the index summarize):
  "fairydragon_water birddragon_ice " +
  // probed 2026-07-30 (paldb Maraith_Saddle page: SkillUnlock_GhostBeast, tech 37):
  "ghostbeast").split(/\s+/));

// --- parse the map ---
const mapSrc = fs.readFileSync(mapPath, "utf8");
// the skip between minLevel and enabled tolerates ONE nesting level of braces
// (conditions = {...}, anyOf = {...}) but still cannot cross the pair's own
// closing brace - a table-valued field before `enabled` no longer silently
// drops the edge
const edgeRe = /\{\s*from\s*=\s*"([^"]+)"\s*,\s*to\s*=\s*"([^"]+)"\s*,\s*category\s*=\s*"([^"]+)"\s*,\s*minLevel\s*=\s*(\d+)(?:[^{}]|\{[^{}]*\})*?enabled\s*=\s*(true|false)/g;
const edges = [];
let m;
while ((m = edgeRe.exec(mapSrc)) !== null) {
  if (m[5] === "true" && m[3] !== "funchain") {
    edges.push({ from: m[1], to: m[2], minLevel: parseInt(m[4], 10) });
  }
}
if (edges.length === 0) throw new Error("no enabled map edges parsed from " + mapPath);

// --- exact-cased species ids from the roster oracle ---
const elSrc = fs.readFileSync(elementsPath, "utf8");
const exactIds = new Map(); // lowercase -> exact
for (const mm of elSrc.matchAll(/\["([A-Za-z0-9_]+)"\]\s*=/g)) {
  exactIds.set(mm[1].toLowerCase(), mm[1]);
}

// --- floors: Kleene fixpoint, roots at 0 ---
const floors = new Map(); // species -> floor (targets only)
const species = new Set();
for (const e of edges) { species.add(e.from); species.add(e.to); }
const floorOf = (s) => (floors.has(s) ? floors.get(s) : 0); // non-target = root = 0
let changed = true, iter = 0;
while (changed && ++iter < 200) {
  changed = false;
  // FULL recompute each round (fixed 2026-07-30): the min must be
  // re-derived from CURRENT parent floors every iteration. The old
  // only-lower update could never RAISE a child whose first estimate came
  // from a stale root-0 parent - the first level INVERSION in the map
  // (WeaselDragon->FairyDragon at 33 landing above FairyDragon->Water's
  // begin at 30) left Aqua's floor at 30 instead of 33.
  const next = new Map();
  for (const e of edges) {
    const cand = Math.max(floorOf(e.from), e.minLevel);
    const cur = next.get(e.to);
    next.set(e.to, cur === undefined ? cand : Math.min(cur, cand));
  }
  for (const [sp, f] of next) {
    if (floors.get(sp) !== f) { floors.set(sp, f); changed = true; }
  }
}
if (iter >= 200) console.warn("WARN: floor fixpoint did not settle in 200 iterations (cyclic map?)");

// --- emit ---
const rows = {};
const emitted = [], skipped = [], unknownId = [];
for (const [sp, floor] of [...floors.entries()].sort((a, b) => a[1] - b[1] || a[0].localeCompare(b[0]))) {
  const lc = sp.toLowerCase();
  const exact = exactIds.get(lc) || sp;
  if (!exactIds.has(lc)) unknownId.push(sp);
  if (KNOWN_GEAR.has(lc)) {
    rows["SkillUnlock_" + exact] = { LevelCap: floor };
    emitted.push(`${exact} -> ${floor}`);
  } else {
    skipped.push(`${exact} (floor ${floor})`);
  }
}

const header =
  "// GENERATED by tools/gen-saddletech.js - do not hand-edit; re-run after map changes.\n" +
  "// Saddle/gear techs move to the level their species first becomes reachable\n" +
  "// per the user's evolution map (strict coincide, variants included).\n" +
  `// Generated ${new Date().toISOString()} from ${edges.length} enabled edges; ` +
  `${emitted.length} techs moved, ${skipped.length} mapped targets without a confirmed gear tech.\n`;
fs.writeFileSync(outPath, header + JSON.stringify({ DT_TechnologyRecipeUnlock: rows }, null, 2) + "\n");

console.log(`edges parsed: ${edges.length}`);
console.log(`targets with floors: ${floors.size}`);
console.log(`EMITTED (${emitted.length}):`);
for (const e of emitted) console.log("  " + e);
console.log(`SKIPPED - no confirmed gear tech (${skipped.length}):`);
for (const s of skipped) console.log("  " + s);
if (unknownId.length) console.log(`WARN - not in elements_static roster: ${unknownId.join(", ")}`);
console.log(`wrote: ${outPath}`);
