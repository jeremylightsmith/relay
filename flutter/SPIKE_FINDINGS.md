# Spike: embedding Relay's LiveView inside a Flutter iOS app

**Date:** 2026-07-12 · **Verdict: ✅ It works.** All three risky unknowns cleared.

## Question

Can Relay's existing **LiveView web UI run embedded inside a Flutter iOS app**, with
(1) an authenticated session, (2) a live websocket, and (3) acceptable native↔web feel?
(This is the "one risk" flagged in the mobile brief / ADR 0005 — reused web views inside a
thin native shell.) This is *not* LiveView Native; it's a `WKWebView` hosting the same
LiveView the desktop uses.

## Setup

- Flutter iOS app in `relay/flutter/` (monorepo alongside the Phoenix app). Toolchain pinned
  via `mise` (flutter 3.44.1 + ruby 4.0.5 for CocoaPods), matching `../rotation`.
- Two surfaces = the whole hybrid in miniature: a **native Flutter inbox** (`InboxScreen`)
  that taps into an **embedded LiveView board** (`CardWebView`, `flutter_inappwebview`).
- **Auth bridge:** native `dio` hits `/dev/login`, captures the `_relay_key` session cookie,
  and injects it into the webview cookie store *before* load — the realistic production path
  (native auth → webview inherits the session).
- Ran on the iPhone 17 simulator against the local dev server (`localhost:4003`), pointed at a
  seeded `spike` board (`priv/repo/spike_seed.exs`). One-line ATS exception in `Info.plist`
  (`NSAllowsLocalNetworking`) to allow `http://localhost` in the webview.

## Results

| Unknown | Result | Evidence |
| --- | --- | --- |
| **1. Auth handoff** | ✅ Board renders **signed-in** — the "DU" (dev user) avatar and real cards appear. Native cookie injection authenticated the embedded LiveView. | `02-embedded-board.png` |
| **2. Live websocket in the webview** | ✅ Added a card from a *separate* web client (Playwright) — it pushed into the embedded webview **with no reload** (Backlog 2→3, UNSTARTED 3→4). The LV socket is live inside `WKWebView`. | `03-realtime.png` |
| **3. Native↔web feel** | ✅ Renders as the mobile board-as-document (RLY-62). Native blue AppBar on top, web content below; loads in well under a second after a warm build. | both |

## The one real seam

**Double header.** The native Flutter AppBar ("Spike Board") sits directly above the
LiveView's own top chrome (Relay logo, "Boards / Spike…" breadcrumb, terminal icon, avatar).
Two headers stacked reads as two apps for a moment. For production the embedded LiveView needs
a **"chromeless" / embedded mode** that hides its own web header (and any nav the native shell
owns) when hosted in the app — the brief's "budget design time so the seams don't show." This
is a LiveView responsive concern, not a Flutter blocker.

## Effort / notes

- **First iOS build** ≈ pod install (~2s) + xcodebuild (~25s); warm rebuilds are fast.
- Auth handoff was ~20 lines of Dart (grab cookie, `CookieManager.setCookie`, load).
- Gotcha hit during the spike: **two iPhone 17 sims were booted**, so `simctl … booted`
  targeted the wrong one — always drive by explicit UDID.
- `flutter_inappwebview` still uses CocoaPods (no SPM yet) — harmless, just a warning.

## Recommendation

The hybrid architecture in ADR 0005 is **viable on Flutter**: native decision surfaces around
reused LiveView content, authenticated and realtime, works today. The main product work this
surfaces:

1. An **embedded/chromeless mode** for the LiveView surfaces we plan to reuse (card, board,
   spec) — hide the web header when hosted natively. *(Card this.)*
2. Confirm the same cookie-injection path works with **real Google OAuth** (rotation already
   does Google sign-in → session cookie; same shape).
3. The native shell needs data for the native inbox/action bar → the REST API (the one RLY-67
   is trimming). Reconfirms the ADR-0005 "small API for decision surfaces" direction.

## How to run

```bash
cd flutter && mise trust
mise exec -- flutter run -d <iphone-udid>                     # native inbox → tap into board
mise exec -- flutter run -d <iphone-udid> --dart-define=WEB_HOME=true   # straight to embedded board
# server: local Phoenix on :4003; seed the board with: mix run priv/repo/spike_seed.exs
```
