# 07 — Run visibility on the card

**Why.** Requirement 1 of ADR 0006 — the reason we stopped tolerating the black box. Run
state is now data in Postgres + PubSub; show it.

**Scope.**

- Card drawer gains a run panel: the flow's nodes with live status (pending / running /
  outcome), duration, attempt count; the active node's streamed log tail (build on the
  RLY-55 log sheet + RLY-112 run-id attribution rather than beside them).
- Board card face: small "node x/y" progress affordance while a run is active (palette per
  design system: AI = violet).
- Render the flow as a graph with the active node highlighted — Fabro's best visibility
  idea. Cut this to a follow-up card if it doesn't fit; the node list is the must-have.
- Match `docs/designs/` mockups; add/refresh Storybook stories for any new reusable
  component.

**Acceptance criteria.**

1. Watching a live Spec run: node status flips in real time without reload; failed nodes
   show their output; needs_input shows who holds the baton.
2. Completed runs remain inspectable (per-node outcomes/durations) after the fact.
3. Stories added; `mix precommit` passes.
