#!/usr/bin/env node
// Relay screenshot helper — drives the running dev app with a headless
// Chromium (via the Playwright installed under assets/) and captures the key
// screens for design review. Reusable by the smoke-tester agent.
//
//   Usage: node bin/shoot.mjs [--base http://localhost:4003] [--out <dir>]
//
// Logs in through the dev-only /dev/login bypass, discovers the board slug and
// a representative card ref, then writes PNGs for each screen (desktop + mobile).
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(resolve(__dirname, "../assets/package.json"));
const { chromium } = require("playwright");

const args = process.argv.slice(2);
const opt = (flag, def) => {
  const i = args.indexOf(flag);
  return i >= 0 && args[i + 1] ? args[i + 1] : def;
};
const BASE = opt("--base", "http://localhost:4003").replace(/\/$/, "");
const OUT = resolve(opt("--out", join(__dirname, "..", "tmp", "shots")));
mkdirSync(OUT, { recursive: true });

const settle = async (page, ms = 1600) => {
  await page.waitForLoadState("domcontentloaded").catch(() => {});
  await page.waitForTimeout(ms);
};
const shot = async (page, name, full = false) => {
  const path = join(OUT, `${name}.png`);
  await page.screenshot({ path, fullPage: full });
  console.log(`  ✓ ${name} -> ${path}`);
  return path;
};

const browser = await chromium.launch();
try {
  const desktop = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });

  // 1) Landing / sign-in (logged OUT, own context)
  const anon = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
  const ap = await anon.newPage();
  await ap.goto(`${BASE}/`, { waitUntil: "domcontentloaded" });
  await settle(ap);
  await shot(ap, "01-landing", true);
  await anon.close();

  // Log in for everything else
  const page = await desktop.newPage();
  await page.goto(`${BASE}/dev/login`, { waitUntil: "domcontentloaded" });
  await settle(page, 800);

  // 2) Boards home
  await page.goto(`${BASE}/boards`, { waitUntil: "domcontentloaded" });
  await settle(page);
  await shot(page, "02-boards", true);

  // 3) Board (follow /board redirect to discover the slug)
  await page.goto(`${BASE}/board`, { waitUntil: "domcontentloaded" });
  await settle(page);
  const url = new URL(page.url());
  const slug = url.pathname.split("/")[2] || "";
  console.log(`  board slug = ${slug}`);
  await shot(page, "03-board", false);

  // discover a representative card ref for the drawer
  const ref = await page.evaluate(() => {
    const el = document.querySelector("[data-ref]");
    return el ? el.getAttribute("data-ref") : null;
  });
  console.log(`  sample card ref = ${ref}`);

  // 4) Board settings
  await page.goto(`${BASE}/board/${slug}/settings`, { waitUntil: "domcontentloaded" });
  await settle(page);
  await shot(page, "04-settings", true);

  // 5) Card detail drawer
  if (ref) {
    await page.goto(`${BASE}/board/${slug}?card=${ref}`, { waitUntil: "domcontentloaded" });
    await settle(page);
    await shot(page, "05-drawer", false);
  }

  // 6) Docs
  await page.goto(`${BASE}/docs`, { waitUntil: "domcontentloaded" });
  await settle(page);
  await shot(page, "06-docs", true);

  // 7) Mobile board + drawer
  const mobile = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  const mp = await mobile.newPage();
  await mp.goto(`${BASE}/dev/login`, { waitUntil: "domcontentloaded" });
  await settle(mp, 800);
  await mp.goto(`${BASE}/board/${slug}`, { waitUntil: "domcontentloaded" });
  await settle(mp);
  await shot(mp, "07-board-mobile", false);
  if (ref) {
    await mp.goto(`${BASE}/board/${slug}?card=${ref}`, { waitUntil: "domcontentloaded" });
    await settle(mp);
    await shot(mp, "08-drawer-mobile", false);
  }
  await mobile.close();

  console.log(`\nAll screenshots in ${OUT}`);
} finally {
  await browser.close();
}
