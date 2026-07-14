// Dev-side generator: builds the PalSchema JSONs for the element crafting
// chain out of tools/out/fruit_elements.json (run generate-data.mjs first).
//
// Usage: node tools/generate-items.mjs
// Outputs (checked in, deployed with the PalSchema mod):
//   PalSchema/Palvolve/items/palvolve_essences.json        9 essence items
//   PalSchema/Palvolve/items/palvolve_element_stones.json  9 adaptation stones
//   PalSchema/Palvolve/raw/DT_ItemRecipeDataTable.json     fruit + organ recipes
//   PalSchema/Palvolve/translations/{en,de}/items.json     merged name/desc keys

import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCHEMA = join(HERE, "..", "PalSchema", "Palvolve");
const fruits = JSON.parse(readFileSync(join(HERE, "out", "fruit_elements.json"), "utf8"));

const ELEMENTS = ["Normal", "Fire", "Water", "Leaf", "Electricity", "Ice", "Earth", "Dark", "Dragon"];

const EN = {
    Normal: "Neutral", Fire: "Fire", Water: "Water", Leaf: "Grass",
    Electricity: "Electric", Ice: "Ice", Earth: "Ground", Dark: "Dark", Dragon: "Dragon",
};
const DE = {
    Normal: "Neutral", Fire: "Feuer", Water: "Wasser", Leaf: "Gras",
    Electricity: "Elektro", Ice: "Eis", Earth: "Boden", Dark: "Dunkel", Dragon: "Drachen",
};
const DE_ESSENCE = {
    Normal: "Neutralessenz", Fire: "Feueressenz", Water: "Wasseressenz",
    Leaf: "Grasessenz", Electricity: "Elektroessenz", Ice: "Eisessenz",
    Earth: "Bodenessenz", Dark: "Dunkelessenz", Dragon: "Drachenessenz",
};

// 10x organ/gland -> 1 essence; elements without a gland use the closest
// fitting vanilla drop (Wool/Berries/Horn)
const ORGANS = {
    Fire: "FireOrgan", Electricity: "ElectricOrgan", Ice: "IceOrgan",
    Water: "PalFluid", Dark: "Venom", Earth: "Bone",
    Normal: "Wool", Leaf: "Berries", Dragon: "Horn",
};

const essenceId = (el) => `Palvolve_Essence_${el}`;
const stoneId = (el) => `Palvolve_AdaptationStone_${el}`;

// element icon variants exist once build-icons.mjs has processed the
// corresponding master; fall back to the neutral icon until then
const resourceIcon = (name, fallback) =>
    existsSync(join(SCHEMA, "resources", "images", `${name}.png`))
        ? `$resource/Palvolve/${name}`
        : fallback;

// ---------------------------------------------------------------- items
{
    const essences = {};
    const stones = {};
    ELEMENTS.forEach((el, i) => {
        essences[essenceId(el)] = {
            Type: "Generic",
            Name: `${EN[el]} Essence`,
            Description: `Concentrated ${EN[el].toLowerCase()} energy, extracted from skill fruits or elemental materials. Used to craft the matching Adaptation Stone.`,
            IconTexture: resourceIcon(`essence_${el.toLowerCase()}`, "$resource/Palvolve/adaptionstone"),
            TypeA: "Material",
            // custom TypeB (PalSchema enum extension) binds the recipes
            // exclusively to the Element Extractor bench - no vanilla
            // converter lists this type
            TypeB: "Palvolve_Craft",
            Rank: 2,
            Rarity: 2,
            Price: 1500,
            MaxStackCount: 99,
            SortID: 999010 + i,
            Weight: 0.5,
        };
        stones[stoneId(el)] = {
            Type: "Generic",
            Name: `Adaptation Stone (${EN[el]})`,
            Description: `A shimmering stone attuned to ${EN[el].toLowerCase()} energy. Lets a bonded Pal adapt into its ${EN[el].toLowerCase()} form once it has reached the required level.`,
            IconTexture: resourceIcon(`adaptionstone_${el.toLowerCase()}`, "$resource/Palvolve/adaptionstone"),
            TypeA: "Material",
            TypeB: "Palvolve_Craft",
            Rank: 2,
            Rarity: 3,
            Price: 5000,
            MaxStackCount: 99,
            SortID: 999030 + i,
            Weight: 1.0,
            Recipe: {
                Product_Count: 1,
                WorkAmount: 300.0,
                Material1_Id: "Palvolve_EvolutionStone",
                Material1_Count: 1,
                Material2_Id: essenceId(el),
                Material2_Count: 1,
            },
        };
    });
    writeFileSync(join(SCHEMA, "items", "palvolve_essences.json"), JSON.stringify(essences, null, 4) + "\n");
    writeFileSync(join(SCHEMA, "items", "palvolve_element_stones.json"), JSON.stringify(stones, null, 4) + "\n");
    console.log(`items: ${ELEMENTS.length} essences + ${ELEMENTS.length} stones`);
}

// ---------------------------------------------------------------- recipes (raw)
{
    const rows = {};
    // skill fruit decomposition, 1:1 into the fruit's element essence
    for (const [fruit, el] of Object.entries(fruits).sort()) {
        rows[`Palvolve_Decompose_${fruit.replace("SkillCard_", "")}`] = {
            Product_Id: essenceId(el),
            Product_Count: 1,
            WorkAmount: 100.0,
            Material1_Id: fruit,
            Material1_Count: 1,
        };
    }
    // material extraction: 10x vanilla drop per element
    for (const [el, organ] of Object.entries(ORGANS)) {
        rows[`Palvolve_Extract_${el}`] = {
            Product_Id: essenceId(el),
            Product_Count: 1,
            WorkAmount: 200.0,
            Material1_Id: organ,
            Material1_Count: 10,
        };
    }
    mkdirSync(join(SCHEMA, "raw"), { recursive: true });
    writeFileSync(
        join(SCHEMA, "raw", "DT_ItemRecipeDataTable.json"),
        JSON.stringify({ DT_ItemRecipeDataTable: rows }, null, 4) + "\n"
    );
    console.log(`recipes: ${Object.keys(rows).length} rows (fruits + organs)`);
}

// ---------------------------------------------------------------- translations
{
    for (const lang of ["en", "de"]) {
        const file = join(SCHEMA, "translations", lang, "items.json");
        const j = JSON.parse(readFileSync(file, "utf8"));
        const names = j.DT_ItemNameText;
        const descs = j.DT_ItemDescriptionText;
        for (const el of ELEMENTS) {
            if (lang === "en") {
                names[`ITEM_NAME_${essenceId(el)}`] = `${EN[el]} Essence`;
                descs[`ITEM_DESC_${essenceId(el)}`] =
                    `Concentrated ${EN[el].toLowerCase()} energy, extracted from skill fruits or elemental materials. Used to craft the matching Adaptation Stone.`;
                names[`ITEM_NAME_${stoneId(el)}`] = `Adaptation Stone (${EN[el]})`;
                descs[`ITEM_DESC_${stoneId(el)}`] =
                    `A shimmering stone attuned to ${EN[el].toLowerCase()} energy. Lets a bonded Pal adapt into its ${EN[el].toLowerCase()} form once it has reached the required level.`;
            } else {
                names[`ITEM_NAME_${essenceId(el)}`] = DE_ESSENCE[el];
                descs[`ITEM_DESC_${essenceId(el)}`] =
                    `Konzentrierte ${DE[el]}-Energie, gewonnen aus Technikfrüchten oder elementaren Materialien. Wird für den passenden Adaptionsstein benötigt.`;
                names[`ITEM_NAME_${stoneId(el)}`] = `Adaptionsstein (${DE[el]})`;
                descs[`ITEM_DESC_${stoneId(el)}`] =
                    `Ein schimmernder Stein voller ${DE[el]}-Energie. Erlaubt einem verbundenen Pal den Wechsel in seine ${DE[el]}-Form, sobald es das nötige Level erreicht hat.`;
            }
        }
        writeFileSync(file, JSON.stringify(j, null, 4) + "\n");
    }
    console.log("translations: en/de updated");
}
