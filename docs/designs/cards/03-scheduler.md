# 03 — Scheduler: server-side dispatch (find_all_ready moves home)

**Why.** The most subtle logic in today's runner is deciding *what to work next* —
`find_all_ready`: right-to-left stage priority, resume-before-fresh, WIP limits counted
across a column's sub-lanes, the human-owned claim rule, per-pool budgets. ADR 0006 moves
it server-side. It deserves its own card and its own tests; buried inside the vertical
slice it would silently double that card's size.

**Scope.**

- A scheduler in `Relay.Runs`: given the board state, the enabled flows' triggers, active
  runs, and connected executors' advertised capacity per isolation class, decide which
  cards start (or resume) runs this tick.
- Preserved rules from `find_all_ready`, now server-side and unit-tested: rightmost stage
  first; resume in-progress before pulling fresh; WIP limits count a column plus its
  sub-lanes; `needs_input` cards skipped; human-owned cards off-limits (ADR 0004); budgets
  consumed as candidates are chosen so one tick never over-dispatches.
- **Executor affinity**: every node-job of an `exclusive` run is dispatched to the
  executor holding its worktree; if that executor is gone, the run parks (never
  reassigned mid-run).
- Event-driven rather than polled where cheap: card moves / answers / executor
  connections already broadcast on PubSub — the scheduler reacts, with a slow tick as
  backstop.
- Pure decision core (board snapshot in, dispatch list out) so the rules are testable
  without processes — same property today's `find_all_ready` has.

**Out of scope.** Executing anything (02 routes, 04/05 execute), trigger schema (01).

**Acceptance criteria.**

1. Unit tests port today's dispatch semantics: rightmost-first, resume-before-fresh, WIP
   across sub-lanes, human-owned exclusion, no over-dispatch in one pass — all pass
   against the pure core.
2. With zero connected executors (or zero capacity for the required isolation), nothing
   dispatches and nothing errors; capacity appearing triggers dispatch without waiting a
   full tick.
3. A card answered out of `needs_input` is picked up as a resume, not a fresh pull.
4. `mix precommit` passes.
