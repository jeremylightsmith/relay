# 06 — Spec flow end-to-end (first vertical slice)

**Why.** The proof of the whole ADR 0006 architecture on the simplest flow: one agent node,
board-triggered, with the hardest cross-cutting behavior (needs_input pause/resume) already
in play. Everything before this card is testable in isolation; this is where it becomes real.

**Scope.**

- Wire the pieces: a card sitting in `Next up` starts a run via the scheduler (03) — no
  `bin/relay watch` involvement for Spec.
- The `brainstorm` agent node runs on the local executor under `shared_clean` isolation;
  its questions flow through needs-input; the answer resumes the node; success moves the
  card to `Spec:Review`.
- Retire the Spec entry from `relay_config.json` (Plan/Code entries stay on legacy watch).

**Out of scope.** Plan/Code migration (08/09), run UI (07 — the timeline note + logs are
enough here).

**Acceptance criteria.**

1. Dogfood: a real card pulled from `Next up` gets a spec written by the flow, including at
   least one needs-input round-trip, with zero `relay watch` involvement for Spec.
2. Concurrent Spec runs respect the executor's advertised `shared_clean` capacity and
   don't collide in its clean worktree.
3. A run whose node fails flags the card with the node's actual output (parity with
   today's `flag()` behavior).
4. `mix precommit` passes; `relay watch` still drives Plan/Code untouched.
