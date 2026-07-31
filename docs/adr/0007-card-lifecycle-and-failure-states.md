# ADR 0007 — Card lifecycle: the happy path and every failure mode

## Status
Proposed (2026-07-22)

## Context

A card moving through Relay is driven by **four coupled state machines** and a scheduler that
places work on executors. When any one of them fails, the card can end up blocked, failed,
parked, or — worse — silently stuck in a state no single document explains. Almost every engine
incident we've hit reduces to *"two of the machines disagreed and nobody had written down how the
disagreement is supposed to resolve."* Recent live examples, all from the same week:

- a plan whose task headings used an em-dash parsed to zero tasks and parked the card
  `needs_input` with a machine string as the "question" (RLY-206 / RLY-209);
- a restart bounced straight back to `needs_input` because no exclusive slot was free — a
  capacity condition wearing a human-question costume (RLY-232);
- an exclusive run was terminally `failed` by the circuit breaker after a **worktree collision**
  repeated 8× — an infrastructure condition, not a code bug (RLY-231);
- a `smoke` node **passed**, but the success outcome was lost when the executor restarted
  mid-report, leaving the run wedged `:running` forever (RLY-230);
- runs outlived their cards — zombie `:running` rows on Done cards, and a parked run holding an
  exclusive slot it wasn't using (RLY-157 / RLY-233).

This ADR writes down, in one place: the machines and their vocabularies, the **happy path**, and
**how each known failure mode is handled** — with `file:line` anchors so it can be kept honest.
It builds on [ADR 0003](0003-card-state-stage-type-validity.md) (card state × stage type),
[ADR 0004](0004-card-ownership-and-the-claim-rule.md) (ownership / the baton), and
[ADR 0006](0006-workflow-orchestration.md) (Relay owns the graph). The authoritative per-state
tables live in [`docs/architecture/state.md`](../architecture/state.md); this ADR is the *why*
and the failure-handling map that sits above them.

## Decision

Adopt this document as the reference map for a card's life. It is **descriptive of current
behavior** (with source anchors) plus a **Known gaps** section we commit to tracking and closing.
Where behavior and this map diverge, the code is the truth and this ADR is a bug — fix one or the
other.

### The four coupled machines (+ the baton)

| Machine | Values | Owner |
| --- | --- | --- |
| **Card status** | `ready` · `queued` · `working` · `needs_input` · `in_review` · `failed` | `Relay.Cards` (`lib/schemas/card.ex:41`) |
| **Run status** | `running` · `parked` · `done` · `failed` · `cancelled` | `Relay.Runs.Transitions` (`lib/relay/runs/transitions.ex`) |
| **Node-job state** | `queued` · `claimed` · `running` · `done` · `revoked` | `Relay.Runs.Dispatcher` |
| **Node outcome** | `succeeded` · `failed` · `partial` · `needs_input` | reported by the executor |

Two derived facts sit on top: **the baton** — `active_owner_type/1` is `:human`, `:ai`, or `nil`,
derived from owners (`lib/relay/cards.ex:627`), and ADR 0004 makes it exclusive and permanent
(provenance, never handed back); and **Done** — not a status but a *derivation*: a `:ready` card on
the board's terminal stage reads as Done (`Cards.done?/2`, `lib/relay/cards.ex:704`). A `:ready`
card in a mid-board `:done` sub-lane (Spec:Done, Plan:Done) is merely *parked waiting to be
pulled* — **this distinction is load-bearing and is where Gap 1 lives.**

Two nuances worth pinning down now, because they cause the most confusion:

- **`queued` ≠ WIP-blocked.** `queued` means *capacity*-blocked: a flow would pull the card but no
  executor slot is free. A WIP-blocked card stays `:ready`. Only the scheduler sets `queued`, and
  only in stages a flow pulls from (`Relay.Runs.Policy`, ADR 0003 RLY-133 update).
- **`failed` is a real card status**, set only by `Cards.mark_failed/3` (never by a human), and it
  counts toward "needs you" even though it stamps no `blocked_since` and carries no question
  (`lib/relay/cards.ex:737`).

The authoritative per-state tables — card status, the run-status transition graph (generated from
`Relay.Runs.Transitions` by `mix relay.gen_state`), and the three park reasons — live in
[`docs/architecture/state.md`](../architecture/state.md). They are gated there and are not
restated here.

### The happy path

A card is *pulled* by the scheduler when it's `:ready`/`:queued`, agent-owned (baton ≠ human), has
no active run, and sits in an enabled flow's `pulls_from` stage with WIP room and a free isolation
slot (`fresh_eligible?`, `lib/relay/runs/scheduler.ex:152`; `Policy.pullable?/1`,
`lib/relay/runs/policy.ex:24`). A run is inserted `:running`, the card moves to the flow's
`works_in` stage and goes `:working`, and the engine walks nodes until it reaches `done` (card
lands on the flow's `lands_on` stage) or a review gate (card `:in_review`, waiting for a human).

The three flows (`lib/relay/flows/default_library.ex`), each **loaded from**
`docs/designs/flows/*.json`:

- **spec** (`shared_clean`): `Next up → brainstorm → Spec:Review`.
- **plan** (`shared_clean`): `Spec:Done → write_plan → Plan:Done`.
- **code** (`exclusive`, 18 nodes): `Plan:Done → … → Review`.

The code flow's happy path, with the `foreach` loop over the plan's tasks:

```mermaid
flowchart LR
    P([Plan:Done<br/>ready]) -->|scheduler pulls| BR[branch]
    BR --> IM[implement]
    IM --> SR[spec_review]
    SR --> QR[quality_review]
    QR -->|foreach_remaining| IM
    QR -->|foreach_exhausted| SY[sync]
    SY --> PC[precommit]
    PC --> FR[final_review]
    FR --> SM[smoke]
    SM --> AC[acceptance]
    AC --> PO[post]
    PO --> RS[resync]
    RS --> RV[reverify]
    RV --> MG[merge]
    MG --> R([Review<br/>in_review])
```

`implement → spec_review → quality_review` repeats once per plan task; `quality_review` checks off
the just-reviewed task, and the `:foreach_exhausted` guard (`remaining == 0`) advances to `sync`
(`lib/relay/runs/run_server.ex:250`, `engine.ex:177`). Tasks come from
`PlanTasks.parse/1` — `## Task N: <name>` headings, now tolerant of `:`, `—`, `–`, or `-`
separators (`lib/relay/runs/plan_tasks.ex:23`, per the fix merged this week).

### How an outcome routes — the engine decision order

Every node outcome runs through `Engine.decide/4` (`lib/relay/runs/engine.ex:72`), a pure function.
**Order matters** — the checks are a `cond`, and earlier rules win:

```mermaid
flowchart TD
    O[node reports an outcome] --> NI{"outcome is<br/>needs_input?"}
    NI -->|yes| PARK[park run :needs_input<br/>+ block card]
    NI -->|no| CB{"failed AND same<br/>failure 3 times?"}
    CB -->|yes| FAIL[fail run, mark card failed]
    CB -->|no| RB{"failed AND retry<br/>budget left?"}
    RB -->|yes| RETRY[re-enter same node]
    RB -->|no| RT[select edge for this outcome]
    RT --> HE{"matching<br/>edge?"}
    HE -->|"no, failed outcome"| FAIL
    HE -->|"no, other outcome"| DEG[degrade: follow the :failed edge]
    HE -->|yes| FO{"edge.to?"}
    DEG --> FO
    FO -->|"loop / visit budget spent"| FAIL
    FO -->|done| DONE[finish run, card lands on stage]
    FO -->|needs_input| PARK
    FO -->|a node| TRANS[transition to next node]
```

Caps and their defaults (all `+ run.retries` as a bonus — one human retry buys one extra of
*everything*, `engine.ex:15`): circuit-breaker threshold **3** (`engine.ex:28`), `max_retries`
per node (0 unless set), `max_loops` per edge (unlimited unless set), visit cap **20**
(`engine.ex:29`). The breaker's signature is a SHA-1 of the normalized failure detail
(`engine.ex:104`) and counts across the **full** history, so it catches same-error loops even when
budgets remain.

### Failure modes and how each is handled

The full grid — every known failure, grouped by the machine that detects it, with its trigger,
handling and resting state — is [`docs/architecture/failures.md`](../architecture/failures.md).
It is a current-state reference and is freshness-gated there; this ADR keeps the decision, the
happy path, the engine's decision order, and the known gaps below.

### Where the machines meet

A `needs_input` outcome moves **two** machines in one step: the run parks and the card blocks, with
self-healing reconciliation if they drift (`state.md:140`). A run reaching `failed` marks the card
`failed` via `mark_failed/3`. A retry (`revive_run`, RLY-189) revives the **same** run row
(`failed`/`parked → running`), never a new one, and raises every engine cap by one — buying exactly
one more move, not a reset (`runs.ex:1886`). `retry_run` is deliberately narrow: it accepts a clean
`:failed` run or a *died-agent* `needs_input` park (latest node outcome was `failed` — the RLY-179
"masquerade"), and **refuses** a genuine question, an `executor_gone` park, or a `:running` run
(`restartable?/1`, `runs.ex:1797`).

## Consequences

- **One map.** Reviewers can check a change against the invariants here instead of re-deriving them;
  "which of the four machines does this touch, and how does it fail?" becomes answerable.
- **It must be kept in sync.** `state.md` is already gated by `mix relay.gen_state`; this ADR is
  prose and can rot. Treat a contradiction between it and the code as a bug in whichever is wrong,
  and supersede rather than silently drift (ADR discipline).
- **The gaps below are now explicit debt**, not tribal knowledge rediscovered per incident.

## Known gaps — what we might still be missing or have wrong

These are hypotheses, ordered by how much they've already bitten us. Several are the *same* root
cause wearing different costumes: **the run lifecycle and the card's stage transitions are not
transactionally coupled.**

1. **Dispatch is non-atomic — the "active run in a `:done` stage" window. → RESOLVED (RLY-233 /
   #190 + RE239).** Dispatch is now atomic: `start_seeded_run/4` moves the card into the flow's
   work lane *then* inserts the run in one transaction, so no *committed* state ever pairs an active
   run with a card still at its (often `:done`-type) `pulls_from` stage. The residual was purely
   observational — the `Listener`'s terminal-close rule read the card stage and the active run in
   two separate queries and could straddle a concurrent `Spec:Done → Plan` dispatch, seeing the
   stale done stage beside the fresh plan run and cancelling it (the live RE239 incident: a plan run
   self-cancelled twice at that handoff). Closed by judging the leak from a single
   `run → card → stage` snapshot (`Relay.Runs.leaked?/1`) — the same predicate `close_orphaned_runs/0`
   sweeps with — instead of a card stage read apart from the run.

2. **Outcome delivery is neither durable nor idempotent.** When an agent finishes a node it POSTs
   the outcome via `bin/relay outcome`. If that report is lost — executor restarted mid-report
   (seen live: RLY-230's `smoke` passed, executor went 19→24, outcome vanished) or a network blip —
   the node execution keeps `outcome=nil` and the run stays `:running` **forever**. Nothing reclaims
   it: the reaper only acts on a *gone* executor, but here the executor is *fresh*; it's the single
   job's outcome that disappeared. Needed: (a) outcome reporting idempotent by execution id, so a
   re-report after restart is accepted; (b) a reaper for "job `claimed`, outcome overdue, executor
   fresh" that re-dispatches or parks; (c) operator tooling to re-accept a known-good outcome
   (`retry_run` refuses a `:running` run — see Gap 7).

3. **`needs_input` is overloaded across three unrelated meanings** — a genuine human question, an
   engine escalation after a node `failed` (A4), and a *system precondition failure* (empty plan B1;
   and RLY-232, where a capacity shortage bounces to `needs_input`). Retry/resume then has to *guess*
   which it is by sniffing the latest node outcome (`restartable?`, the RLY-179 masquerade), and the
   UI shows raw executor strings as "questions." Consider splitting the concept: reserve
   `needs_input` for real questions and add a distinct blocked reason for system failures, so the
   Listener, the UI, and retry stop disambiguating by heuristic. **RLY-232 is the concrete first
   instance to fix.**

4. **Server capacity accounting vs executor worktree-holding can diverge.** The scheduler debits a
   slot only for `:running` runs (`reserve_active_runs`), but the executor *retains* an exclusive
   worktree for a failed/parked exclusive run. So the server can think an exclusive slot is free
   while the executor still holds the worktree — the source of the "blackrock over-committed"
   confusion this week. Decide and document the single truth: does a parked/failed exclusive run
   reserve its slot, and make both sides agree.

5. **The circuit breaker counts environmental failures as code failures.** It trips on 3 identical
   signatures regardless of cause, so a worktree collision (E1) or a capacity refusal repeated 3×
   terminally `fail`s the run — conditions a retry-after-they-clear would fix, not code bugs. RLY-231
   died exactly this way. Consider excluding infra/precondition signatures (branch-mismatch,
   executor-unavailable, capacity) from the breaker, or giving them a park-and-wait path instead of
   counting them toward terminal failure.

6. **Runs leak past card completion.** A card reaching Done doesn't terminal-close its active run —
   we saw zombie `:running` rows on Done cards and a parked run holding an exclusive slot (RLY-157).
   RLY-233 is the fix (the `Listener`'s terminal-close rule + `close_orphaned_runs/0`, both closing a
   run whose card sits in a terminal-type stage). Its Gap 1 blocker — the dispatch/observation race —
   is now resolved (atomic dispatch + the single-snapshot `leaked?/1` leak test), so the leak-close
   paths are no longer endangered by it; what remains is keeping lands-on/Done transitions and run
   termination coupled tightly enough that no new leak reopens.

7. **Retry only works on `:failed`.** A run stranded `:running` (Gap 2), or a card a human wants to
   force-rerun, has no clean path except `cancel_run` + re-pull — which discards every node already
   passed. Consider a status-independent "resume from the last good node" operator action.

8. **Executor restart is a lossy event.** Restart revokes in-flight jobs and re-claims them; anything
   mid-report is lost (Gap 2), and re-claimed jobs can sit `claimed` without being re-run (seen live:
   RLY-230's re-claimed job never executed). A graceful drain (finish or checkpoint in-flight jobs
   before exit) plus idempotent re-report would make restarts safe — and bumping `EXECUTOR_VERSION`
   mid-flight (19→24) is precisely when this bites.

## Alternatives considered

- **Leave the vocabulary in `state.md` and skip an ADR.** Rejected: `state.md` documents *what each
  state is*, not *how failures are handled* or *where the model is wrong*. The failure map and the
  gap list have no home otherwise, and they're what reviews actually need.
- **Encode every failure mode as a formal transition table and generate it.** Attractive, and partly
  done for run status (`Transitions` → `gen_state`). But the cross-machine failures (Gaps 1, 2, 6)
  are *interactions*, not single-machine transitions — a table per machine can't express "run + card
  disagree during dispatch." Prose + the gap list is the right altitude until those are closed.
