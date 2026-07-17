# 07 — Run visibility on the card

**Why.** Requirement 1 of ADR 0006 — the reason we stopped tolerating the black box. Run
state is now data in Postgres + PubSub; show it.

**Scope.**

- **Run tab in the card drawer** (*Detail | Run | Activity*), matching
  `docs/designs/Relay Card Run Panel.dc.html` — all its states: mid-flight (node list
  with per-node duration/attempts/**cost**, failed node expanded with outcome detail,
  loop chip, task-progress bar, "running vN" chip), re-entry, parked, baton revoked,
  circuit breaker, history (collapsed totals: duration · nodes · $). One copy fix vs the
  artboard: the review-failed loop re-runs implement with a **fresh** session carrying
  the findings — only needs-input re-entry says "session resumed" (ADR rule).
- Board card face per `docs/designs/Relay Board Run Affordances.dc.html` — the full
  state strip: AI running (violet, node x/y), parked (amber), run failed (red, names the
  node), your review (blue), **queued** (enabled flow awaiting executor capacity), done
  (green, run totals travel with the card), cancelled (gray, claimed). Phone width
  included.
- Render the flow as a graph with the active node highlighted (mini graph per the
  artboard; the full renderer is shared with the flow editor card).
- Add/refresh Storybook stories for any new reusable component.

**Acceptance criteria.**

1. Watching a live Spec run: node status flips in real time without reload; failed nodes
   show their output; needs_input shows who holds the baton.
2. Completed runs remain inspectable (per-node outcomes/durations) after the fact.
3. Stories added; `mix precommit` passes.
