# ADR 0001 — Client architecture: LiveView-first, with a hybrid mobile app

## Status

Accepted

## Context

Hamaca needs a web app and a mobile app. Two goals shape the client architecture:

1. **Minimize duplicated code between web and native.**
2. **Minimize duplicated code between iOS and Android.**

Hamaca is intrinsically real-time: the baton passes between humans and AI agents, and the
board must update live for everyone watching. Phoenix LiveView fits that well, because UI
state and real-time push already live on the server.

The two goals pull apart. A cross-platform native framework unifies iOS and Android but, used
for everything, forces a second full UI plus an API, duplicating what LiveView already does.
Keeping everything in LiveView avoids that, but a pure webview wrapper can't do what a phone
is for here: push, voice, and one-tap decisions that feel native.

LiveView Native would reuse the LiveView server and render truly native views, but it is
pre-1.0 and its Android (Jetpack) client is not production-ready. Adopting it for iOS alone
would split the platforms, against goal 2.

## Decision

**The Phoenix LiveView app is the single source of truth for UI and real-time logic.** Every
content surface (board, card body, spec/plan, comments, mockups) is built once, in LiveView,
and serves both web and mobile.

**The mobile app is a hybrid.** It is a Flutter app (iOS-first) with two layers:

- **Native decision surfaces** — the small, stable screens where a human makes a quick decision
  that unblocks the baton, or that need a device capability (push, voice, biometrics, OS
  share/launch). They are fed by a human-authed JSON API, `/api/all` + `/api/auth/native`.
- **Embedded LiveView** — every content surface, loaded chromeless in a webview with the same
  session, so it stays real-time for free.

[ADR 0005](0005-mobile-app-scope-and-architecture.md) fixes the mobile app's scope: which
surfaces are native, and the native API that feeds them.

**Placement rule:** default to LiveView. Go native only for a decision surface or a device
capability. Never re-implement a content surface natively, never extend the agent board-key
`/api` for the app, and never add a mobile-only endpoint for something an embedded LiveView
already does.

**LiveView Native is the documented future path.** Because it reuses the same LiveView
server, adopting it is additive (new render targets for templates we already have), not a
rewrite. It is adopted for iOS and Android together, only once the Jetpack client is stable,
never one platform ahead of the other.

## Consequences

**Positive**

- Content is built once and is identical on web and mobile; iOS and Android share one Flutter
  codebase.
- Real-time works on mobile with no extra work: the embedded pages use the same LiveView socket.
- Native effort goes only where it pays: push, voice, and the decision surfaces.
- A non-rewrite path to fully native rendering stays open.

**Negative / accepted trade-offs**

- There is a second codebase (Flutter) and a second, human-authed API to maintain, kept small
  by the placement rule.
- Embedded LiveView pages must work chromeless and at phone width, or the seams show.
- Heavy offline use is not supported. If Hamaca needs rich offline sync, that reopens this
  decision.

## Alternatives considered

- **LiveView Native now.** Shares the server, but Android isn't production-ready, and it still
  means separate SwiftUI and Compose templates. Kept as the future path.
- **Flutter for everything, over a Phoenix API.** Unifies iOS and Android, but duplicates the
  whole web UI in Dart and needs an API for every surface. Rejected against goal 1.
- **Pure webview wrapper.** One codebase, but weak push and voice, and decisions feel like a
  web page. Rejected because the phone's job is the fast decision.
- **PWA only.** Lightest, but weak native integration and no real app-store presence.
