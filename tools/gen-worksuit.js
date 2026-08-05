// Work-suitability static table generator (v1.8.4).
// Reads the pinned vanilla per-species work-suitability dump
// (tools/data/worksuit-vanilla.json - source URL and vintage are recorded
// inside it) and emits scripts/worksuit_static.lua, the rank source for the
// in-session suitability rebuild at evolve (evolution.lua). Zero runtime
// reads, the saddle-tech pattern: crash #7's session convicted every
// runtime route on this build (the DB's TMap-out read runs clean and
// returns empty; DataTable rows are reflection-dead from Lua).
//
// Keys are exact-cased internal CharacterIDs with no BOSS_ prefix (alphas
// share the base form's ranks - the Lua lookup strips the prefix). Casing
// is canonicalized against elements_static.lua (the roster oracle); dump
// keys that cannot be canonicalized are LISTED and skipped, never guessed
// - a wrongly-cased key would just be dead weight, but listing keeps the
// roster gap visible so it can be closed deliberately.
//
// Usage: node tools/gen-worksuit.js    then reinstall the UE4SS half.
// Re-run only when the game adds species. Map edits do NOT require a
// re-run: the table covers the full roster, not just mapped targets.
const fs = require("fs");
const path = require("path");

const repo = path.resolve(__dirname, "..");
const dataPath = path.join(__dirname, "data", "worksuit-vanilla.json");
const elementsPath = path.join(repo, "Mods", "Palvolve-Fork", "scripts", "elements_static.lua");
const outPath = path.join(repo, "Mods", "Palvolve-Fork", "scripts", "worksuit_static.lua");

// The 13 display-facing suitability names, exactly as evolution.lua's
// SUIT_LABELS spells them (EPalWorkSuitability.h order, ordinals 1..13).
const SUIT_NAMES = new Set([
  "Kindling", "Watering", "Planting", "Electricity", "Handiwork",
  "Gathering", "Lumbering", "Mining", "Oil", "Medicine", "Cooling",
  "Transport", "Farming",
]);

const raw = JSON.parse(fs.readFileSync(dataPath, "utf8"));
const meta = raw.__meta || {};
const species = Object.entries(raw).filter(([k]) => k !== "__meta");
if (species.length < 150) {
  throw new Error("suspiciously small dump (" + species.length + " species) - refusing to emit");
}

// exact-cased ids from the roster oracle
const elSrc = fs.readFileSync(elementsPath, "utf8");
const exactIds = new Map(); // lowercase -> exact
for (const m of elSrc.matchAll(/\["([A-Za-z0-9_]+)"\]\s*=/g)) {
  exactIds.set(m[1].toLowerCase(), m[1]);
}

const rows = new Map(); // exact id -> { suitName: rank }
const unmatched = [];
for (const [id, suits] of species) {
  const exact = exactIds.get(id.toLowerCase());
  if (!exact) { unmatched.push(id); continue; }
  const row = {};
  for (const [name, rank] of Object.entries(suits)) {
    if (!SUIT_NAMES.has(name)) {
      throw new Error(id + ": unknown suitability name '" + name + "' - fix the dump, never guess");
    }
    const rn = Number(rank);
    if (!Number.isInteger(rn)) {
      throw new Error(id + ": non-integer rank " + rank + " for " + name + " - data corruption?");
    }
    const r = rn;
    // 1.0 raised the base-rank ceiling: endgame pals sit at 6-8 (Jetragon
    // Gathering 8, Frostallion Cooling 7, Anubis Handiwork 6...); the game
    // cap is 10. Outside 1..10 = corruption.
    if (!(r >= 1 && r <= 10)) {
      throw new Error(id + ": rank " + rank + " for " + name + " outside 1..10 - data corruption?");
    }
    row[name] = r;
  }
  // empty rows are kept (KingWhale/Panthalus legitimately has ZERO work
  // suitabilities): presence in the table is what authorizes the rebuild
  // to zero a stale rank - absence means "unsourced, do not touch"
  rows.set(exact, row);
}

// Column-presence assertion: a dump that silently drops a whole suitability
// column must not emit. WAIVER for Oil: three independent sources confirm no
// pal has a non-zero base OilExtraction in 1.0 data (PalCalc's generator
// drops the column; palmods.gg's 1.0 work index 2026-07-27 states it; paldb
// shows none even on Dumud). If Oil ranks ever appear they pass normally -
// only the OTHER twelve going empty is a regression.
const seenSuits = new Set();
for (const row of rows.values()) for (const n of Object.keys(row)) seenSuits.add(n);
for (const n of SUIT_NAMES) {
  if (n !== "Oil" && !seenSuits.has(n)) {
    throw new Error("suit column '" + n + "' appears in ZERO rows - dump regression, refusing to emit");
  }
}

const sorted = [...rows.keys()].sort();
const lines = [];
lines.push("-- GENERATED FILE - do not edit by hand. Regenerate: node tools/gen-worksuit.js");
lines.push("-- Vanilla per-species work-suitability base ranks (" + sorted.length + " species).");
lines.push("-- Source: " + (meta.source || "see tools/data/worksuit-vanilla.json") +
  (meta.vintage ? " (" + meta.vintage + ")" : ""));
lines.push("-- Keys = internal CharacterID, exact-cased, no BOSS_ prefix (alphas share");
lines.push("-- the base form's ranks - the evolution.lua lookup strips the prefix).");
lines.push("return {");
for (const id of sorted) {
  const row = rows.get(id);
  const parts = Object.entries(row)
    .sort((a, b) => a[0] < b[0] ? -1 : 1)
    .map(([n, r]) => n + " = " + r);
  lines.push('    ["' + id + '"] = { ' + parts.join(", ") + " },");
}
lines.push("}");
fs.writeFileSync(outPath, lines.join("\n") + "\n", "utf8");

console.log("emitted " + sorted.length + " species -> " + outPath);
console.log("sanity: FairyDragon = " + JSON.stringify(rows.get("FairyDragon") || null)
  + ", FairyDragon_Water = " + JSON.stringify(rows.get("FairyDragon_Water") || null));
if (unmatched.length > 0) {
  console.log("NOT in elements_static roster (skipped, close deliberately): " + unmatched.join(", "));
}
const noData = [...exactIds.values()].filter((e) => !rows.has(e)).sort();
if (noData.length > 0) {
  console.log("roster species with NO dump data (" + noData.length + "): " + noData.join(", "));
}
