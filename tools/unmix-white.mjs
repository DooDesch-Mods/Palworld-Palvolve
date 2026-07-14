// Removes a white background from AI-generated item art while preserving
// soft glows: every pixel is treated as artwork composited over white, the
// white share becomes transparency (alpha = 1 - min(R,G,B)) and the original
// color is un-mixed back out. Pixels inside the opaque body (found via a
// flood fill of the near-white region from the borders) stay fully opaque so
// bright in-body highlights don't turn into holes.
//
// Usage: node tools/unmix-white.mjs <input.png> <output.png> [--tint #rrggbb]
// With --tint, the unmixed result is recolored (grayscale luminance times
// tint, whites stay white) - used to derive element variants from a neutral
// base icon.

import { pathToFileURL } from "node:url";
import sharp from "sharp";

/** unmixes a white background out of the image; optional element tint */
export async function unmixWhite(input, tint = null) {
    const { data, info } = await sharp(input)
        .ensureAlpha()
        .raw()
        .toBuffer({ resolveWithObject: true });
    const { width, height } = info;

// flood fill the near-white background from the image borders; everything
// not reached is "inside" the artwork body
const NEARLY_WHITE = 242;
const isNearWhite = (i) =>
    data[i * 4] >= NEARLY_WHITE && data[i * 4 + 1] >= NEARLY_WHITE && data[i * 4 + 2] >= NEARLY_WHITE;

const outside = new Uint8Array(width * height);
const stack = [];
for (let x = 0; x < width; x++) {
    stack.push(x, (height - 1) * width + x);
}
for (let y = 0; y < height; y++) {
    stack.push(y * width, y * width + width - 1);
}
while (stack.length) {
    const i = stack.pop();
    if (outside[i] || !isNearWhite(i)) continue;
    outside[i] = 1;
    const x = i % width;
    if (x > 0) stack.push(i - 1);
    if (x < width - 1) stack.push(i + 1);
    if (i >= width) stack.push(i - width);
    if (i < width * (height - 1)) stack.push(i + width);
}

// grow the outside region a little so soft edges are treated as glow
const dilated = new Uint8Array(outside);
const GROW = 6;
for (let pass = 0; pass < GROW; pass++) {
    const prev = new Uint8Array(dilated);
    for (let y = 1; y < height - 1; y++) {
        for (let x = 1; x < width - 1; x++) {
            const i = y * width + x;
            if (prev[i]) continue;
            if (prev[i - 1] || prev[i + 1] || prev[i - width] || prev[i + width]) dilated[i] = 1;
        }
    }
}

const tintRgb = tint
    ? [parseInt(tint.slice(1, 3), 16), parseInt(tint.slice(3, 5), 16), parseInt(tint.slice(5, 7), 16)]
    : null;

for (let i = 0; i < width * height; i++) {
    const o = i * 4;
    let r = data[o];
    let g = data[o + 1];
    let b = data[o + 2];

    if (dilated[i]) {
        // background / glow zone: unmix against white
        const alpha = 255 - Math.min(r, g, b);
        if (alpha === 0) {
            data[o + 3] = 0;
            continue;
        }
        const a = alpha / 255;
        r = Math.min(255, Math.round((r - 255 * (1 - a)) / a));
        g = Math.min(255, Math.round((g - 255 * (1 - a)) / a));
        b = Math.min(255, Math.round((b - 255 * (1 - a)) / a));
        data[o + 3] = alpha;
    } else {
        data[o + 3] = 255;
    }

    if (tintRgb) {
        // luminance-driven recolor: dark stays dark, highlights stay white
        const lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
        const lift = Math.max(0, lum - 0.82) / 0.18;
        r = Math.round((tintRgb[0] * lum) * (1 - lift) + 255 * lift * lum);
        g = Math.round((tintRgb[1] * lum) * (1 - lift) + 255 * lift * lum);
        b = Math.round((tintRgb[2] * lum) * (1 - lift) + 255 * lift * lum);
    }

    data[o] = Math.min(255, Math.max(0, r));
    data[o + 1] = Math.min(255, Math.max(0, g));
    data[o + 2] = Math.min(255, Math.max(0, b));
}

    return { data, width, height };
}

/** unmix (optionally tint), resize and write as PNG */
export async function unmixToFile(input, output, { tint = null, size = null } = {}) {
    const { data, width, height } = await unmixWhite(input, tint);
    let img = sharp(data, { raw: { width, height, channels: 4 } });
    if (size) img = img.resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } });
    await img.png().toFile(output);
    console.log(`${output} (${size ?? width}px${tint ? ", tint " + tint : ""})`);
}

// CLI: node tools/unmix-white.mjs <input> <output> [--tint #rrggbb] [--size N]
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
    const [input, output, ...rest] = process.argv.slice(2);
    if (!input || !output) {
        console.error("usage: node tools/unmix-white.mjs <input> <output> [--tint #rrggbb] [--size N]");
        process.exit(1);
    }
    const tintIdx = rest.indexOf("--tint");
    const sizeIdx = rest.indexOf("--size");
    await unmixToFile(input, output, {
        tint: tintIdx >= 0 ? rest[tintIdx + 1] : null,
        size: sizeIdx >= 0 ? Number(rest[sizeIdx + 1]) : null,
    });
}
