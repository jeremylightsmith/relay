# 14 — Code column phase lanes (experiment)

**Why.** The thought experiment ("what if every node were a column?") surfaced one thing
worth keeping from World B: watching cards visibly move as their run progresses. The
kanban-safe version: the Code column renders the run's phases as **presentation-only
lanes** — a projection of the run, not stages.

**Scope.**

- Inside the Code column, lanes derived from the flow's phases: Building (the task
  loop) → Verify → Smoke → Accept → Ship. A card sits in the lane matching its run's
  current node and moves live as the run advances.
- **Rework never moves backward**: a review→implement loop renders as the card staying
  in Building with an attempt badge (kanban's rework idiom).
- Explicit non-goals, enforced in code review: lanes have **no** WIP limits, no
  notifications, no approve/reject affordances, no drag — they are read-only projection.
  Dragging a card still uses the column, not the lane.
- **No artboard exists for this** — the 2026-07-17 design pass skipped it and produced
  the Value Stream Map instead. Before building anything here, check whether the VSM
  (analytics view of the same signal) already scratches the itch; if not, get the
  artboard drawn first. Ship behind a board-settings toggle; judged after living with
  it — this card may end in removal, and that's a valid outcome.

**Acceptance criteria.**

1. With the toggle on and a card mid-run, the Code column shows the lanes and the card
   sits in the lane matching its current node; when the run advances phase, the card
   moves without reload.
2. A review-refuted loop shows the card staying in Building with an attempt badge —
   it never moves left.
3. Lanes expose no WIP/notification/approve affordances; card drag behaves exactly as
   without the toggle. Toggle off = today's column, pixel-identical.
4. Matches the artboard. `mix precommit` passes.
