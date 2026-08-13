# Failure modes

Every way a card's journey can fail, grouped by **which machine detects it**, with how the system
handles it and where the card ends up absent human action. This is a current-state reference with
`file:line` anchors — where behavior and this page diverge, the code is the truth and this page is
a bug.

The decision and rationale behind this map live in
[ADR 0007](../adr/0007-card-lifecycle-and-failure-states.md); the per-state tables and the
generated transition graph live in [state.md](state.md); how work physically reaches an executor
is [runner.md](runner.md).

"Ends as" is the resting state absent human action.

## A. Node / engine failures

| # | Failure | Trigger | Handling | Ends as |
| --- | --- | --- | --- | --- |
| A1 | **Genuine human question** | node reports `needs_input` | park run `:needs_input`, block card; Listener resumes on answer with the stored `claude --resume` session (`listener.ex:108`); classified `:question` by `Relay.Runs.park_kind/1` | `parked/needs_input` |
| A2 | **Recoverable node failure** | node reports `failed`, retry budget left | re-enter the same node (`{:retry}`, `engine.ex:85`) | continues |
| A3 | **Routed failure → fixer** | `failed` with a `:failed` edge to a fix node | follow it (`precommit→final_fix`, `smoke→smoke_fix`, `sync→sync_fix`, …) | continues |
| A4 | **Escalated failure** | `failed` with a `:failed → needs_input` edge (RLY-194: `implement`, `*_fix`, `post`, `branch`) | park `:needs_input` for a human; classified `:escalation` by `Relay.Runs.park_kind/1` | `parked/needs_input` |
| A5 | **No route** | `failed` with no `:failed` edge, or budgets spent | `{:fail}` → run `failed` → `mark_failed` → card `failed` | `failed` |
| A6 | **Silent no-op** | `expects_commits` node reports `succeeded` but HEAD didn't move since the node was *entered* — per visit, not per attempt, so a retry still counts a commit an earlier attempt of the same visit made (RE298) | rewritten to `failed` before finalize (`override_no_op_success/4`, `run_server.ex`) → routes as A2–A5 | as A2–A5 |
| A7 | **Same error looping** | 3 identical `failure_signature`s | circuit breaker `{:fail}` even with budget left (`engine.ex:82`) | `failed` |
| A8 | **Runaway** | `max_loops` on an edge, or 20 node visits, exceeded | `{:fail}` | `failed` |
| A9 | **Unrouted non-failed outcome** | outcome (e.g. `partial`) with no matching edge | `degrade_to_failed` — follow the node's `:failed` edge, spending *its* budget (`engine.ex:145`) | as A3–A5 |
| A10 | **Broken baton** | a node declaring `writes` reports `succeeded` with a declared card field still blank | rewritten to `failed` before finalize (`override_missing_writes/4`, `run_server.ex`) → routes as A2–A5 | as A2–A5 |

**Telling A1 from A4 (RE253).** Both end as `parked/needs_input`, and the only surviving difference
in the database is the latest `NodeExecution.outcome` — `:needs_input` for A1, `:failed` for A4.
`Relay.Runs.park_kind/1` is the one function that reads that difference, and the inference is
exact: a `:needs_input` outcome parks in `Engine.decide/4` *before* edge routing is ever reached, so
the two cases cannot collide and no `parked_reason` value or schema column is needed to separate
them. The drawer renders A1 as the question the agent asked, and A4 as an answerable escalation —
the failed node and its attempt count, the failure output in a dark `<pre>`, an answer box that
resumes the node with the human's note as `findings`, and a Retry beside it. There is deliberately
no "agent stopped" dead end: an agent that dies environmentally reports `failed` exactly like a node
that ran and honestly failed, so the two are not distinguishable from the data and the UI must not
pretend otherwise.

## B. Plan / foreach

| # | Failure | Trigger | Handling | Ends as |
| --- | --- | --- | --- | --- |
| B1 | **Empty plan** | flow has a `foreach` but `PlanTasks.parse` yields `[]` | **no run created**; `block_on_unusable_plan` calls `request_input` explaining the missing `## Task N:` headings (`runs.ex:653`) — prevents merging an empty branch as "done" | card `needs_input`, no run |

## C. Scheduling & capacity (diagnostic — the card waits, no run fails)

`capacity_diagnosis/1` (`scheduler.ex:437`) classifies *why* a pull can't happen; these are
**verdicts**, not run states — the card sits `:ready`/`:queued` and is explained in the UI.

| # | Verdict | Condition |
| --- | --- | --- |
| C1 | `awaiting_capacity` | ≥1 live current executor, simply no free slot → card marked `:queued` |
| C2 | WIP-blocked | works-in stage at its `wip_limit` → flow halts, card stays `:ready` (does **not** queue) |
| C3 | `no_executor` | executor roster empty |
| C4 | `executor_gone` | roster non-empty but every executor's freshness is `:gone` |
| C5 | `executor_outdated` | every live executor is below `min_executor_version` (21) → claims get 409 `executor_outdated` (`node_job_controller.ex:38`). Normally transient: with `auto_update` on (the default) the refused executor upgrades itself and the card pulls on a later poll — see D4 |

## D. Executor lifecycle

| # | Failure | Trigger | Handling | Ends as |
| --- | --- | --- | --- | --- |
| D1 | **Executor died** | `last_heartbeat` older than `max(60s, 2×interval)` → `:gone` (`runs.ex:1172`) | reaper (30s) requeues `shared_clean` jobs to `:queued`; parks `exclusive` runs `:executor_gone` (keeps the pin) | `queued` / `parked/executor_gone` |
| D1t | **Executor died holding a talk turn** (RE268) | same trigger as D1, but the job is `kind: :talk` | **Nothing automatic.** The reaper deliberately skips talk jobs (`runs.ex:1860`) — requeueing one would hand a resumed `claude` session to a machine that does not hold it. The turn stays `claimed` and the pane keeps showing Stop | stranded until a human presses Stop (`Talk.stop_turn/1`, unconditional) |
| D2 | **Executor returns** | scheduler sees capacity | `Policy.resumable?/2` resumes `executor_gone` parks onto the pinned executor (`scheduler.ex:85`) | `running` |
| D3 | **Human take-over mid-run** | owner becomes `:human` | Listener revokes the job and parks `:claimed`; resumes fresh if handed back to AI (`listener.ex:100`) | `parked/claimed` |
| D4 | **Outdated executor** | version < 21 | 409 on claim; heartbeat still 200 and returns `required_version` **and** `latest_executor_version` (`node_job_controller.ex:142`). With `auto_update` on — the default in both `AUTO_UPDATE_DEFAULTS` and the project's `.relay/executor.json` — the executor downloads that version from the board's `/api/scaffold` and re-execs at a job boundary (RE185/RE304, `bin/relay:maybe_auto_update`; [runner.md "Auto-update (RE185)"](runner.md)). RLY-184's fail-stop is the fallback: auto-update off, refused, or it didn't take | **self-heals (auto-update)**; else card waits (C5) |
| D4t | **Pre-Talk executor on the board** (RE268) | executor version ≥ `min_executor_version` but < `min_talk_executor_version` (38) | the claim query narrows to `NodeJob.flow_kinds()` for that executor (`runs.ex:1096`), so it never SEES a talk job — flow work it still handles correctly keeps flowing. Without this it would claim the (deliberately unpinned, capacity-exempt) first turn, `KeyError` on the missing `isolation`, reject to the flow-only outcome route, 404, and leave the turn `claimed` forever — wedging Talk board-wide via `:turn_in_flight` | turn stays `queued` until a v38+ executor claims it |
| D5 | **Two executors, one identity** (same checkout **and** name) | second `relay execute` starts | singleton flock refuses it with the holder's pid (`bin/relay:acquire_singleton_lock`). Since RE305 two executors on one *host* are supported when they are different checkouts: the default name is `<checkout-dir>@<short-host>`, so they hash to different identity locks and their different `ROOT`s give different namespace locks ([runner.md "Single-process guarantee"](runner.md)) | second process exits only on a genuine identity/namespace collision |

## E. Worktree (exclusive runs)

| # | Failure | Trigger | Handling | Ends as |
| --- | --- | --- | --- | --- |
| E1 | **Branch mismatch** | exclusive worktree's HEAD ≠ the run's branch | executor **refuses to run** (would ship a subset / wrong branch, RLY-166); node fails (`bin/relay:1687`) → A2–A7 | `failed` after breaker |
| E2 | **Worktree contended** | a card's worktree is bound to another live run | `assign` refuses to steal it (`bin/relay:1403`) | job can't start |
| E2t | **Worktree contended by a deferred talk turn** (RE268) | a run's terminal disposition sits deferred (`pending_finish`) because a talk turn still occupies the same worktree, and a NEW run for that card is dispatched | `rec` is still `state="active"` bound to the OLD `run_id`, so E2's "different live run" branch refuses it (`bin/relay:1551` `release()`; [runner.md](runner.md) "Known gap"). The claim loop now **retries placement** for a bounded window (`PLACEMENT_ATTEMPTS` × `PLACEMENT_RETRY_S`, ~10s) before rejecting, so a refusal lasting one talk turn no longer fails the run | job waits, then runs; only a persistent miss fails |
| E3 | **Failed-run worktree retained** | exclusive run fails | worktree kept for retry (re-baselined on revive); evicted oldest-first past `max_retained_failed` (3) (`bin/relay:1597`). A retained tree a talk turn has since reattached to (`talk_users > 0`) is **excluded from candidacy** (RE268) — evicting it would delete the tree the running `claude -p` is working in | retained |

Per-card worktrees (`<ns>-<ref>`) replaced the old reused `<ns>-work-N` slot pool (RLY-231);
`min_executor_version` was raised to 21 to enforce it.

## F. Human review gate

| # | Path | Handling |
| --- | --- | --- |
| F1 | **Approve** | only on a `:review` stage; moves to the **next stage or substage** — the parent's Done sub-lane if one exists, else the next main stage; completes in place at the terminal stage (`Cards.approve/2`, `lib/relay/cards.ex:1234`) |
| F2 | **Reject** | requires a note; destination is *derived* (sub-lane → its parent; top-level → configured `reject_to_stage_id` or previous main stage); card forced `:ready` for rework, rejection embed set; Listener re-enters the flow with `changes_requested` context (`cards.ex:1252`, `listener.ex:141`) |

---
*Sources of truth: `lib/relay/runs/engine.ex`, `lib/relay/runs/run_server.ex`,
`lib/relay/runs/scheduler.ex`, `lib/relay/runs/listener.ex`, `lib/relay/runs.ex`,
`lib/relay/cards.ex`, `bin/relay`.*
