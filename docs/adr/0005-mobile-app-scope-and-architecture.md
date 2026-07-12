# ADR 0005 — Mobile app: scope and hybrid native-shell architecture

**Status:** Draft (2026-07-12) — the hybrid direction is **validated by a spike** and the
V1/V1.1 scope is broken into cards (see "Resolved decisions" + "Card breakdown"). A few genuine
questions remain open; not yet Accepted.

**Related:** builds on / refines [ADR 0001](0001-client-architecture.md) (LiveView-first with
a thin native wrapper). Source: `docs/designs/Relay Mobile Brief.dc.html` (platform brief
v0.1) and `docs/designs/Relay Mobile.dc.html` (tappable Inbox & Board prototype).

## Context

Relay's home is the desktop board. Mobile is **not** a second copy of it — it's a *companion*
for keeping work moving when you're away from your desk: unblock the AI and clear the
decisions only a human can make. The design question the brief answers is *what belongs on a
phone* and *how much is native vs. reused web*.

This ADR interacts with ADR 0001. That ADR fixed "one UI codebase (LiveView/HEEx); mobile is
a thin native wrapper providing navigation, push, and store presence; no separate mobile
client." The brief **pushes past a pure wrapper**: it proposes building a handful of *decision
surfaces natively* (inbox list, approve/reject bar, answer field) while reusing LiveView for
the *content surfaces* (card body, spec/plan, board columns, comments). Whether that is a
refinement of ADR 0001 or a partial supersede is an **open decision** (see below).

## Proposed decisions (from the brief — to confirm/refine)

### 1. What mobile is / isn't
- **Is:** respond to the AI's requests for input; review a finished card and approve/reject;
  glance at status; get pushed the moment the AI is blocked on you.
- **Isn't:** authoring specs/plans from scratch; building/restructuring boards; long-form
  writing or heavy multi-card reorg; admin/billing/integrations.
- **Rule of thumb:** more than a minute of typing or more than one screen of layout → it
  belongs on the web board. Mobile is for the *decision*, not the *production*.

### 2. Surfaces
- **Inbox — the front door (KEEP).** A single "Needs you" queue fed by push; where ~80% of
  sessions start and end.
- **Board — the map (KEEP).** Fuller picture, one stage at a time, swipe between stages, tap
  into any card. Read-mostly, with review actions available inline.
- **Stream — conversational feed (DROP).** Reframes structured work as chat and buries the
  status model; the Inbox already delivers the "AI needs you" moment.

### 3. The two primary actions
- **Respond to a request for input** — answer a paused AI's question (option / short reply /
  direction); work resumes immediately.
- **Review → approve or reject** — approve to advance, or reject with a reason. Neither is a
  blind tap; both require supporting context first (§4).
- **Text entry is voice-first** — tap-to-speak, transcribed on-device (Whisper); type if
  preferred.
- **Secondary (supported, not the point):** hand a card to the AI, move a card between
  stages, comment/reply, reply by voice, search, reassign.

### 4. Supplemental context (opens *over* the decision, dismisses back to it)
- **Spec / plan** → web sheet.
- **PR on GitHub** → deep-links into the GitHub app (don't rebuild the diff).
- **Comments (soon with screenshots)** → web thread + a native image viewer (pinch-zoom,
  full-screen).
- **Principle:** you never lose the approve/reject bar by going to look at something.

### 5. Architecture — hybrid thin native shell + reused web views
Neither extreme: a pure webview wrapper can't push or handle screenshots well; a full native
rebuild duplicates the product and doubles every change.
- **Layer 1 — Native shell (Swift/Kotlin):** push, tab bar & navigation, inbox list,
  approve/reject bar, sheets & in-app browser, screenshot viewer, biometrics/share, voice
  (Whisper).
- **Layer 2 — Web content (reused LiveView):** card body, spec & plan docs, responsive board
  columns, comment threads, live app preview.
- **Layer 0 — Shared core:** one API & data model, same auth session, realtime sync (web ⇄
  mobile).
- **Rationale:** decision surfaces are small/stable (cheap to build native, worth the polish);
  content surfaces are large/fast-changing (don't maintain twice). **Key risk:** the reused
  web views must be genuinely mobile-responsive or the seams show.

### 6. Notification model (push is the product)
- **Fires on:** card ready for review, AI asks a question, or an @mention. Progress/status
  never push.
- **Batching:** one card = one push; bursts collapse into "N cards need you."
- **Quiet hours:** respected by default; wake to a batched digest.
- **Badge:** app icon badge = count of items in "Needs you"; hits zero when caught up.
- **Tap:** deep-links straight to the card, never a generic inbox.

### 7. Ship plan
North-star metric: **median time-to-unblock** (how fast the AI gets its answer once stuck).
- **V1 · the loop:** login & push opt-in; push → card review; approve/reject + note;
  needs-input answer; needs-you + empty state; basic notification settings.
- **V1.1 · context:** board (read + move); boards list; comments + screenshots; spec sheet;
  open in GitHub.
- **Later · depth:** voice everywhere; biometric gate on approve; widgets / Live Activity;
  offline action queue; multi-board switching.

## Resolved decisions (spike + planning, 2026-07-12)

**Spike — the hybrid works.** A Flutter/iOS spike (`flutter/`, `flutter/SPIKE_FINDINGS.md`)
embedded the LiveView board inside a native app: **native session** (cookie injection) +
**live websocket inside `WKWebView`** + acceptable feel. The one seam — a **double header** —
is the origin of the chromeless-embed work (RLY-79). This answers the **A0001-reconciliation**
question: **ADR 0005 refines ADR 0001** — we build a few native decision surfaces + a
session-authed JSON API to feed them, and reuse LiveView (chromeless) for content. The "one UI
codebase / thin wrapper" stance holds for **content surfaces**, not for the small decision
surfaces.

**Scope decisions locked (→ card refs):**
- **Auth:** Google **and Sign in with Apple** (App Store 4.8); native provider → Phoenix
  session → cookie injection into the webviews. (RLY-78)
- **Inbox:** **user-wide / cross-board**, and **only the two decision types** (needs-input +
  in-review) — *not* the web board's third "awaiting-human" flavor. The **F4 feed and F5 badge
  use this same two-type definition**, so the mobile count deliberately diverges from
  `needs_you_rollup`. (RLY-80, RLY-85, RLY-81)
- **Review context (V1):** approve/reject on the **embedded card body alone** is enough for V1;
  spec sheet / comments / Open-in-GitHub arrive in V1.1. (RLY-87)
- **Decision flow:** after a decision, **auto-advance to the next needs-you item**
  (queue-clearing to zero → empty state). (RLY-88)
- **Board:** the **embedded LiveView owns the board**, move included, for now — no native move
  sheet yet; revisit by feel. (RLY-94)
- **Comments:** **text-only reply** (resolves brief Q4); screenshot *upload* deferred; a
  **native** pinch-zoom viewer handles *viewing* attachments. (RLY-96, RLY-97)
- **Structured question options** ("pick an option") ride on **RLY-71** (Make questions
  smoother), not a new mobile feature. (RLY-89)
- **Voice:** **voice-first entry is V1** (not Later), **on-device Whisper** (not OS dictation).
  (RLY-99)
- **@mentions:** don't exist yet; comments-only @mentions is a **separate cross-cutting
  feature** (RLY-82) that unblocks F5's deferred @mention push trigger.
- **Notification settings:** **skipped for now** — quiet hours rely on **OS Do-Not-Disturb**;
  re-enable push via OS settings until a dedicated settings card exists. (RLY-90)
- **Platform:** **iOS-first**; Android is a parked epic (RLY-103), adopted per ADR 0001's
  "iOS + Android together" rule for any true-native path.

**Card breakdown** (on the board, tagged `mobile`; foundations first via `/brainstorm RLY-77`):
Foundations **RLY-77–81** (+ @mentions **RLY-82**); V1 **RLY-83–90** + **RLY-99**;
V1.1 **RLY-91, 94–98**; Later **RLY-100–103**.

## Open questions (still genuinely open)

- **Q1 (brief).** Can you reject *from the inbox* without opening the card, or does reject
  always force a look at context first? (Affects RLY-85 / RLY-87.)
- **Q2 (brief).** Minimum viable "click around the app" preview on a phone — live build,
  recorded walkthrough, or screenshots only?
- **LiveView Native.** Does this hybrid make ADR 0001's LiveView-Native path more or less
  likely — and could it later collapse the F4 API away? Revisit when the Jetpack client is
  production-ready.
- **Mobile-responsiveness of reused surfaces.** Which LiveView views already work at phone
  width (RLY-62 board scroll) vs. need dedicated mobile design before embedding — per-surface
  polish lives in RLY-87 / 91 / 94 / 96.
- **Structured-question rendering.** Native stepper (consume RLY-71's JSON wire format) vs.
  reuse RLY-71's web stepper via the embedded webview. (RLY-89.)

## Consequences

**Positive**
- Ships the decision loop fast on a **proven foundation** (spike: auth + realtime inside the
  webview work today), reusing LiveView for the large, fast-changing content surfaces.
- Near-zero duplication for content; native investment concentrated on the small, stable
  decision surfaces.

**Negative / accepted trade-offs**
- Introduces a **native codebase** (Flutter) and a **session-authed JSON API** for the decision
  surfaces — a deliberate refinement of ADR 0001's "no separate client / no separate API."
- Reused LiveView surfaces need a **chromeless embed mode** (RLY-79) and genuine mobile
  responsiveness, or the seams show.
- The mobile "needs you" count **diverges** from the web board's `needs_you_rollup` — must be
  kept consistent across F4 / F5 / inbox by design.

## Alternatives considered

- **Pure webview wrapper** — cheapest, but can't push well or handle screenshots; feels cheap.
- **Full native rebuild** — best feel, but duplicates the whole product and doubles every
  future change; violates ADR 0001's duplication goals.
- **Hybrid (chosen direction)** — native decision surfaces + reused web content. Captured
  above; details open.
