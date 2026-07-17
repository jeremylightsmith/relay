# 08 — Migrate the Plan flow

**Why.** Second step of the ADR 0006 sequencing: same shape as Spec (one agent node), so it
should be almost pure configuration — this card is the test that adding a flow is cheap.

**Scope.**

- Enable the seeded Plan flow: pull from `Spec:Done`, run `write-plan` under `shared_clean`
  isolation, land on `Plan:Done`.
- Retire the Plan entry from `relay_config.json`; `relay watch` now handles only Code.
- Fix whatever Spec-specific assumptions this flushes out of 01–06.

**Acceptance criteria.**

1. Dogfood: a card with an approved spec gets its plan written by the flow end-to-end.
2. No engine/executor code changes needed beyond genuine bug fixes (if that fails, write
   down why — it's a signal the model is wrong before tackling Code).
3. `mix precommit` passes.
