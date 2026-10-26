#!/usr/bin/env node
// Hamaca App Store screenshots (RE479) — frames and captions the four raw simulator captures
// into the store images, matching the card mockup "Store listing — … four framed captioned
// shots": a caption above a neutral ink device frame on a soft brand tint, at 1320×2868.
//
//   node bin/store-screenshots.mjs
//
// Reads  flutter/ios/fastlane/screenshots_raw/en-US/{01_needs_you,02_board,03_review,04_answer}.png
// Writes flutter/ios/fastlane/screenshots/en-US/<same names>.png (what `deliver` uploads)
//
// The mockup draws a 240px tile; every size here is that tile's value × 1320 / 240 = 5.5.
// Colours are the brand hexes from docs/brand/README.md: the tint is Blue or Violet mixed 14%
// into White (the mockup's `.tile-human` / `.tile-ai`), the frame and caption are Ink.
//
// Prereqs: the raw captures (bin/capture_store_screenshots.sh) and Playwright's Chromium in
// assets/node_modules (`cd assets && npm install && npx playwright install chromium`).
// See flutter/docs/DEPLOYMENT.md § "Store screenshots" for the whole seed → capture → render loop.
import { createRequire } from "node:module";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(resolve(__dirname, "../assets/package.json"));
const { chromium } = require("playwright");

const ROOT = resolve(__dirname, "..");
const RAW_DIR = join(ROOT, "flutter/ios/fastlane/screenshots_raw/en-US");
const OUT_DIR = join(ROOT, "flutter/ios/fastlane/screenshots/en-US");

const WIDTH = 1320;
const HEIGHT = 2868;
const SCALE = WIDTH / 240;

// docs/brand/README.md
const BLUE = "#1A6EFF";
const VIOLET = "#6339D0";
const WHITE = "#FFFFFF";
const INK = "#1E252E";

// Store order, caption and tint — exactly the mockup's.
const SHOTS = [
  { name: "01_needs_you", caption: "Your phone lights up only when it's your move.", tint: BLUE },
  { name: "02_board", caption: "Watch the whole factory at a glance.", tint: VIOLET },
  { name: "03_review", caption: "Approve, or send it back with a note.", tint: BLUE },
  { name: "04_answer", caption: "Answer an agent in two taps.", tint: BLUE },
];

// The mockup's tile values (p-4, gap-3, 15px caption with min-h 2.6em, 6px bezel, 30px / 24px radii).
const PAD = 16 * SCALE;
const GAP = 12 * SCALE;
const CAPTION_PX = 15 * SCALE;
const CAPTION_MIN_H = 2.6 * CAPTION_PX;
const BEZEL = 6 * SCALE;
const FRAME_RADIUS = 30 * SCALE;
const SCREEN_RADIUS = 24 * SCALE;

const missing = SHOTS.map((s) => join(RAW_DIR, `${s.name}.png`)).filter((p) => !existsSync(p));
if (missing.length > 0) {
  console.error(`store-screenshots: missing raw capture(s):\n  ${missing.join("\n  ")}`);
  console.error("Run bin/capture_store_screenshots.sh first (flutter/docs/DEPLOYMENT.md § Store screenshots).");
  process.exit(1);
}

const escapeHtml = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const page_html = ({ caption, tint }, dataUri) => `<!doctype html>
<html><head><meta charset="utf-8"><style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { width: ${WIDTH}px; height: ${HEIGHT}px; overflow: hidden; }
  body {
    background: color-mix(in oklab, ${tint} 14%, ${WHITE});
    color: ${INK};
    font-family: "Helvetica Neue", Helvetica, -apple-system, system-ui, sans-serif;
    padding: ${PAD}px;
    display: flex; flex-direction: column; gap: ${GAP}px;
  }
  figcaption {
    font-size: ${CAPTION_PX}px; font-weight: 600; line-height: 1.375; letter-spacing: -0.025em;
    text-align: center; min-height: ${CAPTION_MIN_H}px;
  }
  .stage { flex: 1; min-height: 0; display: flex; justify-content: center; align-items: flex-start; }
  .shot-frame { padding: ${BEZEL}px; border-radius: ${FRAME_RADIUS}px; background: ${INK}; }
  .shot-frame img { display: block; border-radius: ${SCREEN_RADIUS}px; }
</style></head>
<body>
  <figcaption>${escapeHtml(caption)}</figcaption>
  <div class="stage"><div class="shot-frame"><img src="${dataUri}" alt=""></div></div>
</body></html>`;

mkdirSync(OUT_DIR, { recursive: true });
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: 1 });

  for (const shot of SHOTS) {
    const raw = readFileSync(join(RAW_DIR, `${shot.name}.png`));
    await page.setContent(page_html(shot, `data:image/png;base64,${raw.toString("base64")}`));
    await page.evaluate(() => document.fonts.ready);

    // Fit the whole screen inside the space left under the caption, bezel included.
    await page.evaluate((bezel) => {
      const img = document.querySelector("img");
      const stage = document.querySelector(".stage");
      const scale = Math.min(
        (stage.clientWidth - 2 * bezel) / img.naturalWidth,
        (stage.clientHeight - 2 * bezel) / img.naturalHeight,
      );
      img.style.width = `${Math.floor(img.naturalWidth * scale)}px`;
      img.style.height = `${Math.floor(img.naturalHeight * scale)}px`;
    }, BEZEL);

    const out = join(OUT_DIR, `${shot.name}.png`);
    await page.screenshot({ path: out });
    console.log(`store-screenshots: wrote ${out.slice(ROOT.length + 1)}`);
  }
} finally {
  await browser.close();
}
