# Failure modes

Every way a card's journey can fail, grouped by **which machine detects it**, with how the system
handles it and where the card ends up absent human action. This is a current-state reference with
`file:line` anchors — where behavior and this page diverge, the code is the truth and this page is
a bug.

The decision and rationale behind this map live in
[ADR 0007](../adr/0007-card-lifecycle-and-failure-states.md); the per-state tables and the
generated transition graph live in [state.md](state.md); how work physically reaches a runner
is [runner.md](runner.md).

"Ends as" is the resting state absent human action.

## A. Node / engine failures

| # | Failure | Trigger | Handling | Ends as |
| --- | --- | --- | --- | --- |
| A1 | **Genuine human question** | node reports `needs_input` | park run `:needs_input`, block card; Listener resumes on answer with the stored `claude --resume` session (`listener.ex:108`); classified `:question` by `Relay.Runs.park_kind/1` | `parked/needs_input` |
| A2 | **Recoverable node failure** | node reports `failed`, retry budget left | re-enter the same node (`{:retry}`, `engine.ex:85`) | continues |
| A3 | **Routed failure → fixer** | `failed` with a `:failed` edge to a fix node | follow it (`precommit→final_fix`, `smoke→final_fix`, `spec_review→fix_findings`, `sync→sync_fix`, …) | continues |
| A4 | **Escalated failure** | `failed` with a `:failed → needs_input` edge (RLY-194: `implement`, `*_fix`, `post`, `branch`) | park `:needs_input` for a human; classified `:escalation` by `Relay.Runs.park_kind/1` | `parked/needs_input` |
| A5 | **No route** | `failed` with no `:failed` edge, or budgets spent | `{:fail}` → run `failed` → `mark_failed` → card `failed` | `failed` |
| A6 | **Silent no-op** | `expects_commits` node reports `succeeded` but HEAD didn't move since the node was *entered* — per visit, not per attempt, so a retry still counts a commit an earlier attempt of the same visit made (RE298) | rewritten to `failed` before finalize (`override_no_op_success/4`, `run_server.ex`) → routes as A2–A5. **Unless** the node asserted `--no-changes` AND this node already committed for what it is bound to (RE310) — then the `succeeded` stands | as A2–A5 |
| A6b | **Work already committed** | an `expects_commits` node is re-entered onto work its own earlier visit already committed, so it *cannot* move HEAD (RE306) | the failure detail names the exit (`relay outcome succeeded --no-changes`) instead of repeating "produced no commits"; a human can also `relay advance <ref>` / press "Task already done — continue" to check the task off and move on (`Runs.advance_foreach/2`) | recoverable — previously an inescapable loop |
| A7 | **Same error looping** | 3 identical `failure_signature`s (only `failed` rows count — a `blocked` row never does, A11) | circuit breaker `{:fail}` even with budget left (`engine.ex:82`) | `failed` |
| A8 | **Runaway** | `max_loops` on an edge, or 20 node visits, exceeded | `{:fail}` | `failed` |
| A9 | **Unrouted non-failed outcome** | outcome (e.g. `partial`) with no matching edge | `degrade_to_failed` — follow the node's `:failed` edge, spending *its* budget (`engine.ex:145`) | as A3–A5 |
| A10 | **Broken baton** | a node declaring `writes` reports `succeeded` with a declared card field still blank | rewritten to `failed` before finalize (`override_missing_writes/4`, `run_server.ex`) → routes as A2–A5 | as A2–A5 |
| A11 | **Agent could not run (infrastructure)** | an agent node's `claude -p` exits non-zero with an auth or usage-limit signature in its stream — expired OAuth session, invalid key, `billing_error`, a usage limit with **no known reset** (phrase match only), or a usage-limit wait past the cap (A11b) (RE308) | the runner reports `blocked` (`classify_claude_failure`, `./relay`) with `agent could not run: <reason>` and no `resume_at`; the engine parks *before* the breaker and retry rules (`{:park, :blocked}`, `engine.ex`), so no `max_retries`, breaker count or `max_loops` is spent; the attempt's session is dropped (`finalize_job!/2`) and the Listener never `--resume`s it; classified `:infrastructure` by `Relay.Runs.park_kind/1`, revivable by Retry | `parked/needs_input` |
| A11b | **Usage limit with a known reset (waits it out)** | as A11, but the job's own stream carried a rejected `rate_limit_event` with `resetsAt` (RE267) | the runner reports `blocked` **plus** `resume_at` (`blocked_resume_at`, `./relay`); the engine returns `{:requeue, node}` (`engine.ex`): RunServer inserts attempt +1 of the same visit/binding with a verbatim copy of the blocked job's payload, logs one `:action` line (`usage limit — waiting for reset at …; node … will re-run (wait N of 3)`), and the run stays `running` with the AI baton. The refused runner has already paused its own claiming until the reset (RE320), so while every runner is paused the run face shows the C7 **Rate limited · resumes …** verdict; an unlimited runner may claim it at once. No retry, breaker count or `max_loops` is spent. After `Engine.max_usage_limit_waits/0` (3) consecutive waits on one node the next one parks as A11 | continues (`running`), else `parked/needs_input` |

**Telling A1, A4 and A11 apart (RE253, RE308).** All three end as `parked/needs_input`, and the
only surviving difference in the database is the latest `NodeExecution.outcome` — `:needs_input`
for A1, `:blocked` for A11, anything else (`:failed`, or a degraded `:partial`) for A4.
`Relay.Runs.park_kind/1` is the one function that reads that difference, and the inference is
exact: `:needs_input` and `:blocked` both park in `Engine.decide/4` *before* edge routing is ever
reached, so no two cases can collide and no `parked_reason` value or schema column is needed to
separate them. An A11b wait never parks at all — `resume_at` on the `:blocked` row is what
`Engine.decide/4` reads to requeue instead — so it never reaches `park_kind/1` until the wait past
the cap, which is an ordinary A11. The drawer renders A1 as the question the agent asked; A4 as an answerable
escalation — the failed node and its attempt count, the failure output in a dark `<pre>`, an
answer box that resumes the node with the human's note as `findings`, and a Retry beside it; and
A11 as **Agent could not run** — the cause in the same `<pre>` and a Retry, with no answer box (the
fix is outside the card: log back in, or — for a limit with no known reset, or after three waits
(A11b) — wait for it to reset) and no attempt count (none
was spent). RE253 deliberately had no "agent stopped" state, because an agent that died
environmentally was indistinguishable in the data from one that honestly failed. RE308 made it
distinguishable: the runner classifies a non-zero `claude -p` exit from the stream itself (the
assistant event's `error` tag, the result's `api_error_status`, a rejected `rate_limit_event`, then
a phrase fallback) and reports `blocked` instead of `failed`. An expired login therefore no longer
spends the retry budget, trips the breaker, or hands the next node `agent exited non-zero` as a
phantom finding. A non-zero exit with no such signature is still `failed`, now with the stream's
last words in its detail.

**Telling a silent no-op from work already done (RE310).** Both look identical at the moment of
the report — an `expects_commits` node saying `succeeded` with HEAD unmoved — and the engine tells
them apart with a SECOND baseline. `baseline_sha/2` is HEAD before this **visit**;
`binding_baseline_sha/2` is HEAD before this **binding** (the node's first execution for this
sub-task, or its first visit in the run when it has none). When the binding baseline differs from
the reported sha, this node has already committed for this work, and that is the only situation in
which a `--no-changes` assertion is honoured. Both are one query — `baseline_before/2` — at
different boundaries, so they cannot drift. The nil handling is deliberately asymmetric: the guard
**fails open** on a missing sha ("a missing row is not evidence of a lie"), the claim check **fails
closed** (the burden of proof is on the claimant).

## B. Plan / foreach

| # | Failure | Trigger | Handling | Ends as |
| --- | --- | --- | --- | --- |
| B1 | **Empty plan** | flow has a `foreach` but `PlanTasks.parse` yields `[]` | **no run created**; `block_on_unusable_plan` calls `request_input` explaining the missing `## Task N:` headings (`runs.ex:653`) — prevents merging an empty branch as "done" | card `needs_input`, no run |

## C. Scheduling & capacity (diagnostic — the card waits, no run fails)

These are **verdicts**, not run states — the card sits `:ready`/`:queued` and is explained in the
UI. C0 is decided before capacity is even consulted (`Relay.Runs.Policy.pullable?/1`); C1-C7 come
from `capacity_diagnosis/1` (`scheduler.ex:437`), which classifies *why* an otherwise-eligible
pull can't happen.

| # | Verdict | Condition |
| --- | --- | --- |
| C0 | `blocked_by_dependencies` | card declares blockers that have not reached a top-level Done column (RE93); `evidence.blocked_by` names their refs. Fresh pulls only — a run in flight and a rejection re-entry both continue |
| C1 | `awaiting_capacity` | ≥1 live current runner, simply no free slot → card marked `:queued` |
| C2 | WIP-blocked | works-in stage at its `wip_limit` → flow halts, card stays `:ready` (does **not** queue) |
| C3 | `no_runner` | runner roster empty |
| C4 | `runner_gone` | roster non-empty but every runner's freshness is `:gone` |
| C5 | `runner_outdated` | every live runner is below `Relay.Runs.min_runner_version/0` (57 since RE311) → claims get 409 `runner_outdated` (`node_job_controller.ex:38`). Normally transient: with `auto_update` on (the default) the refused runner upgrades itself and the card pulls on a later poll — see D4 |
| C6 | `resume_refused` | a parked run's resume is refused on every tick; `evidence.resume_refused_reason` names why and `evidence.resume_refused_since` when it started (RE297) — see D6 for what happens when it persists |
| C7 | `runner_rate_limited` | every live, current runner has paused itself at its Claude usage limit (`.relay/runner.json` `limits`, or Claude refused a call) — RE320. Transient by design: each runner resumes at its window's `resets_at` (or earlier on an under-limit probe); `evidence.resumes_at` is the earliest. A run's own queued job reads the same verdict in `diagnose/3` |

## D. Runner lifecycle

| # | Failure | Trigger | Handling | Ends as |
| --- | --- | --- | --- | --- |
| D1 | **Runner died** | `last_heartbeat` older than `max(60s, 2×interval)` → `:gone` (`runs.ex:1172`) | reaper (30s) requeues `shared_clean` jobs to `:queued`; parks `exclusive` runs `:runner_gone` (keeps the pin) | `queued` / `parked/runner_gone` |
| D1t | **Runner died holding a talk turn** (RE268) | same trigger as D1, but the job is `kind: :talk` | **Nothing automatic.** The reaper deliberately skips talk jobs (`runs.ex:1860`) — requeueing one would hand a resumed `claude` session to a machine that does not hold it. The turn stays `claimed` and the pane keeps showing Stop | stranded until a human presses Stop (`Talk.stop_turn/1`, unconditional) |
| D2 | **Runner returns** | scheduler sees capacity | `Policy.resumable?/2` resumes `runner_gone` parks onto the pinned runner (`scheduler.ex:85`); a resume that can never be placed is reported, clocked and aged out instead of waiting forever — D6 | `running`, or `failed` after 30m (RE297) |
| D3 | **Human take-over mid-run** | owner becomes `:human` | Listener revokes the job and parks `:claimed`; resumes fresh if handed back to AI (`listener.ex:100`) | `parked/claimed` |
| D4 | **Outdated runner** | version below `Relay.Runs.min_runner_version/0` (57 since RE311 — the release channel changed shape on the wire) | 409 on claim; heartbeat still 200 and returns `required_version` **and** `latest_runner_version` (`node_job_controller.ex:142`). With `auto_update` on — the default in both `AUTO_UPDATE_DEFAULTS` and the project's `.relay/runner.json` — the runner downloads that version from the board's `/api/scaffold` and re-execs at a job boundary (RE185/RE304, `./relay:maybe_auto_update`; [runner.md "Auto-update (RE185)"](runner.md)). RLY-184's fail-stop is the fallback: auto-update off, refused, or it didn't take | **self-heals (auto-update)**; else card waits (C5) |
| D4t | **Pre-Talk runner on the board** (RE268) | runner version ≥ `min_runner_version` but < `min_talk_runner_version` (`max(39, min_runner_version/0)`, so 57 today) | the claim query narrows to `NodeJob.flow_kinds()` for that runner (`runs.ex:1096`), so it never SEES a talk job — flow work it still handles correctly keeps flowing. Without this it would claim the (deliberately unpinned, capacity-exempt) first turn, `KeyError` on the missing `isolation`, reject to the flow-only outcome route, 404, and leave the turn `claimed` forever — wedging Talk board-wide via `:turn_in_flight` | turn stays `queued` until a talk-capable runner claims it |
| D5 | **Two runners, one identity** (same checkout **and** name) | second `relay start` starts | singleton flock refuses it with the holder's pid (`./relay:acquire_singleton_lock`). Since RE305 two runners on one *host* are supported when they are different checkouts: the default name is `<checkout-dir>@<short-host>`, so they hash to different identity locks and their different `ROOT`s give different namespace locks ([runner.md "Single-process guarantee"](runner.md)) | second process exits only on a genuine identity/namespace collision |
| D6 | **Resume refused forever** | `Policy.resumable?/2` says yes while `take_slot/3` says `:none` on every tick — flow row deleted (`isolation: nil`), pin unresolved, pinned runner absent from capacity, or the class is simply full | `plan/1` reports the refusal; `record_resume_refusals/3` stamps `resume_refused_since`/`_reason`; the reaper's `abandon_unresumable_runs/1` fails the run after `unresumable_after_s/0` (30m), clearing the pin only when `Schemas.Run.pin_unhonourable_refusal_reasons/0` proves it can never be honoured | `failed` → human `retry`, which re-adopts the flow working the card's stage when the row is gone ([runner.md "Re-adoption"](runner.md)) (RE297) |
| D7 | **Runner holds a worktree the queued job needs** (RE311) | a run ended server-side (cancel/finish) while the runner was down, or a revoke left the tree `active` and bound — the runner still holds the card's exclusive worktree, so the card's next job has no slot | every beat declares `held` (`[{ref, state}]`, `Schemas.Runner.holding_states/0`); the server answers with `release_held`, the subset whose card's runs have ALL ended, and the runner tears down (`done`/`cancelled`) or retains (`failed`). Keyed on the **card ref**, which survives a restart — the retired run-id keying could not name a `recover()`ed tree at all. Within the beat window a retry is placed in the card's own idle tree by `assign` rather than refused | slot freed on the next beat |

## E. Worktree (exclusive runs)

| # | Failure | Trigger | Handling | Ends as |
| --- | --- | --- | --- | --- |
| E1 | **Branch mismatch** | exclusive worktree's HEAD ≠ the run's branch | runner **refuses to run** (would ship a subset / wrong branch, RLY-166); node fails (`./relay:1687`) → A2–A7 | `failed` after breaker |
| E2 | **Worktree contended** | a card's worktree is bound to another **live** run, or holds a terminal disposition deferred under a talk turn (E2t) | `assign` refuses to steal it. An IDLE tree bound to an earlier run of the SAME card is **adopted**, not refused (RE311) — the tree's identity is the card's branch, so a retry after a cancel continues in it instead of failing with "no free 'exclusive' slot" | job can't start (live run only) |
| E2t | **Worktree contended by a deferred talk turn** (RE268) | a run's terminal disposition sits deferred (`pending_finish`) because a talk turn still occupies the same worktree, and a NEW run for that card is dispatched | `rec` is still `state="active"` bound to the OLD `run_id`, so E2's "different live run" branch refuses it (`./relay:1551` `release()`; [runner.md](runner.md) "Known gap"). The claim loop now **retries placement** for a bounded window (`PLACEMENT_ATTEMPTS` × `PLACEMENT_RETRY_S`, ~10s) before rejecting, so a refusal lasting one talk turn no longer fails the run | job waits, then runs; only a persistent miss fails |
| E3 | **Failed-run worktree retained** | exclusive run fails | worktree kept for retry (re-baselined on revive); evicted oldest-first past `max_retained_failed` (3) (`./relay:1597`). A retained tree a talk turn has since reattached to (`talk_users > 0`) is **excluded from candidacy** (RE268) — evicting it would delete the tree the running `claude -p` is working in | retained |

Per-card worktrees (`<ns>-<ref>`) replaced the old reused `<ns>-work-N` slot pool (RLY-231);
`min_runner_version` was raised to 21 to enforce it (RE311 has since raised it to 57 — see
D4 and D7).

## F. Human review gate

| # | Path | Handling |
| --- | --- | --- |
| F1 | **Approve** | only on a `:review` stage; moves to the **next stage or substage** — the parent's Done sub-lane if one exists, else the next main stage; completes in place at the terminal stage (`Cards.approve/2`, `lib/relay/cards.ex:1234`) |
| F2 | **Reject** | requires a note; destination is *derived* (sub-lane → its parent; top-level → configured `reject_to_stage_id` or previous main stage); card forced `:ready` for rework, rejection embed set; Listener re-enters the flow with `changes_requested` context (`cards.ex:1252`, `listener.ex:141`) |

---
*Sources of truth: `lib/relay/runs/engine.ex`, `lib/relay/runs/run_server.ex`,
`lib/relay/runs/scheduler.ex`, `lib/relay/runs/listener.ex`, `lib/relay/runs.ex`,
`lib/relay/cards.ex`, `./relay`.*
