#!/usr/bin/env node
// Relay design capture — turns the RUNNING app into a Claude Design `.dc.html`
// mockup, so the design project can keep iterating from what actually shipped
// instead of from a hand-drawn approximation.
//
//   node bin/design-capture.mjs                       # capture the card-detail screen
//   node bin/design-capture.mjs --screen card-detail --out "docs/designs-as-is/Relay Card Detail.dc.html"
//   node bin/design-capture.mjs --seed                # re-seed the demo board first (recommended)
//   node bin/design-capture.mjs --list                # list the screens this script knows
//   node bin/design-capture.mjs --only detail-done,activity   # iterate on a couple of artboards
//
// How it works: it drives a headless Chromium over the real LiveView (seeded by
// `priv/repo/design_seeds.exs`), and for each artboard it walks the target
// subtree and writes every *computed* style back onto the element as an inline
// `style=` attribute — diffed against that tag's browser defaults and against the
// parent's inherited values, so the output stays readable. Tailwind/daisyUI class
// names are dropped; nothing external is referenced. The result is a
// self-contained static document that opens anywhere and uploads to Claude Design.
//
// Output lands in `docs/designs-as-is/`, deliberately NOT `docs/designs/`: those are
// pulled *from* Claude Design and lead the app; these are generated *from* the app and
// follow it. Two directories so nobody ever has to guess which way a given file points.
//
// Prereqs: a dev server on --base with `mix run priv/repo/design_seeds.exs` applied.
// See `.claude/skills/design-capture/SKILL.md` for the full loop.
import { createRequire } from "node:module";
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, relative, resolve, sep } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(resolve(__dirname, "../assets/package.json"));
const { chromium } = require("playwright");

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const opt = (name, def) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[i + 1] : def;
};

const BASE = opt("base", process.env.RELAY_BASE || "http://localhost:4003").replace(/\/$/, "");
const BOARD = opt("board", "design-capture");
const DESKTOP = { width: 1440, height: 940 };
const MOBILE = { width: 402, height: 860 };

// ---------------------------------------------------------------------------
// Screens — each one becomes a `.dc.html` document full of artboards.
//
// A frame is: where to go, what to wait for, what to click first, and which
// subtree to lift out. `card` is a ref on the seeded board; the drawer opens as
// an overlay on the board URL (`/cards/:ref` is the chromeless native host and
// hides the decision buttons, so it is deliberately NOT what we shoot).
// ---------------------------------------------------------------------------

const drawer = (spec) => ({
  selector: "#card-drawer-panel",
  url: (s) => `/board/${s.board}?card=${spec.card}`,
  wait: "#card-drawer-panel",
  ...spec,
});

// The drawer's body arrives in a second async render that also *reassigns*
// `drawer_tab` (a card with a live run opens on Run). Click before that lands
// and the tab silently snaps back, so wait for the socket, then for the
// skeletons to clear, and only then switch tabs.
const settle = async (page) => {
  await page.waitForFunction(() => window.liveSocket?.isConnected(), null, { timeout: 20000 });
  await page.waitForFunction(() => !document.querySelector('[id$="-skeleton"]'), null, { timeout: 20000 });
  await page.waitForTimeout(250);
};

const showTab = async (page, name) => {
  await page.click(`#card-drawer-tab-${name}`);
  await page.waitForFunction(
    (n) => {
      const panel = document.querySelector(`#card-drawer-tab-panel-${n}`);
      return panel && !panel.classList.contains("hidden");
    },
    name,
    { timeout: 10000 },
  );
  await page.waitForTimeout(300);
};

const SCREENS = {
  "card-detail": {
    title: "Relay Card Detail",
    tagline: "The card drawer, every face — captured from the running LiveView",
    intro:
      "Each artboard below is the real `#card-drawer-panel` subtree lifted out of the app with " +
      "its computed styles inlined. Nothing here is hand-drawn: change the LiveView, re-run " +
      "`bin/design-capture.mjs`, and these update.",
    frames: [
      drawer({
        id: "detail-ready",
        group: "Detail tab",
        name: "Ready · human holds the baton",
        note: "The plain reading state. Stage chip is blue because a human owns the stage; description, acceptance criteria, spec and the comment thread all present.",
        card: "DE1",
      }),
      drawer({
        id: "detail-working",
        group: "Detail tab",
        name: "Working · AI holds the baton",
        note: "Violet stage chip, the ambient working strip with its progress %, and the sub-task checklist the Code stage ticks off as it goes.",
        card: "DE2",
      }),
      drawer({
        id: "detail-needs-input-question",
        group: "Detail tab",
        name: "Needs input · question (A1)",
        note: "The agent asked and parked. Structured stepper: one question at a time, canned options plus free text.",
        card: "DE3",
      }),
      drawer({
        id: "detail-needs-input-escalation",
        group: "Detail tab",
        name: "Needs input · escalation (A4)",
        note: "Different provenance, different face: the node burned its retry budget and the flow routed the card to a human. Failure output stays visible, and Retry is offered alongside the answer box.",
        card: "DE4",
      }),
      drawer({
        id: "detail-in-review",
        group: "Detail tab",
        name: "In review · the review gate",
        note: "The one place buttons are correct: a decision only a human can make. Approve advances to the next stage or substage; Request changes opens the note panel.",
        card: "DE5",
      }),
      drawer({
        id: "detail-review-reject",
        group: "Detail tab",
        name: "In review · request changes open",
        note: "Same card, reject panel expanded — the note is required, and it rides back with the card as the rejection banner.",
        card: "DE5",
        prepare: async (page) => {
          await page.click("#review-request-changes");
          await page.waitForSelector("#review-reject-panel");
          await page.fill(
            "#review-request-note",
            "Archiving 400 cards fired 400 PubSub broadcasts and the board froze. Batch the broadcast into one message.",
          );
          await page.waitForTimeout(250);
        },
      }),
      drawer({
        id: "detail-sent-back",
        group: "Detail tab",
        name: "Sent back · rejection banner",
        note: "The card re-entered Code carrying the reviewer's note. The banner is the first thing in the panel, above the working strip.",
        card: "DE6",
      }),
      drawer({
        id: "detail-done",
        group: "Detail tab",
        name: "Done · shipped",
        note: "Done pill in the header, the AI result block (summary, changed files, screenshots, deploy link), and a fully-ticked checklist.",
        card: "DE8",
      }),
      drawer({
        id: "detail-archived",
        group: "Detail tab",
        name: "Archived · read-only",
        note: "Every edit affordance is gone; the only action is Restore.",
        card: "DE10",
      }),
      drawer({
        id: "run-mid-flight",
        group: "Run tab",
        name: "Run · mid-flight",
        note: "The flow graph with the live node lit, plus the node table — attempts, duration, spend, verdict.",
        card: "DE2",
        tab: "run",
      }),
      drawer({
        id: "run-escalated",
        group: "Run tab",
        name: "Run · parked on a human",
        note: "The parked banner repeats inside the Run tab so the answer box is reachable without switching back.",
        card: "DE4",
        tab: "run",
      }),
      drawer({
        id: "run-breaker",
        group: "Run tab",
        name: "Run · circuit breaker tripped",
        note: "Three identical quality-review failures in a row; the engine stopped the run rather than loop forever.",
        card: "DE7",
        tab: "run",
      }),
      drawer({
        id: "run-history",
        group: "Run tab",
        name: "Run · with history",
        note: "Latest run expanded, prior runs collapsed underneath — done, failed, done.",
        card: "DE8",
        tab: "run",
      }),
      drawer({
        id: "run-queued",
        group: "Run tab",
        name: "Run · queued",
        note: "AI-ready card sitting in the flow's pulls-from stage with no run yet.",
        card: "DE9",
        tab: "run",
      }),
      drawer({
        id: "activity",
        group: "Activity tab",
        name: "Activity · the audit trail",
        note: "Agent health at the top, then the mixed feed: moves, status flips, the question and its answer, and the runner's own log lines.",
        card: "DE11",
        tab: "activity",
      }),
      drawer({
        id: "detail-mobile",
        group: "Narrow",
        name: "Detail · narrow (402px)",
        note: "Below the 720px drawer breakpoint the panel goes full-bleed. Same markup, no separate mobile client — see ADR 0001.",
        card: "DE5",
        viewport: MOBILE,
      }),
      {
        id: "in-context",
        group: "In context",
        name: "The drawer over the board",
        note: "How the card detail actually arrives: an end-drawer over the board, scrim behind it.",
        card: "DE5",
        url: (s) => `/board/${s.board}?card=DE5`,
        wait: "#card-drawer-panel",
        selector: "body",
        // Both are "no executor is connected to this dev machine" chrome, not a
        // design state — they would read as part of the board if left in.
        hide: ["#stopped-work-banner", "#restart-stalled-button"],
        expand: false,
        frameHeight: DESKTOP.height,
      },
    ],
  },
};

// ---------------------------------------------------------------------------
// The in-page serializer. Runs inside the browser, must be self-contained.
// ---------------------------------------------------------------------------

// The artboards carry this reset, and the baseline that inline styles are
// diffed against is measured under the SAME reset. That is what keeps the
// output small and correct: Tailwind's preflight sets `border-style:solid`
// on every element, so a browser-default baseline would emit a bare
// `border-style` with no width and paint a 3px black box around everything.
//
// Everything reset here is either non-inherited or reset to `inherit` — an
// aggressive `*{list-style:none}` would out-specify the cascade and silently
// eat every value the diff decided it could skip because the parent already
// had it.
const FRAME_RESET =
  "box-sizing:border-box;border:0 solid currentColor;margin:0;padding:0;" +
  "font:inherit;color:inherit;background:transparent;appearance:none;";

function serializeSubtree({ selector, scope, expand, reset }) {
  const PROPS = [
    "display", "visibility", "opacity", "position", "top", "right", "bottom", "left", "z-index",
    "flex-direction", "flex-wrap", "flex-grow", "flex-shrink", "flex-basis",
    "justify-content", "align-items", "align-self", "align-content", "justify-self", "order",
    "row-gap", "column-gap",
    "grid-template-columns", "grid-template-rows", "grid-column", "grid-row",
    "grid-auto-flow", "grid-auto-rows", "place-items", "place-content",
    "box-sizing", "width", "height", "min-width", "min-height", "max-width", "max-height", "aspect-ratio",
    "margin-top", "margin-right", "margin-bottom", "margin-left",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
    "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
    "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
    "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius",
    "outline-width", "outline-style", "outline-color", "outline-offset",
    "background-color", "background-image", "background-size", "background-position",
    "background-repeat", "background-clip", "background-origin",
    "box-shadow", "filter", "backdrop-filter", "mix-blend-mode",
    "color", "font-family", "font-size", "font-weight", "font-style", "font-variant-numeric",
    "line-height", "letter-spacing", "text-align", "text-transform", "text-indent",
    "text-decoration-line", "text-decoration-color", "text-overflow",
    "white-space", "word-break", "overflow-wrap", "vertical-align",
    "writing-mode", "text-orientation", "translate", "rotate", "scale",
    "overflow-x", "overflow-y",
    "list-style-type", "list-style-position",
    "cursor", "pointer-events", "user-select", "resize", "appearance",
    "transform", "transform-origin",
    "object-fit", "object-position", "fill", "stroke", "stroke-width",
    "mask-image", "mask-size", "mask-position", "mask-repeat",
    "table-layout", "border-collapse", "border-spacing",
    "content",
  ];

  // Properties the cascade hands down — emit only where the child actually
  // differs from its parent, or the output triples in size for no visual gain.
  const INHERITED = new Set([
    "color", "font-family", "font-size", "font-weight", "font-style", "font-variant-numeric",
    "line-height", "letter-spacing", "text-align", "text-transform", "text-indent",
    "white-space", "word-break", "overflow-wrap", "list-style-type", "list-style-position",
    "cursor", "visibility", "pointer-events", "fill", "stroke", "stroke-width",
    "writing-mode", "text-orientation",
    "border-collapse", "border-spacing",
  ]);

  const SKIP_TAGS = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "LINK", "META", "TITLE", "IFRAME"]);
  // Attributes worth keeping on HTML elements. SVG keeps everything geometric.
  const KEEP_ATTR = /^(alt|src|href|type|placeholder|value|checked|disabled|colspan|rowspan|title|role|aria-|open|selected|multiple|lang|dir)/;
  const SVG_NS = "http://www.w3.org/2000/svg";

  const root = document.querySelector(selector);
  if (!root) throw new Error(`design-capture: no element matches ${selector}`);

  // Let the panel grow to its natural height so the artboard shows the whole
  // card instead of one scrollport of it.
  const restore = [];
  if (expand) {
    for (const el of [root, ...root.querySelectorAll("*")]) {
      const cs = getComputedStyle(el);
      if (cs.overflowY === "auto" || cs.overflowY === "scroll" || el === root) {
        restore.push([el, el.getAttribute("style")]);
        el.style.height = "auto";
        el.style.maxHeight = "none";
        el.style.overflow = "visible";
      }
    }
    void root.offsetHeight;
  }

  // `getComputedStyle().width` hands back the *used* value, so every block would
  // get its measured pixel width pinned and stop reflowing. The Typed OM map
  // hands back the *computed* value instead — `auto` stays `auto` — which is the
  // difference between a mockup that rewraps and one that overlaps itself.
  const sizeValue = (el, prop) => {
    if (el.namespaceURI === SVG_NS) return getComputedStyle(el).getPropertyValue(prop);
    let declared;
    try {
      declared = el.computedStyleMap().get(prop)?.toString();
    } catch {
      return getComputedStyle(el).getPropertyValue(prop);
    }
    if (!declared || declared === "auto") return null;
    // Percentages survive as percentages; anything viewport- or context-relative
    // is frozen to the pixels it actually occupied, since the artboard is not the
    // viewport it was measured in.
    if (declared.endsWith("%")) return declared;
    return getComputedStyle(el).getPropertyValue(prop);
  };

  // Defaults, per tag, measured in a pristine document under the artboard's own
  // reset — see FRAME_RESET on the Node side.
  const frame = document.createElement("iframe");
  frame.style.cssText = "position:absolute;left:-9999px;width:1200px;height:800px;border:0;";
  document.body.appendChild(frame);
  const fdoc = frame.contentDocument;
  const fstyle = fdoc.createElement("style");
  fstyle.textContent = `*,::before,::after{${reset}}`;
  fdoc.head.appendChild(fstyle);
  const fsvg = fdoc.createElementNS(SVG_NS, "svg");
  fdoc.body.appendChild(fsvg);

  const defaultsCache = new Map();
  const defaultsFor = (el) => {
    const isSvg = el.namespaceURI === SVG_NS;
    const key = (isSvg ? "svg:" : "html:") + el.tagName;
    if (defaultsCache.has(key)) return defaultsCache.get(key);
    let probe;
    try {
      probe = isSvg ? fdoc.createElementNS(SVG_NS, el.tagName) : fdoc.createElement(el.tagName);
      (isSvg ? fsvg : fdoc.body).appendChild(probe);
    } catch {
      probe = fdoc.createElement("div");
      fdoc.body.appendChild(probe);
    }
    const cs = fdoc.defaultView.getComputedStyle(probe);
    const map = {};
    for (const p of PROPS) map[p] = cs.getPropertyValue(p);
    probe.remove();
    defaultsCache.set(key, map);
    return map;
  };

  const pseudoBaseline = (() => {
    const probe = fdoc.createElement("div");
    fdoc.body.appendChild(probe);
    const out = {};
    for (const p of PROPS) out[p] = fdoc.defaultView.getComputedStyle(probe, "::before").getPropertyValue(p);
    probe.remove();
    return out;
  })();

  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const escAttr = (s) => esc(s).replace(/"/g, "&quot;");

  const pseudoRules = [];
  let pseudoSeq = 0;

  const SIDES = ["top", "right", "bottom", "left"];
  // A border only exists when it has width AND style; emit the trio together or
  // not at all, so a lone `border-style` can never paint a phantom edge.
  const borderDecls = (cs) => {
    const out = [];
    for (const side of SIDES) {
      const w = cs.getPropertyValue(`border-${side}-width`);
      const s = cs.getPropertyValue(`border-${side}-style`);
      if (!w || w === "0px" || s === "none") continue;
      out.push(`border-${side}:${w} ${s} ${cs.getPropertyValue(`border-${side}-color`)}`);
    }
    const ow = cs.getPropertyValue("outline-width");
    const os = cs.getPropertyValue("outline-style");
    if (ow && ow !== "0px" && os !== "none") {
      out.push(`outline:${ow} ${os} ${cs.getPropertyValue("outline-color")}`);
      const off = cs.getPropertyValue("outline-offset");
      if (off && off !== "0px") out.push(`outline-offset:${off}`);
    }
    return out;
  };

  const SKIP_LONGHAND = new Set(
    SIDES.flatMap((s) => [`border-${s}-width`, `border-${s}-style`, `border-${s}-color`]).concat([
      "outline-width",
      "outline-style",
      "outline-color",
      "outline-offset",
    ]),
  );

  // The drawer is a `position:fixed` overlay. Kept as-is, every artboard would
  // escape its frame and pile up over the page, so the root is re-planted as an
  // in-flow box and anything fixed below it anchors to the frame instead of the
  // viewport (the frame carries `position:relative`).
  const ROOT_DROP = new Set([
    "position", "top", "right", "bottom", "left", "z-index",
    "grid-column", "grid-row", "transform", "transform-origin",
    "margin-top", "margin-right", "margin-bottom", "margin-left",
  ]);

  const rootRect = root.getBoundingClientRect();

  const styleFor = (el, cs, parentCs, isRoot) => {
    const defaults = defaultsFor(el);
    const decls = isRoot ? ["position:relative"] : [];
    // A `fixed` descendant (the board's drawer overlay) was placed against the
    // viewport. Re-anchoring it to the frame means carrying the offsets it
    // actually had, not the `auto` the cascade reports for the other axis.
    const pin = [];
    const wasFixed = !isRoot && cs.getPropertyValue("position") === "fixed";
    if (wasFixed) {
      // `top`/`left` resolve against the containing block, not the artboard —
      // measure from the nearest positioned ancestor or the pin lands a whole
      // page-scroll away.
      let cb = el.parentElement;
      while (cb && cb !== root && getComputedStyle(cb).position === "static") cb = cb.parentElement;
      const base = (cb || root).getBoundingClientRect();
      const r = el.getBoundingClientRect();
      pin.push(`top:${Math.round(r.top - base.top)}px`, `left:${Math.round(r.left - base.left)}px`);
    }
    for (const p of PROPS) {
      if (isRoot && ROOT_DROP.has(p)) continue;
      // A fixed box was outside the grid; as `absolute` it would rejoin it and
      // get thrown into an implicit column beyond the viewport.
      if (wasFixed && (p === "grid-column" || p === "grid-row")) continue;
      if (p === "content" || SKIP_LONGHAND.has(p)) continue;
      if (p === "text-decoration-color" && cs.getPropertyValue("text-decoration-line") === "none") continue;
      let v = p === "width" || p === "height" ? sizeValue(el, p) : cs.getPropertyValue(p);
      if (!v) continue;
      if (p === "position" && v === "fixed") v = "absolute";
      if (INHERITED.has(p)) {
        if (parentCs && parentCs.getPropertyValue(p) === v) continue;
        if (!parentCs && v === defaults[p]) continue;
      } else if (v === defaults[p]) {
        continue;
      }
      decls.push(`${p}:${v}`);
    }
    return decls.concat(borderDecls(cs), pin);
  };

  const collectPseudo = (el, cs, which) => {
    const ps = getComputedStyle(el, which);
    const content = ps.getPropertyValue("content");
    if (!content || content === "none" || content === "normal") return null;
    const decls = [];
    for (const p of PROPS) {
      if (SKIP_LONGHAND.has(p)) continue;
      const v = ps.getPropertyValue(p);
      if (!v) continue;
      if (p !== "content" && v === pseudoBaseline[p]) continue;
      decls.push(`${p}:${v}`);
    }
    decls.push(...borderDecls(ps));
    if (!decls.length) return null;
    const mark = `dc${++pseudoSeq}`;
    pseudoRules.push(`${scope} [data-dc="${mark}"]${which}{${decls.join(";")}}`);
    return mark;
  };

  const walk = (el, parentCs, isRoot) => {
    if (SKIP_TAGS.has(el.tagName)) return "";
    const cs = getComputedStyle(el);
    if (!isRoot && (cs.display === "none" || el.hasAttribute("hidden"))) return "";

    const tag = el.tagName.toLowerCase();
    const isSvg = el.namespaceURI === SVG_NS;
    const attrs = [];

    for (const { name, value } of el.attributes) {
      if (/^(phx-|data-phx|xmlns:|on)/.test(name)) continue;
      if (name === "class" || name === "style") continue;
      if (name === "id") {
        // Keep the hook for designers without minting duplicate ids across artboards.
        attrs.push(`data-id="${escAttr(value)}"`);
        continue;
      }
      if (isSvg || KEEP_ATTR.test(name)) attrs.push(`${name}="${escAttr(value)}"`);
    }

    // Live form state lives on the property, not the attribute.
    if (tag === "input") {
      if (el.type === "checkbox" || el.type === "radio") {
        if (el.checked) attrs.push("checked");
      } else if (el.value) {
        attrs.push(`value="${escAttr(el.value)}"`);
      }
    }

    const decls = styleFor(el, cs, parentCs, isRoot);
    const before = collectPseudo(el, cs, "::before");
    const after = collectPseudo(el, cs, "::after");
    const marks = [before, after].filter(Boolean);
    if (marks.length) attrs.push(`data-dc="${marks[0]}"`);
    // One element, two pseudos — reuse the first mark for both rules.
    if (marks.length === 2) {
      const idx = pseudoRules.length - 1;
      pseudoRules[idx] = pseudoRules[idx].replace(`[data-dc="${marks[1]}"]`, `[data-dc="${marks[0]}"]`);
    }
    if (decls.length) attrs.push(`style="${escAttr(decls.join(";"))}"`);

    const open = `<${tag}${attrs.length ? " " + attrs.join(" ") : ""}>`;
    const VOID = new Set(["img", "input", "br", "hr", "source", "path", "circle", "rect", "line", "polygon", "polyline", "use", "stop", "ellipse"]);
    if (VOID.has(tag) && !el.childNodes.length) return open;

    let inner = "";
    if (tag === "textarea") {
      inner = esc(el.value || "");
    } else {
      for (const node of el.childNodes) {
        if (node.nodeType === Node.TEXT_NODE) inner += esc(node.nodeValue);
        else if (node.nodeType === Node.ELEMENT_NODE) inner += walk(node, cs, false);
      }
    }
    return `${open}${inner}</${tag}>`;
  };

  const html = walk(root, null, true);
  const rect = root.getBoundingClientRect();
  const bodyCs = getComputedStyle(document.body);
  const base = {
    fontFamily: bodyCs.fontFamily,
    fontSize: bodyCs.fontSize,
    color: bodyCs.color,
    background: bodyCs.backgroundColor,
  };

  frame.remove();
  for (const [el, prev] of restore) {
    if (prev === null) el.removeAttribute("style");
    else el.setAttribute("style", prev);
  }

  return { html, pseudoRules, width: Math.round(rect.width), height: Math.round(rect.height), base };
}

// ---------------------------------------------------------------------------
// Asset inlining — a `.dc.html` must reference nothing but itself.
// ---------------------------------------------------------------------------

const assetCache = new Map();

async function inlineAssets(page, html) {
  const urls = new Set();
  for (const m of html.matchAll(/src="([^"]+)"/g)) urls.add(m[1]);
  for (const m of html.matchAll(/url\(&quot;(.*?)&quot;\)/g)) urls.add(m[1]);
  for (const m of html.matchAll(/url\(([^)"'&]+)\)/g)) urls.add(m[1]);

  const targets = [...urls].filter((u) => u && !u.startsWith("data:") && !u.startsWith("#"));
  if (!targets.length) return html;

  // Fetched from Node, not the page: an avatar on a third-party CDN is opaque
  // to in-page `fetch` and would silently stay a remote reference.
  const api = page.context().request;
  let result = html;
  for (const url of targets) {
    if (!assetCache.has(url)) {
      assetCache.set(url, null);
      try {
        const res = await api.get(url.startsWith("http") ? url : new URL(url, BASE).href);
        if (res.ok()) {
          const body = await res.body();
          if (body.length <= 2_000_000) {
            const type = (res.headers()["content-type"] || "application/octet-stream").split(";")[0];
            assetCache.set(url, `data:${type};base64,${body.toString("base64")}`);
          }
        }
      } catch {
        /* leave it alone; the artboard just keeps one remote reference */
      }
    }
    const data = assetCache.get(url);
    if (data) result = result.split(url).join(data);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Document assembly
// ---------------------------------------------------------------------------

const CANVAS_BG = "oklch(0.955 0.008 255)";
const INK = "oklch(0.32 0.02 255)";
const MUTED = "oklch(0.52 0.02 255)";
const RULE = "oklch(0.90 0.006 255)";

function renderDocument(screen, frames, meta) {
  const rules = frames.flatMap((f) => f.pseudoRules);
  const groups = [];
  for (const f of frames) {
    const last = groups[groups.length - 1];
    if (last && last.name === f.group) last.frames.push(f);
    else groups.push({ name: f.group, frames: [f] });
  }

  const section = (f) => {
    const frameStyle = [
      "background:oklch(1 0 0)",
      `border:1px solid ${RULE}`,
      "border-radius:14px",
      "overflow:hidden",
      // containing block for anything the app positioned against the viewport
      "position:relative",
      "box-shadow:0 1px 2px oklch(0.32 0.02 255 / 0.06),0 8px 24px oklch(0.32 0.02 255 / 0.06)",
      `width:${f.width}px`,
      "max-width:100%",
      f.frameHeight ? `height:${f.frameHeight}px` : "",
      `font-family:${f.base.fontFamily}`,
      `font-size:${f.base.fontSize}`,
      `color:${f.base.color}`,
    ]
      .filter(Boolean)
      .join(";");

    return `
  <section id="${f.id}" style="display:flex;flex-direction:column;gap:12px;">
    <div style="display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;">
      <h3 style="margin:0;font-size:15px;font-weight:600;letter-spacing:-0.01em;color:${INK};">${f.name}</h3>
      <code style="font-family:'JetBrains Mono',ui-monospace,monospace;font-size:11px;color:${MUTED};background:oklch(0.97 0.004 255);border:1px solid ${RULE};border-radius:5px;padding:2px 6px;">${f.card || f.selector}</code>
      <code style="font-family:'JetBrains Mono',ui-monospace,monospace;font-size:11px;color:${MUTED};">${f.width}×${f.height}</code>
    </div>
    <p style="margin:0;max-width:760px;font-size:13px;line-height:1.55;color:${MUTED};">${f.note}</p>
    <div data-dc-frame style="${frameStyle}">${f.html}</div>
  </section>`;
  };

  const body = groups
    .map(
      (g) => `
<div style="display:flex;flex-direction:column;gap:34px;">
  <div style="display:flex;align-items:center;gap:12px;">
    <span style="font-family:'JetBrains Mono',ui-monospace,monospace;font-size:11px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:${MUTED};">${g.name}</span>
    <span style="flex:1;height:1px;background:${RULE};"></span>
  </div>
  ${g.frames.map(section).join("\n")}
</div>`,
    )
    .join("\n");

  return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${screen.title}</title>
<script src="${meta.supportJs}"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  *{box-sizing:border-box;}
  html,body{margin:0;padding:0;}
  body{font-family:'Helvetica Neue',Helvetica,-apple-system,system-ui,sans-serif;color:${INK};background:${CANVAS_BG};-webkit-font-smoothing:antialiased;}
  ::-webkit-scrollbar{width:9px;height:9px;}
  ::-webkit-scrollbar-thumb{background:oklch(0.88 0.01 255);border-radius:6px;}
  ::-webkit-scrollbar-track{background:transparent;}
  /* The artboard reset. Inline styles below are diffs against exactly this. */
  [data-dc-frame] *,[data-dc-frame] ::before,[data-dc-frame] ::after{${FRAME_RESET}}
${rules.map((r) => "  " + r).join("\n")}
</style>
</helmet>

<div style="min-height:100vh;padding:40px 44px 96px;display:flex;flex-direction:column;gap:44px;">

  <header style="display:flex;flex-direction:column;gap:12px;max-width:820px;">
    <div style="display:flex;align-items:center;gap:9px;">
      <div style="width:23px;height:23px;border-radius:7px;background:oklch(0.60 0.14 250);display:flex;align-items:center;justify-content:center;position:relative;">
        <div style="width:8px;height:8px;border-radius:50%;background:oklch(1 0 0);"></div>
        <div style="position:absolute;right:3px;top:3px;width:4px;height:4px;border-radius:50%;background:oklch(0.60 0.14 250);box-shadow:0 0 0 1.5px oklch(1 0 0);"></div>
      </div>
      <span style="font-weight:600;font-size:15px;letter-spacing:-0.02em;">Relay</span>
      <span style="font-family:'JetBrains Mono',ui-monospace,monospace;font-size:10px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:oklch(0.56 0.16 292);background:oklch(0.56 0.16 292 / 0.10);border-radius:5px;padding:3px 7px;">captured from code</span>
    </div>
    <h1 style="margin:0;font-size:30px;font-weight:600;letter-spacing:-0.03em;">${screen.title}</h1>
    <p style="margin:0;font-size:15px;line-height:1.6;color:${MUTED};">${screen.tagline}</p>
    <p style="margin:0;font-size:13px;line-height:1.6;color:${MUTED};max-width:760px;">${screen.intro}</p>
    <div style="display:flex;flex-wrap:wrap;gap:8px;margin-top:4px;font-family:'JetBrains Mono',ui-monospace,monospace;font-size:11px;color:${MUTED};">
      <span style="border:1px solid ${RULE};border-radius:6px;padding:3px 8px;background:oklch(1 0 0);">${meta.captured}</span>
      <span style="border:1px solid ${RULE};border-radius:6px;padding:3px 8px;background:oklch(1 0 0);">${meta.commit}</span>
      <span style="border:1px solid ${RULE};border-radius:6px;padding:3px 8px;background:oklch(1 0 0);">${frames.length} artboards</span>
      <span style="border:1px solid ${RULE};border-radius:6px;padding:3px 8px;background:oklch(1 0 0);">bin/design-capture.mjs</span>
    </div>
  </header>

${body}

  <footer style="border-top:1px solid ${RULE};padding-top:16px;font-size:12px;line-height:1.7;color:${MUTED};max-width:820px;">
    Regenerate with <code style="font-family:'JetBrains Mono',ui-monospace,monospace;">mix run priv/repo/design_seeds.exs &amp;&amp; node bin/design-capture.mjs --screen ${meta.screen}</code>.
    Data comes from <code style="font-family:'JetBrains Mono',ui-monospace,monospace;">priv/repo/design_seeds.exs</code>; the artboards are the live
    <code style="font-family:'JetBrains Mono',ui-monospace,monospace;">#card-drawer-panel</code> subtree with computed styles inlined.
  </footer>
</div>
</x-dc>
</body>
</html>
`;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

if (flag("list")) {
  for (const [key, s] of Object.entries(SCREENS)) {
    console.log(`${key.padEnd(16)} ${s.frames.length} artboards — ${s.title}`);
  }
  process.exit(0);
}

const screenKey = opt("screen", "card-detail");
const screen = SCREENS[screenKey];
if (!screen) {
  console.error(`Unknown screen "${screenKey}". Known: ${Object.keys(SCREENS).join(", ")}`);
  process.exit(1);
}

const OUT = resolve(opt("out", join(__dirname, "..", "docs", "designs-as-is", `${screen.title}.dc.html`)));
const only = opt("only", null);
const frames = only ? screen.frames.filter((f) => only.split(",").includes(f.id)) : screen.frames;

console.log(`design-capture · ${screenKey} · ${frames.length} artboards · ${BASE}`);

const commit = await (async () => {
  const { execSync } = await import("node:child_process");
  try {
    return execSync("git rev-parse --short HEAD", { cwd: resolve(__dirname, "..") }).toString().trim();
  } catch {
    return "unknown";
  }
})();

// A seeded run is live: the engine keeps advancing the demo runs, so attempt
// counts and elapsed times drift between captures. Re-seeding right before the
// shoot is what makes two runs of this script comparable.
if (flag("seed")) {
  const { execSync } = await import("node:child_process");
  console.log("  seeding priv/repo/design_seeds.exs …");
  execSync("mix run priv/repo/design_seeds.exs", { cwd: resolve(__dirname, ".."), stdio: "inherit" });
}

const browser = await chromium.launch();
const captured = [];
try {
  const context = await browser.newContext({ viewport: DESKTOP, deviceScaleFactor: 2 });
  const page = await context.newPage();
  page.on("pageerror", (e) => console.warn(`  ! page error: ${e.message}`));

  await page.goto(`${BASE}/dev/login`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(600);

  for (const f of frames) {
    const url = `${BASE}${f.url({ board: BOARD })}`;
    process.stdout.write(`  · ${f.id.padEnd(30)}`);
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        await page.setViewportSize(f.viewport || DESKTOP);
        await page.goto(url, { waitUntil: "domcontentloaded" });
        await page.waitForSelector(f.wait, { timeout: 15000 });
        await settle(page);
        // Always assert the tab, never inherit whatever the card defaulted to.
        await showTab(page, f.tab || "detail");
        if (f.prepare) await f.prepare(page);
        if (f.hide) {
          await page.evaluate(
            (sels) => sels.forEach((s) => document.querySelectorAll(s).forEach((el) => el.remove())),
            f.hide,
          );
          await page.waitForTimeout(200);
        }

        const result = await page.evaluate(serializeSubtree, {
          selector: f.selector,
          scope: `#${f.id}`,
          expand: f.expand !== false,
          reset: FRAME_RESET,
        });
        result.html = await inlineAssets(page, result.html);
        captured.push({ ...f, ...result });
        console.log(`ok  ${result.width}×${result.height}  ${(result.html.length / 1024).toFixed(0)}kb`);
        break;
      } catch (err) {
        const why = err.message.split("\n")[0];
        if (attempt === 1) process.stdout.write(`retry (${why}) `);
        else console.log(`FAILED — ${why}`);
      }
    }
  }
} finally {
  await browser.close();
}

if (!captured.length) {
  console.error("Nothing captured — is the dev server running and design_seeds.exs applied?");
  process.exit(1);
}

const doc = renderDocument(screen, captured, {
  captured: new Date().toISOString().slice(0, 10),
  commit: `@${commit}`,
  screen: screenKey,
  // The design-canvas runtime is shared with the hand-authored mockups and lives
  // beside them, so link it relative to wherever --out put us.
  supportJs: relative(dirname(OUT), resolve(__dirname, "..", "docs", "designs")).split(sep).join("/") + "/support.js",
});

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, doc);
console.log(`\n→ ${OUT}  (${(doc.length / 1024).toFixed(0)}kb, ${captured.length}/${frames.length} artboards)`);
if (captured.length < frames.length) process.exitCode = 1;
