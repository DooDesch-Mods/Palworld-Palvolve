// Builds the mod's item icons from the AI-generated masters in
// Workspace/extracted/icon-sources: white background unmixed (glow-safe),
// element variants tinted from the neutral bases, everything resized to
// 256px and written into PalSchema/Palvolve/resources/images.
//
// Sources (any missing one is skipped with a note):
//   evolutionstone.png      colored master
//   adaptionstone_base.png  neutral tintable master
//   essence_base.png        neutral tintable master

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { unmixToFile } from "./unmix-white.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const SOURCES = join(HERE, "..", "..", "Workspace", "extracted", "icon-sources");
const OUT = join(HERE, "..", "PalSchema", "Palvolve", "resources", "images");
const SIZE = 256;

// element tints aligned with the mod/website element palette
const TINTS = {
    normal: "#b9c0cb",
    fire: "#e2622e",
    water: "#4b86dd",
    leaf: "#55b64f",
    electricity: "#e5c435",
    ice: "#8fd8e8",
    earth: "#b3823f",
    dark: "#a04fc8",
    dragon: "#7d63e2",
};

const evo = join(SOURCES, "evolutionstone.png");
if (existsSync(evo)) {
    await unmixToFile(evo, join(OUT, "evolutionstone.png"), { size: SIZE });
} else {
    console.log("skip: evolutionstone.png missing in icon-sources");
}

const adapt = join(SOURCES, "adaptionstone_base.png");
if (existsSync(adapt)) {
    await unmixToFile(adapt, join(OUT, "adaptionstone.png"), { size: SIZE });
    for (const [el, tint] of Object.entries(TINTS)) {
        await unmixToFile(adapt, join(OUT, `adaptionstone_${el}.png`), { size: SIZE, tint });
    }
} else {
    console.log("skip: adaptionstone_base.png missing in icon-sources");
}

const essence = join(SOURCES, "essence_base.png");
if (existsSync(essence)) {
    for (const [el, tint] of Object.entries(TINTS)) {
        await unmixToFile(essence, join(OUT, `essence_${el}.png`), { size: SIZE, tint });
    }
} else {
    console.log("skip: essence_base.png missing in icon-sources");
}
