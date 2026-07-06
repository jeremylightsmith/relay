# ADR 0001 — Client architecture: LiveView-first with a thin native wrapper

**Status:** Accepted (2026-07-06)

## Context

Relay needs a web app and mobile apps (iOS + Android). Two goals shape the client
architecture, stated by the project owner:

1. **Minimize duplicated code between web and native.**
2. **Minimize duplicated code between iOS and Android.**

Relay is also intrinsically real-time — the "baton" passes between humans and AI agents and
the board must update live for everyone watching. Phoenix LiveView is an excellent fit for
that: UI state and real-time push already live on the server.

The tension: the two goals can pull in different directions. A cross-platform native
framework (e.g. Flutter) unifies iOS and Android but forces a *second* full UI plus an API
layer, duplicating everything the LiveView app already does. Conversely, keeping everything
in LiveView minimizes web↔native duplication but needs a strategy to reach the app stores.

### State of LiveView Native (researched 2026-07)

LiveView Native is attractive because it reuses the LiveView server and would let us render
*truly* native views. But as of mid-2026 it is **not ready to bet both platforms on**:

- The framework is still pre-1.0 (core `~0.4.0-rc`).
- The **SwiftUI** client is the most mature, but still a release candidate.
- The **Jetpack/Android** client is **explicitly not production-ready** — the maintainers say
  the API is still being finalized and it has not been announced for general use.

Shipping native SwiftUI on iOS while Android lags would directly violate goal #2 (it splits
the platforms). So LiveView Native is a *future* option, not a *now* option.

## Decision

**The Phoenix LiveView web app is the single source of truth for UI and real-time logic.**
Mobile ships as a **thin native wrapper** (Hotwire/Turbo-Native-style shell) around that same
LiveView UI:

- **One UI codebase** (LiveView/HEEx) for web and mobile.
- **One shared mobile shell** covering iOS and Android — a small native host providing app
  navigation, push notifications, and store presence around the web content.
- **No separate mobile client and no separate API** are maintained today.

**LiveView Native is the documented upgrade path.** Because it reuses the same LiveView
server, adopting it later is *additive* (add SwiftUI/Compose render targets to templates we
already have), not a rewrite. We will adopt it **for iOS and Android together**, only once
the Jetpack client is stable — never one platform ahead of the other.

## Consequences

**Positive**

- Near-zero duplication across web↔native and iOS↔Android — both goals satisfied.
- Real-time works on mobile for free (it's the same LiveView socket).
- Features are built once, in LiveView. Product velocity stays high.
- A clean, non-rewrite path to true-native rendering when Android is ready.

**Negative / accepted trade-offs**

- The mobile experience is web-rendered inside a native shell, not fully native widgets.
  Acceptable for a board-centric, connection-oriented product; revisited via LiveView Native.
- Heavy offline use is not a first-class capability of this approach. If Relay later needs
  rich offline/sync, that is the trigger to re-open this decision (a new ADR).
- We depend on a wrapper toolkit's LiveView compatibility for native navigation/hand-off.

**Implications for contributors (see also `AGENTS.md`)**

- Build features in LiveView. Do **not** stand up a parallel mobile UI or a bespoke API
  "for the app" — the app *is* the LiveView UI.
- Keep UI logic in the server/LiveView layer so it is inherited by every client.

## Alternatives considered

- **LiveView Native now** — shares the server, but Android isn't production-ready and you
  still maintain separate SwiftUI + Compose templates (three UI layers). Deferred to roadmap.
- **Flutter + Phoenix API** — unifies iOS/Android, but duplicates the entire web UI in Dart
  and requires a parallel API/Channels surface. Highest total duplication; rejected against
  goal #1.
- **PWA only** — lightest possible, single codebase, but weak native integration and no real
  app-store story. Kept as a fallback but insufficient as the mobile plan.
