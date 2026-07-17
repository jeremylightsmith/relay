# 01 — Flows domain: flow definitions as data + default library

**Why.** ADR 0006: flows are declarative graph data owned by Relay, not per-project config
or code. This card creates the vocabulary everything else builds on.

**Scope.**

- New `Relay.Flows` context (own sub-boundary per ADR 0002, exported from `Relay`).
- Schemas for a flow: key, trigger (pulls-from / works-in / done — stored as stage **ids**,
  names for display, so renames don't break flows), isolation requirement (`shared_clean` /
  `exclusive` — worktrees and concurrency stay executor-local per ADR 0006), nodes (closed
  type set: `agent`, `shell`, `gate`, `parallel`, `human`), edges (`from`, `to`, `on`
  outcome, `max_loops`).
- **Versioning**: every save bumps the flow's `version`; a run snapshots the version it
  started on, so edits never mutate in-flight work.
- Validation: node types, outcomes, and isolation from the closed sets; edges reference
  existing nodes; exactly one `start`; trigger stages must exist on the board; **at most
  one enabled flow per pulls-from stage per board** (two would race for the same card).
- Seed the default library as data. The authored seed definitions live in
  [`docs/designs/flows/`](../flows/README.md) — a faithful translation of today's
  `relay_config.json` + `execute-plan.js` (Spec/Plan single agent node each; Code as the
  full nine-phase graph), with the open modeling questions listed in its README
  (per-task loops, findings re-entry, mid-run rebase).

**Out of scope.** Executing anything (02), per-project overrides (09), UI.

**Acceptance criteria.**

1. Default flows are seeded per board and readable through the context API.
2. Invalid flows (unknown node type, unknown outcome, edge to a missing node, trigger
   naming a nonexistent stage) are rejected with changeset errors.
3. Boundary compiles clean; `mix precommit` passes.
