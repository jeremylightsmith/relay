# 09 — Decompose the Code flow (retire the /exec-plan black box)

**Why.** The payoff card of ADR 0006 — the black box this whole decision exists to open.
Also the riskiest: it re-implements execute-plan.js's orchestration as flow data + engine
features. Expect to split this at planning time; it is deliberately last.

**Scope.**

- Code flow per the ADR sketch: branch (shell) → implement (agent, iterating plan tasks) →
  review (agent) with `failed → implement` loop (`max_loops`) → precommit (`gate`) → smoke
  (agent) → merge (shell), under `exclusive` isolation.
- Engine features this flushes out: `foreach` over plan tasks (sequential), and — only if
  the flow genuinely needs it — `parallel` fan-out (deferred from 02; design settled in
  the ADR: git fork-and-join, ensemble-winner or map-merge, `skipped` for losers — an
  ensemble review panel here is its expected first customer).
- Review/smoke verdicts arrive via the agent-node outcome contract (04), replacing the
  `tmp/exec-plan-status` scratch-file gate.
- Task check-off mirrors to the card's `sub_tasks` as nodes complete (the old RLY thread,
  now native).
- Retire the Code entry from `relay_config.json` and the legacy watch path once the flow
  survives dogfooding on real cards. **Keep the legacy path revivable until then** (config
  entry restorable, watch code not deleted in the cutover PR): after this cutover the
  pipeline that ships fixes IS the new engine — if it breaks, fixes get hand-played, so
  the rollback lever must outlive the celebration.

**Known losses to reckon with (from the ADR).** The Claude Workflow engine's internal
journal/caching/StructuredOutput retries don't come along; per-node structured output is
our outcome contract now. Budget for tuning loops.

**Acceptance criteria.**

1. Dogfood: a real card goes Plan:Done → merged PR entirely through the flow, with
   per-node visibility (which task, which verdict) live on the card.
2. A refuted review demonstrably loops back to implement and converges or fails the run —
   never silently proceeds; the merge node is unreachable while precommit is red.
3. Legacy watch path removed; `relay_config.json` reduced to executor-local concerns or
   deleted. `mix precommit` passes.
