# 02 — Runs engine: execute a flow as a supervised state machine

**Why.** The heart of ADR 0006: Relay routes between nodes on typed outcomes, so gates,
retries, and resume are engine behavior instead of prompt-pleading.

**Scope.**

- New `Relay.Runs` context. A run = (card, flow) executed as a supervised process
  (`DynamicSupervisor` + `Registry`), with every state transition persisted to Postgres
  (run status, current node, per-node outcome/duration, attempt counts).
- Outcome routing on the closed set `succeeded / failed / partial / needs_input`;
  `max_retries` per node; `max_loops` per edge; `gate` failure reroutes or fails the run —
  never silently passes.
- `needs_input` checkpoints the run, blocks the card (existing needs-input machinery), and
  re-enters the same node when the answer arrives.
- Resume: on app restart, unfinished runs restore from Postgres and continue at the next
  node (no lost work between nodes).
- **Baton interplay (ADR 0006 §5).** A human claiming the card mid-run cancels the active
  node-job and parks the run at its last checkpoint; release/hand-back makes it
  schedulable again. A review **rejection** re-enters the flow with the CHANGES REQUESTED
  context (parity with today's resume mode). Engine writes to card state respect the
  card-state × stage-type validity rules (ADR 0003).
- Node execution goes through a dispatch behaviour ("give this node-job to an executor") so
  02 is testable with a fake executor before 04/05 exist.
- PubSub events per transition on `board:<id>:runs`.

**Out of scope.** Deciding *which* card starts a run (03), the real executor transport
(04/05), UI (07), `parallel` fan-out (defer to 09 if unneeded sooner).

**Acceptance criteria.**

1. With a stubbed executor, a Spec-shaped flow runs start → done and moves the card per its
   trigger; each transition is in Postgres and broadcast on PubSub.
2. A failing node retries `max_retries` times, then follows its `failed` edge or fails the
   run; the node's output lands on the card.
3. A `needs_input` outcome pauses the run and blocks the card; answering resumes the same
   node. Restarting the app mid-run resumes at the correct node.
4. Claiming the card mid-run cancels the active node-job and parks the run; rejecting a
   completed card re-enters the flow carrying the rejection note.
5. `mix precommit` passes.
