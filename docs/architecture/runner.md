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
- **Heartbeat**: a background thread posts the in-flight refs to
  `POST /api/board/heartbeat` every 30s so the board knows what's actively being worked.
- **Run ids**: each `work()` gets a UUID attached to its log lines (RLY-112) so a card's
  timeline can group lines by run.

Known sharp edges this design accepts (and ADR 0006 removes): stage-level granularity
only, the `tmp/exec-plan-status` scratch-file merge gate, and prompt-enforced rules.

---
*Sources of truth: `bin/relay`, `relay_config.json`, `bin/test_relay.py`.*
