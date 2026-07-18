# The runner: how work physically gets done

**Today's system.** [ADR 0006](../adr/0006-workflow-orchestration.md) (Proposed) will
replace this shape with a server-side flow engine + thin executor; until those cards land,
this page describes what actually runs. The runner lives on a developer machine — it needs
the checkout, git worktrees, and the `claude` CLI — and talks to the deployed app only
through the board-key REST API.

`bin/relay` (Python, single file) is two things:

1. **A CLI** for every card operation an agent needs (`card`, `move`, `comment`,
   `needs-input`, `approve`, …) — the surface documented in
   [`../agent-integration.md`](../agent-integration.md).
2. **A board runner** (`relay watch`, or no arguments): a poll loop that drives ready
   cards through the pipeline defined in `relay_config.json`. The runner is generic — every
   board-specific fact (stages, prompts, worktree pools) lives in the config.

## The watch loop

Each tick (`poll_interval`, default 45s, plus a wake on any job finishing):

- **Scan**: fetch the board, then `find_all_ready` picks every dispatchable card —
  rightmost pipeline stage first; *resume* in-progress (`working`, unblocked) cards before
  pulling *fresh* ones; a stage's WIP limit counts the column plus its sub-lanes;
  `needs_input` and human-owned cards are skipped (ADR 0004); pool budgets are consumed as
  candidates are chosen so one tick never over-dispatches.
- **Dispatch**: each card runs on a worker thread in a worktree slot from its stage's pool.
  Pools (`relay_config.json`): after the Spec (RLY-136) and Plan (RLY-138) cutovers the watcher
  drives Code alone, and `pools` names exactly one entry — the `exclusive` `work` pool, giving
  each job its own `work-N`. The `shared` `clean` pool that once pointed N slots at one
  read-only worktree for Spec/Plan is **gone** — no stage references it anymore. Worktrees live
  under `.claude/worktrees/`, detached so they never collide with the root checkout.
  Exclusive slots are reset before use — leftovers are **stashed, never dropped** (a
  stranded edit once contained a real fix), then hard-reset and cleaned (`-fd`, keeping
  build caches).
- **Work** (`work()`): move a fresh card into the stage, set status `working`, run the
  stage's `action` steps in order — `{shell: cmd}` or `{claude: prompt}` (headless
  `claude -p --dangerously-skip-permissions`, stream-json events rendered live). Then:
  card asked a question → leave it blocked; a step failed → `flag()` posts an `[auto]`
  needs-input carrying the failing step's output tail; success → comment + move to the
  stage's `done` sub-stage.

## Side channels

- **Log mirror**: every feed line is queued to a background `LogForwarder` thread that
  batches `POST /api/board/logs` (best-effort: drops on full queue, swallows all errors) —
  landing in `Activity.LogSink` → the card timeline, and `AgentLog` → the live log sheet.
- **Heartbeat**: a background thread posts to `POST /api/board/heartbeat` every 30s
  (`interval`) — always, including when idle, so an idle-but-connected runner is
  distinguishable from no runner at all. The payload carries this runner's identity
  (`runner_id`, `host`, `started_at`, `interval`) plus a live manifest (`pools`, `jobs`,
  `refs`) built straight from the watch loop's `pools`/`in_flight` state (RLY-141). It
  feeds `Relay.RunnerPresence`, which the Runners view reads to show who's running and
  what's in flight.
- **Run ids**: each `work()` gets a UUID attached to its log lines (RLY-112) so a card's
  timeline can group lines by run.

Known sharp edges this design accepts (and ADR 0006 removes): stage-level granularity
only, the `tmp/exec-plan-status` scratch-file merge gate, and prompt-enforced rules.

## Dispatcher split during the ADR-0006 migration (RLY-136 → RLY-139)

Two dispatchers coexist while stages migrate off the legacy watcher:

- **Spec and Plan are engine-driven** (RLY-136, RLY-138): a card in *Next up* (Spec) or
  *Spec:Done* (Plan) is dispatched by the server-side `Relay.Runs.Scheduler` to the node-job
  engine (`Relay.Runs`), claimed by `relay execute` over the node-job REST API. Neither has a
  `relay_config.json` pipeline entry any more.
- **Code alone is still watcher-driven**: `relay watch` reads its `relay_config.json` pipeline
  entry and runs it the legacy way, until RLY-139 cuts it over too — at which point this whole
  section, and `relay watch`, retire.

A stage is on exactly one dispatcher at a time. The cutover ritual that guarantees this — and why
its order is fixed — is in [`../runbooks/flow-cutover.md`](../runbooks/flow-cutover.md).

**Shared-budget arbitration: Plan preempts Spec.** `Relay.Runs.Scheduler.plan/1` folds over
**all** enabled flows in one tick, sorted **rightmost `works_in` stage position first**
(`scheduler.ex:38-45`, rule documented at `scheduler.ex:9-13`), threading one shared capacity
accumulator through the fold. `Relay.Runs.Capacity` keys free slots
`executor_id => %{shared_clean: n, exclusive: n}` **per isolation class, not per flow**
(`capacity.ex:5-7`) — and Spec and Plan are both `:shared_clean`. So from the Plan cutover the
two flows draw from **one** `shared_clean` budget, and rightmost-first means **Plan takes
shared slots ahead of Spec** whenever both have eligible cards and capacity is scarce. This
matches the watcher's old single `clean` pool in total capacity, but the *ordering* — always
drain the right of the board (closer to Done) before pulling more in on the left — is new: it
is intended WIP discipline, not Spec starvation, even though under real scarcity it will look
like Spec is being starved. Pinned by `test/relay/runs/scheduler_test.exs` ("two flows sharing
one shared_clean budget (spec + plan)") and exercised live over the REST API by
`test/relay_web/api/plan_flow_e2e_test.exs` ("Spec and Plan enabled at once").

**Acceptance-criterion-2 finding (RLY-138).** The Plan cutover required **no engine or executor
change** — `Relay.Runs.Scheduler.plan/1` was already written flow-agnostic
(`scheduler.ex:38-45,91-97,130-144,202-207`) from the W9/W11 Spec work, so enabling a second
`:shared_clean` flow is pure configuration: seed data already present in
`Relay.Flows.DefaultLibrary`, an `enable_flow/1` toggle, and the `relay_config.json` /
`write-plan.md` edits described above. Every new test this card adds — both the pure-scheduler
arbitration cases and the `plan_flow_e2e_test.exs` REST-level cases — **passed on first run**
against the unmodified engine. That is the signal RLY-139 (Code) is betting on: adding a flow
to this engine is configuration, not code.

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
- **Executor heartbeat superset.** `BoardController.heartbeat/2` gained a third, independent,
  additive branch: a beat carrying `name` + `capacity` (on top of the RLY-141 watcher fields)
  calls `Relay.Runs.upsert_executor/2`, writing/refreshing a durable `Schemas.Executor` row
  (`{board_id, name}`, capacity map, `last_heartbeat`). It still calls
  `Relay.RunnerPresence.beat/2` exactly as before — the Runners view (RLY-141) is unchanged.
  A legacy or capacity-less beat never touches the `Executor` table.
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

`bin/relay execute` is the second runner mode: a thin, board-agnostic client of the node-job
transport above. `relay watch` (the whole "The watch loop" section above) is **byte-for-byte
untouched** — it keeps reading `relay_config.json` and posting to `/api/board/heartbeat`. The
two generations coexist on the same machine through the migration; nothing they touch overlaps.

- **Config.** `.relay/executor.json` (a separate file from `relay_config.json`) holds
  `name` (defaults to hostname), `namespace` (default `exec`), `capacity: {shared_clean,
  exclusive}`, `poll_timeout`, `heartbeat_interval`. Missing file → sensible defaults;
  capacity is the field a developer routinely edits.
- **Worktree namespace.** `ExecutorPool` maps every job's `isolation` onto worktrees under the
  `exec-*` namespace — disjoint from the watcher's `clean`/`work` pools — so a `relay watch` and
  a `relay execute` can run on the same checkout at once without contending over a worktree.
  `shared_clean` jobs share one reused `exec-clean` worktree (never reset per-job, only
  fast-forwarded to base when every shared slot is idle). `exclusive` jobs get a slot from a
  fixed `exec-work-1..N` pool, bound to a run from its first job until that run reaches a
  terminal `run_state` — the reset happens only on that first job, since a run's later nodes
  build on the diff its earlier nodes left in the worktree.
- **The claim/execute/report loop (`cmd_execute`).** Each iteration: advertise current free
  capacity per isolation class on a long-poll `POST /api/node-jobs/claim` (a read timeout is
  "no work", not an error); on a claim, hand the job to a worker thread bounded by the pool's
  free slots; the worker resets the slot if needed, runs the step (shell/gate via
  `_stream_shell`, agent via `_stream_claude_job`), and POSTs the typed outcome to
  `/api/node-jobs/:id/outcome`. `--once` drains a single claim→execute→report cycle and exits;
  `--dry-run` claims and mutates nothing (it only logs the capacity it would advertise);
  `--interval` overrides the configured poll timeout; SIGINT stops claiming new work and waits
  for in-flight workers to finish.
- **Heartbeat-borne revoke.** `ExecutorHeartbeat` POSTs `{executor, running: [job-ids]}` to
  `POST /api/node-jobs/heartbeat` every `heartbeat_interval`s and — unlike the watcher's
  `Heartbeat`, which discards the response body — reads back `{revoked: [job-ids]}` and
  terminates each one's live subprocess via its `JobControl`. A revoked **exclusive** job resets
  its worktree (salvaging any leftovers via `git stash`, same as `reset_worktree` elsewhere),
  since that worktree is bound 1:1 to this job/run. A revoked **`shared_clean`** job leaves
  `exec-clean` untouched instead — that worktree is shared by other jobs still running
  concurrently, and resetting it would destroy their work; it's only ever fast-forwarded once
  every shared slot is idle. Either way, no outcome is reported for a revoked job — the server
  already knows a revoked job never finished. **This endpoint is
  client-side only for now**: `bin/relay` posts to it, but no server route exists yet (the W9
  server currently only extends `/api/board/heartbeat` — see "Node-job transport" above); wiring
  the server-side revoke response is left to a follow-up card.

---
*Sources of truth: `bin/relay`, `relay_config.json`, `.relay/executor.json`,
`bin/test_relay.py`, `lib/relay_web/controllers/api/node_job_controller.ex`, `lib/relay/runs.ex`,
`lib/relay_web/controllers/api/board_controller.ex`.*
