# The runner: how work physically gets done

**Today's system.** [ADR 0006](../adr/0006-workflow-orchestration.md) landed a server-side
flow engine + thin executor for every stage — Spec (RLY-136), Plan (RLY-138), and Code
(RLY-139, this doc's most recent cutover). The legacy board-runner (`relay watch`,
`relay_config.json`, `.claude/workflows/execute-plan.js`) is **deleted**; there is no
fallback dispatcher to describe. The executor lives on a developer machine — it needs the
checkout, git worktrees, and the `claude` CLI — and talks to the deployed app only through
the board-key REST API.

`bin/relay` (Python, single file) is two things:

1. **A CLI** for every card operation an agent needs (`card`, `move`, `comment`,
   `needs-input`, `approve`, …) — the surface documented in
   [`../agent-integration.md`](../agent-integration.md).
2. **`relay execute`** — the only runner mode: a poll loop that claims node-jobs from the
   server and runs them (see "Executor mode" below).

## Dispatch is server-side

A card in any AI-enabled stage is dispatched by `Relay.Runs.Scheduler` (folding over every
enabled `Flow` on the board, rightmost `works_in` stage position first) straight to the
node-job engine (`Relay.Runs`) — no per-stage config file, no board-runner poll loop.
`relay execute` claims the resulting `NodeJob` rows over the node-job REST API (below) and
runs whatever node it is handed; it knows nothing about stages, columns, or which flow a
job belongs to. Board-specific facts (stages, prompts, per-node budgets) live entirely in
`Flow`/`Flow.Node`/`Flow.Edge` rows, seeded from
[`docs/designs/flows/`](../designs/flows/README.md) and editable in Settings › Flows.

**Shared-budget arbitration: rightmost flow wins ties.** `Relay.Runs.Capacity` keys free
slots `executor_id => %{shared_clean: n, exclusive: n}` **per isolation class, not per
flow** (`capacity.ex:5-7`), and `Relay.Runs.Scheduler.plan/1` threads one shared capacity
accumulator through its fold, sorted rightmost `works_in` stage position first
(`scheduler.ex:38-45`, rule documented at `scheduler.ex:9-13`). So when two flows share an
isolation class and both have eligible cards under scarce capacity, the flow closer to Done
draws first — intended WIP discipline, not starvation, even though under real scarcity it
looks like the leftward flow is being starved. Pinned by
`test/relay/runs/scheduler_test.exs` and exercised live over the REST API by
`test/relay_web/api/plan_flow_e2e_test.exs` / `test/relay/runs/code_flow_e2e_test.exs`.

## Side channels

- **Log mirror**: every feed line is queued to a background `LogForwarder` thread that
  batches `POST /api/board/logs` (best-effort: drops on full queue, swallows all errors) —
  landing in `Activity.LogSink` → the card timeline, and `AgentLog` → the live log sheet.
- **Executor heartbeat (client-side only)**: `ExecutorHeartbeat` posts `{executor,
  running: [job-ids]}` to `POST /api/node-jobs/heartbeat` every `heartbeat_interval`s,
  expecting `{revoked: [job-ids]}` back so it can terminate each revoked job's live
  subprocess (see "Node-job transport" below) — but no server route exists yet
  (`router.ex` registers only `/node-jobs/claim` and `/node-jobs/:id/outcome`), so the
  POST 404s and no subprocess is ever terminated. Revoke is DB-state-only today
  (`Relay.Runs.NoopDispatcher.revoke/1` → `:ok`); wiring the response is a follow-up.
- **Run ids**: each executor worker tags its log lines with the claimed job's `run_id`
  (RLY-112) so a card's timeline can group lines by run.

## Node-job transport (RLY-134, ADR 0006 card 04)

The first slice of ADR 0006's target shape: a pure REST transport on top of the runs engine
(W5, `Relay.Runs`), board-key auth like the rest of `/api`, no scheduling/dispatch policy —
that stays server-side.

- `POST /api/node-jobs/claim` (`RelayWeb.Api.NodeJobController.claim/2`) — upserts the
  advertising executor (a claim doubles as a liveness touch, via
  `Relay.Runs.upsert_executor/2`) then atomically claims the oldest eligible `queued`
  `NodeJob` (`Relay.Runs.claim_next_job/1`, `SELECT … FOR UPDATE SKIP LOCKED`). Long-polls
  up to ~25s on the `board:<id>:runs` topic when nothing is immediately claimable (`?wait=0`
  short-polls instead); serialises the raw `run` + resolved `vars` W5 already stored, never
  a worktree path. **Eligibility respects exclusive affinity (ADR 0006 §5):** an *unpinned*
  job (`executor_name` nil) needs advertised free capacity in its isolation class, but a job
  *pinned* to the requesting executor (`executor_name` = its name) is claimable regardless of
  advertised capacity — the executor is already holding that run's bound worktree slot.
  Pinning is set at enqueue: `Relay.Runs.insert_job!/3` pins every job of an `exclusive` run
  after the first to the executor that claimed the first, so an `exclusive` run's later nodes
  and its needs-input **resume** always return to the machine holding its worktree (and a
  parked run whose holder advertises `exclusive: 0` can still be handed its own resume — the
  fix for the affinity deadlock; the executor keeps polling while it holds bound slots via
  `ExecutorPool.has_bound_slots/0`).
- `POST /api/node-jobs/:id/outcome` (`.outcome/2`) — `Relay.Runs.get_claimed_job/2` (board-
  scoped, 409 `conflict` if the job isn't `claimed`/`running`), then
  `Relay.Runs.report_outcome/2` against the closed outcome set (422 `unknown_outcome`
  otherwise).
- **Executor heartbeat superset.** `BoardController.heartbeat/2`'s `/api/board/heartbeat`
  route carries an independent, additive branch: a beat carrying `name` + `capacity` calls
  `Relay.Runs.upsert_executor/2`, writing/refreshing a durable `Schemas.Executor` row
  (`{board_id, name}`, capacity map, `last_heartbeat`). It still calls
  `Relay.RunnerPresence.beat/2` exactly as before, feeding the Runners view (RLY-141). A
  capacity-less beat never touches the `Executor` table.
- **Executor liveness + reclaim.** `Relay.Runs.ExecutorReaper` (supervised, see
  [`runtime.md`](runtime.md)) periodically calls `Relay.Runs.reclaim_stale_executors/0`:
  a stale executor's (`Relay.Runs.executor_stale?/2`) in-flight `shared_clean` jobs go back
  to `queued`; its `exclusive` runs are parked (`Relay.Runs.park_for_reclaim/1`,
  `parked_reason: :executor_gone`) rather than requeued, since exclusive runs are pinned to
  one executor's worktree.
- **Log `node_job_id` convergence.** `POST /api/board/logs` entries may carry an optional
  `node_job_id` alongside `run_id` — same nullable-string shape, not an FK. It rides through
  `Relay.AgentLog.stamp/1` → `Relay.Activity.LogSink.row/2` → `activities.node_job_id`, kept
  for W6's run panel to key log lines off a specific node-job.
- The full outcome-file contract (`RELAY_NODE_OUTCOME`) executors must honor is documented in
  [`../agent-integration.md`](../agent-integration.md#node-job-protocol-adr-0006).

## Executor mode (`relay execute`) (RLY-135, ADR 0006 card 05)

`bin/relay execute` is **the only runner mode**: a thin, board-agnostic client of the
node-job transport above. It knows the Relay REST API and how to execute a node-job;
nothing else — every board-specific fact lives server-side as flow data.

- **Config.** `.relay/executor.json` holds `name` (defaults to hostname), `namespace`
  (default `exec`), `capacity: {shared_clean, exclusive}`, `poll_timeout`,
  `heartbeat_interval`. Missing file → sensible defaults; capacity is the field a developer
  routinely edits.
- **Worktree namespace.** `ExecutorPool` maps every job's `isolation` onto worktrees under
  the `exec-*` namespace. `shared_clean` jobs share one reused `exec-clean` worktree (never
  reset per-job, only fast-forwarded to base when every shared slot is idle). `exclusive`
  jobs get a slot from a fixed `exec-work-1..N` pool, bound to a run from its first job
  until that run reaches a terminal `run_state` — the reset happens only on that first job,
  since a run's later nodes build on the diff its earlier nodes left in the worktree.
- **The claim/execute/report loop (`cmd_execute`).** Each iteration: advertise current free
  capacity per isolation class on a long-poll `POST /api/node-jobs/claim` (a read timeout is
  "no work", not an error); on a claim, hand the job to a worker thread bounded by the pool's
  free slots; the worker resets the slot if needed, runs the step (shell/gate via
  `_stream_shell`, agent via `_stream_claude_job`), and POSTs the typed outcome to
  `/api/node-jobs/:id/outcome`. `--once` drains a single claim→execute→report cycle and exits;
  `--dry-run` claims and mutates nothing (it only logs the capacity it would advertise);
  `--interval` overrides the configured poll timeout; SIGINT stops claiming new work and waits
  for in-flight workers to finish.
- **Heartbeat-borne revoke (not yet wired server-side).** `ExecutorHeartbeat` POSTs
  `{executor, running: [job-ids]}` to `POST /api/node-jobs/heartbeat` every
  `heartbeat_interval`s, expecting `{revoked: [job-ids]}` back so it can terminate each
  one's live subprocess via its `JobControl`. **In reality no server route exists yet** —
  the POST 404s, the client never sees a revoke list, and no subprocess is ever
  terminated. Revoke is DB-state-only (`Relay.Runs.NoopDispatcher.revoke/1` → `:ok`, the
  configured dispatcher per `config/config.exs:73`); the behavior described next is what
  happens once the response is wired, not what happens today. A
  revoked **exclusive** job resets its worktree (salvaging any leftovers via `git stash`,
  same as `reset_worktree` elsewhere), since that worktree is bound 1:1 to this job/run. A
  revoked **`shared_clean`** job leaves `exec-clean` untouched instead — that worktree is
  shared by other jobs still running concurrently, and resetting it would destroy their
  work; it's only ever fast-forwarded once every shared slot is idle. Either way, no outcome
  is reported for a revoked job — the server already knows a revoked job never finished.

### Agent node → `.claude/agents` definition

A flow node of type `agent` may name an `agent` (e.g. `plan-implementer`). The server
carries it in the job payload (`Relay.Runs.build_payload/4` → the claim response's
`agent`), and `bin/relay`'s `_stream_claude_job` appends `--agent <name>` to the
`claude -p` invocation: the agent file supplies the system prompt, the node's `run`
string stays the user prompt. An unknown name makes the CLI fail loudly rather than
silently fall back to the default agent (verified against CLI 2.1.214), which is the
property that makes this safe to depend on. A node with no `agent` invokes exactly as
it did before RLY-139.

**Fallback if `--agent` ever regresses:** delegate by name from the node's `run` prompt
— `"Use the spec-reviewer subagent to review …"`. It works today with zero new plumbing
and needs no schema change.

---
*Sources of truth: `bin/relay`, `.relay/executor.json`, `bin/test_relay.py`,
`lib/relay_web/controllers/api/node_job_controller.ex`, `lib/relay/runs.ex`,
`lib/relay_web/controllers/api/board_controller.ex`.*
