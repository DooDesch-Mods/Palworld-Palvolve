// Merge the user's web-editor export (NEW) with fork-only fields from the
// previous config_user (OLD). NEW's map is authoritative for edges, levels,
// categories, conditions (incl. deliberate duplicate alt-pairs). Restored on
// top, because the editor (schema 4) cannot express them:
//   - free = true   (per (from,to) match against OLD; all copies of a dup get it;
//                    NEW-only adaptations also get it per the standing policy)
//   - hpBelow:1     (LizardMan->HoodGhost death's-door condition)
//   - materials     (Xeno meteor bills: 30 / 90)
// Tail: NEW's settings + OLD-only keys (statusEvolutions/evolveNotify/techCensus).
// Also reports: added/removed/changed edges, unknown species ids, and pairs
// whose AND-list contains 2+ mutually exclusive regions (likely meant as OR).
//
// Usage: node merge-usermap.js <old.lua> <new.lua> <elements_static.lua> <out.lua>

const fs = require("fs");
const [oldPath, newPath, elemPath, outPath] = process.argv.slice(2);

const lineRe = /^\s*\{ from = "([^"]+)", to = "([^"]+)", category = "([^"]+)", minLevel = (\d+).*?conditions = \{([^}]*)\}|^\s*\{ from = "([^"]+)", to = "([^"]+)", category = "([^"]+)", minLevel = (\d+)/;
const parseMap = (src) => {
    const pairs = [];
    for (const line of src.split(/\r?\n/)) {
        if (!/^\s*\{ from = /.test(line)) continue;
        const from = /from = "([^"]+)"/.exec(line)[1];
        const to = /to = "([^"]+)"/.exec(line)[1];
        const cat = (/category = "([^"]+)"/.exec(line) || [])[1];
        const lvl = parseInt((/minLevel = (\d+)/.exec(line) || [])[1], 10);
        const conds = (/conditions = \{([^}]*)\}/.exec(line) || [, ""])[1]
            .split(",").map(s => s.trim().replace(/^"|"$/g, "")).filter(Boolean);
        const free = /free = true/.test(line);
        pairs.push({ from, to, cat, lvl, conds, free, line });
    }
    return pairs;
};

const oldSrc = fs.readFileSync(oldPath, "utf8");
const newSrc = fs.readFileSync(newPath, "utf8");
const roster = new Set();
for (const m of fs.readFileSync(elemPath, "utf8").matchAll(/\["([A-Za-z0-9_]+)"\]\s*=/g)) roster.add(m[1]);

const oldPairs = parseMap(oldSrc), newPairs = parseMap(newSrc);
const key = (p) => p.from + ">" + p.to;
const oldByKey = new Map();
for (const p of oldPairs) { if (!oldByKey.has(key(p))) oldByKey.set(key(p), []); oldByKey.get(key(p)).push(p); }
const newKeys = new Set(newPairs.map(key));
const oldFree = new Set(oldPairs.filter(p => p.free).map(key));

const REGIONS = new Set(["inCave", "inDesert", "inVolcano", "inSnow", "inGrassland",
    "inForest", "inSakura", "inDarkIsland", "onSkyIsland", "onMushroomIsland",
    "atWorldTree", "onOilrig", "inSanctuary"]);

// --- transform NEW lines ---
const out = [];
const report = { added: [], removed: [], changed: [], unknown: [], regionAnd: [], newCosted: [], freeRestored: 0 };
for (const raw of newSrc.split(/\r?\n/)) {
    if (!/^\s*\{ from = /.test(raw)) { out.push(raw); continue; }
    let line = raw;
    const from = /from = "([^"]+)"/.exec(line)[1];
    const to = /to = "([^"]+)"/.exec(line)[1];
    const k = from + ">" + to;
    const cat = (/category = "([^"]+)"/.exec(line) || [])[1];

    for (const id of [from, to]) if (!roster.has(id)) report.unknown.push(`${k}: unknown id ${id}`);

    const conds = (/conditions = \{([^}]*)\}/.exec(line) || [, ""])[1]
        .split(",").map(s => s.trim().replace(/^"|"$/g, "")).filter(Boolean);
    const regions = conds.filter(c => REGIONS.has(c));
    if (regions.length >= 2) report.regionAnd.push(`${k}: requires ${regions.join(" AND ")} simultaneously`);

    // restore free
    const wasFree = oldFree.has(k);
    const newOnly = !oldByKey.has(k);
    if (wasFree || (newOnly && cat === "adaptation")) {
        if (!/free = true/.test(line)) {
            line = line.replace("enabled = true, ", "enabled = true, free = true, ");
            report.freeRestored++;
        }
    } else if (newOnly && cat === "evolution") {
        report.newCosted.push(k);
    }

    // restore hpBelow:1 on the death's-door edge
    if (k === "LizardMan>HoodGhost" && !/hpBelow/.test(line)) {
        line = line.replace('conditions = { "inCombat"', 'conditions = { "hpBelow:1", "inCombat"');
    }
    // restore Xeno meteor bills
    if (k === "DarkAlien>WhiteAlienDragon" && !/materials/.test(line)) {
        line = line.replace(/(conditions = \{[^}]*\})( \},)/, '$1, materials = { { id = "MeteorDrop", count = 30 } }$2');
    }
    if (k === "WhiteAlienDragon>DarkMechaDragon" && !/materials/.test(line)) {
        line = line.replace(/(conditions = \{[^}]*\})( \},)/, '$1, materials = { { id = "MeteorDrop", count = 90 } }$2');
    }
    out.push(line);
    if (newOnly) report.added.push(`${k} (${cat}, ${(/minLevel = (\d+)/.exec(line) || [])[1]})`);
}
for (const [k, ps] of oldByKey) if (!newKeys.has(k)) report.removed.push(`${k} (${ps[0].cat}, ${ps[0].lvl})`);

// changed edges (same key, different level or conditions) - compare first occurrences
const newByKey = new Map();
for (const p of newPairs) { if (!newByKey.has(key(p))) newByKey.set(key(p), []); newByKey.get(key(p)).push(p); }
for (const [k, olds] of oldByKey) {
    const news = newByKey.get(k);
    if (!news) continue;
    const o = olds[0], n = news[0];
    const oc = o.conds.join("+"), nc = n.conds.join("+");
    if (o.lvl !== n.lvl || (oc !== nc && news.length === 1 && olds.length === 1)) {
        report.changed.push(`${k}: ${o.lvl}${oc ? " [" + oc + "]" : ""} -> ${n.lvl}${nc ? " [" + nc + "]" : ""}${news.length > 1 ? " (+alt)" : ""}`);
    } else if (news.length > 1) {
        report.changed.push(`${k}: gained alt-condition pair(s)`);
    }
}

// --- splice the preserved OLD-only tail keys before the closing brace ---
const TAIL = `    -- evolution info on the pal stats page (fork feature, superseded by the
    -- Palpedia tab but user-preferred ON as a second surface)
    statusEvolutions = { enabled = true },
    -- toast-only prompts (user 2026-07-29): the notice feed renders fine on
    -- this build, so the chat copies are off - the toast is the one surface
    evolveNotify = { chatFallback = false },
    -- census by-value row read CONVICTED of the 933 CTDs - keep the ladder off
    techCensus = false,
`;
let merged = out.join("\n");
merged = merged.replace(/(\n\s*eggFilter = \{ enabled = true \},)/, "\n" + TAIL + "$1");

fs.writeFileSync(outPath, merged, "utf8");

console.log(`OLD ${oldPairs.length} pairs -> NEW ${newPairs.length} pairs; free restored on ${report.freeRestored} lines`);
const dump = (t, a) => { if (a.length) { console.log(`\n${t} (${a.length}):`); a.forEach(x => console.log("  " + x)); } };
dump("ADDED", report.added); dump("REMOVED", report.removed); dump("CHANGED", report.changed);
dump("NEW COSTED EVOLUTIONS (never auto-fire, charge a stone)", report.newCosted);
dump("UNKNOWN IDS", report.unknown);
dump("SUSPECT: multiple regions AND-ed in ONE pair (unsatisfiable?)", report.regionAnd);
console.log("\nwrote: " + outPath);
