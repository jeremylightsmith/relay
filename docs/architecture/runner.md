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
  Pools (`relay_config.json`): a `shared` pool points N slots at one read-only worktree
  (Spec/Plan); an `exclusive` pool gives each job its own `work-N` (Code). Worktrees live
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
  a worktree path.
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
- The full outcome-file contract (`RELAY_OUTCOME_PATH`) executors must honor is documented in
  [`../agent-integration.md`](../agent-integration.md#node-job-protocol-adr-0006).

---
*Sources of truth: `bin/relay`, `relay_config.json`, `bin/test_relay.py`,
`lib/relay_web/controllers/api/node_job_controller.ex`, `lib/relay/runs.ex`,
`lib/relay_web/controllers/api/board_controller.ex`.*
