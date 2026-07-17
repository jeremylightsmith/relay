# 11 — Runners view: who's running, and what's on each

**Why.** The kanban is the *work-centric* view (cards, stages, whose turn). Debugging the
system needs the *machine-centric* view — every CI system has one (Buildkite agents,
GitHub runners): which runners are connected, what each is executing right now, and when
it last breathed. It answers the most common operational question — **"why is nothing
running?"** (no runner connected / runner wedged / card stuck mid-stage) — which today
means squinting at a terminal on the machine that runs `bin/relay watch`.

**Play early, on purpose.** This is the instrument panel for debugging the ADR 0006 build
itself. It's independent of cards 01–05, small, and pays for itself during the vertical
slice (06). Built as v0 against today's runner; cards 04/05 later swap the data source
without changing the page's shape.

**Scope (v0, against today's system).**

- **Heartbeat grows an identity.** `bin/relay watch` already posts in-flight refs every
  30s; the payload gains `{runner_id, host, started_at, refs}` (a few lines in
  `bin/relay`; `runner_id` stable per process).
- **Presence table server-side**: heartbeats land in an ETS-backed process (the
  `BoardWatch` pattern — no DB), broadcast on a new `board:<id>:runners` PubSub topic
  (add it to `docs/architecture/runtime.md` — the freshness gate applies).
- **`/board/:slug/runners` LiveView**, linked from the board header: one panel per
  runner — host, uptime, last-beat age (fresh / stale / gone thresholds), and its
  in-flight cards as ref links into the card drawer. Live feed lines under each runner via
  the existing `AgentLog` stream, grouped by the refs that runner reported.
- **Empty state**: "no runners connected", with the command to start one.
- **Upgrade path (not built now):** when 04/05 land, executor registration/claims replace
  the heartbeat as the data source, and a capacity-per-isolation-class column appears;
  the page's shape survives.

**Out of scope.** Remote control (pause/drain a runner), historical runs, per-node flow
progress (07 owns card-level run visibility).

**Acceptance criteria.**

1. With `relay watch` running, `/board/:slug/runners` shows the runner within one beat —
   host, uptime, and its in-flight refs; stopping the runner flips it to disconnected
   within two beat intervals, without a page reload.
2. Two runners (e.g. two processes) appear as two panels, each grouping only its own
   cards and feed lines.
3. While a card is being worked, its feed lines stream live under the owning runner.
4. With no runner, the empty state renders with the start command. `mix precommit` passes.
