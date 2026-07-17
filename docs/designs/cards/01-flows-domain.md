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
- Validation: node types, outcomes, and isolation from the closed sets; edges reference
  existing nodes; exactly one `start`; trigger stages must exist on the board.
- Seed the default library as data: Spec and Plan flows (single agent node each), Code flow
  (branch → implement ⇄ review → precommit gate → smoke → merge, per the ADR sketch).

**Out of scope.** Executing anything (02), per-project overrides (09), UI.

**Acceptance criteria.**

1. Default flows are seeded per board and readable through the context API.
2. Invalid flows (unknown node type, unknown outcome, edge to a missing node, trigger
   naming a nonexistent stage) are rejected with changeset errors.
3. Boundary compiles clean; `mix precommit` passes.
