---
description: Autonomously execute a card's plan via the Claude Workflow engine.
---

Run `/exec-plan <ref>` to completion using the Claude Workflow engine. The card ref comes from
`$ARGUMENTS`; the plan is read **from the card**, not a durable shared file. Each task is
TDD-implemented, passed through sequential spec-compliance then code-quality review, and
committed; then `mix precommit` runs, then a whole-branch review with a bounded fix loop,
then an **acceptance smoke** that drives the feature end-to-end through the running app
(screenshots + design-artboard comparison for UI), and finally an **acceptance check** that runs
the card's own human-authored `acceptance_criteria` — the last two also with bounded fix loops.
The orchestration lives in `.claude/workflows/execute-plan.js`.

## Preflight — verify BEFORE launching (stop and report if any fails)
1. **The card has a non-empty `plan`.** Read it: `./bin/relay card <ref> --json` (field
   `plan`). If it is empty, stop and tell the user to produce it with `/brainstorm <ref>` →
   `/write-plan <ref>`. Do NOT invent a plan.
2. **Clean-ish working tree on a feature branch** (not `main`). Run `git status` and
   `git branch --show-current`. If on `main`, stop and tell the user to branch first.
   If there are unrelated uncommitted changes, surface them and ask before proceeding.
3. **Confirm scope with the user.** This makes **real, autonomous commits** on the
   current branch. Summarize: how many unchecked tasks remain and the branch name, then
   get an explicit go-ahead. ($ARGUMENTS may say "yes"/"go" to skip this confirmation.)

## Launch
`execute-plan.js` reads a repo-root `plan.md` (it is unchanged). Materialize the card's plan
into that **transient** file just before launching:

    ./bin/relay card <ref> --json | jq -r '.plan // ""' > plan.md

Then invoke the Workflow tool with the committed script, passing the card ref through `args` so
the workflow can read the card's acceptance criteria, attach the smoke screenshots, and post the
results comment on this card:

    Workflow({ scriptPath: ".claude/workflows/execute-plan.js", args: { ref: "<ref>" } })

(Replace `<ref>` with the actual card ref from `$ARGUMENTS`.)

The workflow runs in the background; a task-notification arrives when it completes.
While it runs, the user can watch live progress with `/workflows`.

`plan.md` is also the **only** record of per-task progress (`execute-plan.js` flips each
task's `- [ ]` to `- [x]` as it completes, and re-reads the file each cycle to pick the next
unchecked task) — nothing writes progress back to the card. So do NOT delete it unconditionally
here; whether it survives the run depends on how the run ends (see On completion below).

## On completion
**First, record the outcome so an autonomous runner can gate on it** — write the workflow's
`status` verbatim to a sentinel file:

    mkdir -p tmp && printf '%s' '<status>' > tmp/exec-plan-status

Do this for **every** status below (`ready` and every failure alike). The Code-stage runner
refuses to push the branch, open the PR, or merge unless this file reads exactly `ready`, so a
`broken`/`blocked`/`stalled`/`smoke-failed`/`acceptance-failed` run stops at the branch instead
of shipping.

Then read the workflow's returned object and report faithfully:
- `status: "ready"` — all tasks done, precommit passed, whole-branch review approved, the
  acceptance smoke drove the feature successfully, AND every one of the card's acceptance
  criteria came back `pass` or `human-verify`. Surface `smoke.summary`, the `smoke.screenshots`
  paths, and any 👤 `human-verify` criteria the human still needs to eyeball, then suggest
  `/finish` to merge / open the PR (the human-gated step). The run is fully done, so now delete
  the transient plan so it never becomes a shared file another card clobbers:

      rm -f plan.md

- `status: "blocked"` — the implementer escalated `BLOCKED`/`NEEDS_CONTEXT` on a task
  (`blockedTask`, `implementerStatus`, `detail`) and the run halted before reviewing it.
  Relay the `detail` verbatim — it says what's stuck and what would unblock — and help the
  user resolve it (provide context, fix the plan, or split the task) before re-launching.
- `status: "rebase-conflict"` — before starting a task, the branch could not be cleanly
  rebased onto `origin/main`: the cheap `sync` step found a conflict and the `rebaser` agent
  could not safely resolve it, so the run halted with the branch left un-mangled (rebase
  aborted). `conflictTask` names the task it halted before; relay `detail` verbatim, help the
  human resolve the conflict on the branch (rebase it onto `origin/main` by hand), then
  relaunch with `resumeFromRunId` to continue.
- `status: "stalled"` — a task failed review 6 times (`stalledTask`). Report it; do not
  paper over it. Offer `/workflows` logs and the `systematic-debugging` skill.
- `status: "review-loop-exhausted"` — final review still had blocking findings after 3
  passes. Report the outstanding findings and stop.
- `status: "smoke-failed"` — the feature was built and reviewed clean, but the acceptance
  smoke found it broken end-to-end after 3 fix passes (`smoke.findings`, `smoke.screenshots`).
  Relay the findings + screenshots and stop; do not suggest merging.
- `status: "smoke-blocked"` — the smoke could not run for an environment/setup reason
  (`smoke.findings`), not a code defect. The branch may still be fine; report what blocked the
  smoke and what would unblock it (e.g. start the dev server, install the browser), and offer
  to re-run once resolved.
- `status: "acceptance-failed"` — the branch built, reviewed, and smoked clean, but at least one
  of the card's acceptance criteria FAILED after up to 3 fix passes. Read `acceptance.criteria`
  and relay every failing criterion with its evidence (what was expected, what happened
  instead), plus `acceptance.findings`. Stop; do not suggest merging. The per-criterion
  checklist was also posted to the card as a comment.
- `status: "acceptance-blocked"` — the acceptance criteria could not be fetched or run for an
  environment/setup reason (`acceptance.findings`), not a code defect. The branch may still be
  fine; report what blocked the run and what would unblock it, and offer to re-run once
  resolved.

Note: `human-verify` criteria do **not** block — a run whose criteria are all `pass` /
`human-verify` returns `ready`, and the 👤 lines appear in the card comment for the human to
check at the gate.

For every status above other than `ready`, **leave `plan.md` in place** — do NOT `rm -f` it.
It holds the `- [x]` progress `execute-plan.js` tracks, and deleting it would lose every
completed task's state before the human has a chance to resume.

## Notes
- The plan lives on the card; `plan.md` is only a transient materialization exec-plan creates.
  It is deleted only on a successful `ready` completion (see On completion above); every other
  status leaves it in place. Never commit `plan.md`.
- To resume after an interruption or a script edit: progress is tracked ONLY as `- [x]` boxes
  in the on-disk `plan.md`, never on the card — `execute-plan.js` re-reads `plan.md` each cycle
  and nothing writes progress back to the card. So if `plan.md` still exists in the
  working tree, leave it as-is; only re-materialize it from the card (the `Launch` step above)
  if it is missing. Re-materializing while it still exists would reset every box to `- [ ]` and
  re-run already-completed tasks. Then relaunch with
  `Workflow({ scriptPath: ".claude/workflows/execute-plan.js", resumeFromRunId: "<id>" })`.
- The script does NOT open a PR — that is intentionally the human-gated `/finish` step.
- Edit `.claude/workflows/execute-plan.js` to change models, review depth, or the loop.
