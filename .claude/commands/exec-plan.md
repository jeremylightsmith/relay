---
description: Autonomously execute the approved repo-root plan.md via the Claude Workflow engine.
---

Run the approved `plan.md` to completion using the Claude Workflow engine. Each task is
TDD-implemented, passed through sequential spec-compliance then code-quality review, and
committed; then `mix precommit` runs, then a whole-branch review with a bounded fix loop,
then an **acceptance smoke** that drives the feature end-to-end through the running app
(screenshots + design-artboard comparison for UI), also with a bounded fix loop.
The orchestration lives in `.claude/workflows/execute-plan.js`.

## Preflight — verify BEFORE launching (stop and report if any fails)
1. **`plan.md` exists at the repo root** with at least one unchecked `- [ ]` task.
   If missing, stop and tell the user to produce it with `/brainstorm` → `/write-plan`.
   Do NOT invent a plan.
2. **Clean-ish working tree on a feature branch** (not `main`). Run `git status` and
   `git branch --show-current`. If on `main`, stop and tell the user to branch first.
   If there are unrelated uncommitted changes, surface them and ask before proceeding.
3. **Confirm scope with the user.** This makes **real, autonomous commits** on the
   current branch. Summarize: how many unchecked tasks remain and the branch name, then
   get an explicit go-ahead. ($ARGUMENTS may say "yes"/"go" to skip this confirmation.)

## Launch
Invoke the Workflow tool with the committed script:

    Workflow({ scriptPath: ".claude/workflows/execute-plan.js" })

The workflow runs in the background; a task-notification arrives when it completes.
While it runs, the user can watch live progress with `/workflows`.

## On completion
Read the workflow's returned object and report faithfully:
- `status: "ready"` — all tasks done, precommit passed, whole-branch review approved, AND the
  acceptance smoke drove the feature successfully. Surface `smoke.summary` and the
  `smoke.screenshots` paths so the user can eyeball them, then suggest `/finish` to merge /
  open the PR (the human-gated step).
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

## Notes
- To resume after an interruption or a script edit, relaunch with
  `Workflow({ scriptPath: ".claude/workflows/execute-plan.js", resumeFromRunId: "<id>" })`.
- The script does NOT open a PR — that is intentionally the human-gated `/finish` step.
- Edit `.claude/workflows/execute-plan.js` to change models, review depth, or the loop.
