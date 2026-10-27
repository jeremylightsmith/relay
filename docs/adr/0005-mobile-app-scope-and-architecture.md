# ADR 0005 — Mobile app: a decision companion, native where it decides

## Status

Accepted

## Context

Hamaca's home is the desktop board. The phone is a companion for keeping work moving when
you're away from your desk: unblock the AI and make the decisions only a human can make. The
north-star metric is **median time-to-unblock**, how fast the AI gets its answer once it's
stuck.

[ADR 0001](0001-client-architecture.md) makes LiveView the single home for UI and real-time
logic, with the mobile app as a hybrid of native decision surfaces and embedded LiveView. This
ADR fixes what belongs on the phone and which parts of it are native. The design sources are
`docs/designs/Relay Mobile Brief.dc.html` (the platform brief) and
`docs/designs/Relay Mobile.dc.html` (the tappable Inbox and Board prototype).

## Decision

### What mobile is, and isn't

- **Is:** answer the AI's questions; review a finished card and approve or reject it; glance at
  status; get pushed the moment the AI is blocked on you.
- **Isn't:** writing specs or plans from scratch, building or restructuring boards, long-form
  writing, heavy multi-card reorganising, admin, billing or integrations.
- **Rule of thumb:** more than a minute of typing or more than one screen of layout belongs on
  the web board. The phone is for the decision, not the production.

### The two primary actions

- **Answer a request for input:** a paused AI's question (pick an option, a short reply, a
  direction); the work resumes at once. Structured questions render in a **native stepper**
  that reads the same question format the web uses.
- **Review, then approve or reject:** approve advances the card; reject takes a note. Neither is
  a blind tap: you decide from the card screen, with the card in view, never from an inbox row.
  After a decision the app **auto-advances** to the next item, ending on an empty state.
- **Text entry is voice-first:** on-device dictation streams words into the field at the
  cursor (Apple SpeechTranscriber on iOS 26+, WhisperKit as the fallback), with a slim toolbar
  above the keyboard; typing works too.
- Supporting context opens over the decision and dismisses back to it, so you never lose the
  approve/reject bar. A card's PR opens in the GitHub app.

### Architecture: two layers over one backend

- **Layer 1 — Native (Flutter, iOS-first):** push and its onboarding, sign-in (Google and Sign
  in with Apple), the tab bar and navigation, the Needs-you inbox, the review approve/reject bar
  and the reject note, the answer stepper, voice dictation, the new-card sheet, the board
  switcher (list, star, mute), and settings.
- **Layer 2 — Embedded LiveView (chromeless):** the board (moves included), the card body
  (`/cards/:ref`, the drawer alone), spec and plan, comments, and mockups. These are never
  re-implemented natively.
- **Shared:** one domain and data model, and one signed-in user. Native sign-in mints the
  Phoenix session, whose cookie the webviews reuse, plus a user API token for `/api/all`.

Decision surfaces are small and stable, so they're cheap to build natively and worth the
polish. Content surfaces are large and fast-changing, so they're never maintained twice. A
native surface not listed above is added by amending this ADR in the same branch; the
placement rule is in [ADR 0001](0001-client-architecture.md) and `AGENTS.md`.

### The inbox and the count

- The **Needs-you inbox** is user-wide across boards and holds only the two decision types:
  cards in `needs_input` and `in_review` (`Hamaca.Cards.needs_you_feed/1`). It leaves out the web
  board's third, ready-awaiting-human flavor, so the mobile count deliberately differs from the
  web board's `needs_you_rollup`.
- The **app-icon badge** counts the same two types, minus boards you muted
  (`Hamaca.Push.needs_you_count/1`). The in-app inbox still shows muted boards.

### Notifications: push is the product

- A push fires when a card enters `needs_input` or `in_review`
  (`Hamaca.Push.notification_statuses/0`). Progress and status never push. Muting a board stops
  its pushes.
- One card is one push. Tapping it opens that card, never a generic inbox.
- Quiet hours rely on the OS's Do Not Disturb; there are no in-app notification settings
  beyond per-board mute.

### Decided, not yet built

A native spec sheet, a native pinch-zoom screenshot viewer, @mentions in comments and their
push, collapsing bursts into one "N cards need you" push, Android, and later a biometric gate
on approve, widgets, and an offline action queue.

## The native API

Human-authed, and never the agent board-key `/api`. Full detail is in
[`docs/architecture/domain.md`](../architecture/domain.md) and
[`docs/architecture/runtime.md`](../architecture/runtime.md).

`/api/auth/native` (native sign-in to a Phoenix session):

- `POST /google`
- `POST /apple`
- `GET /me`

`/api/all` (the session cookie for device registration, the `relayu_` user API token for the
rest):

- `POST /devices`
- `DELETE /devices/:token`
- `POST /cards`
- `GET /feed`
- `GET /boards`
- `POST /boards/:slug/star`
- `POST /boards/:slug/mute`
- `GET /cards/:ref`
- `POST /cards/:ref/approve`
- `POST /cards/:ref/reject`
- `POST /cards/:ref/answer`

## Consequences

**Positive**

- The decision loop is fast and native where it counts, and content is shared with the web
  rather than rebuilt.
- One feed query backs the inbox, so the inbox and the native API can't drift.

**Negative / accepted trade-offs**

- There is a Flutter codebase and a human-authed JSON API to maintain beside LiveView.
- Embedded LiveView pages need the chromeless embed mode and must work at phone width, or the
  seams show.
- The mobile count differs from the web board's on purpose, and the badge differs from the
  inbox for muted boards. Both definitions have to be kept in their one place each.
- `/api/all` takes two credentials (session cookie for devices, user API token for the rest).

## Alternatives considered

- **Pure webview wrapper.** Cheapest, but weak at push, voice and screenshots, and decisions
  feel like a web page.
- **Full native rebuild.** Best feel, but duplicates the whole product and doubles every
  change, against ADR 0001's goals.

## Open questions

- What is the minimum viable way to preview the app being built from a phone: a live build, a
  recorded walkthrough, or screenshots only?
- Once LiveView Native's Android client is production-ready, could it replace the native
  decision layer and let the `/api/all` API go away?
