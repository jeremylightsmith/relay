---
description: Turn a card's approved spec into the plan stored on that card for /exec-plan to run.
---

Run `/write-plan <ref>`. The card ref comes from `$ARGUMENTS`; the **card is the source of
truth** — read the approved spec from its `spec` field and write the plan back to its `plan`
field, never a shared repo file.

You author the plan **yourself, in the main conversation context** with the regular model —
do NOT delegate to a subagent. The plan's quality depends on the decisions reached in this
conversation (the spec is only a compression of them); a fresh planning subagent lacks that
context, so authoring in-context is how those decisions reach the plan.

## Steps
1. **Resolve the card and spec.** Take the card ref from `$ARGUMENTS`; if absent, ask the user
   which card to plan. Read the approved spec from the card's `spec` field:

       ./bin/relay card <ref> --json

   Read it fully. If `./bin/relay card <ref>` shows a **CHANGES REQUESTED** block, treat
   resolving that feedback as this pass's primary goal.
2. **Author the plan** in-context, following the guidance below.
3. **Self-review** (checklist at the end), fixing inline.
4. **Write the plan to the card.** Save it to a temp file and attach it so it travels with the
   card — do NOT leave a durable repo-root `plan.md`:

       ./bin/relay plan <ref> @<tmpfile>

   Then summarize the task breakdown to the user and point them to `/exec-plan <ref>`. Do NOT
   launch `/exec-plan` — approval is a separate, human-gated step.

---

## Plan authoring guidance

You are writing an implementation plan to be executed autonomously by `/exec-plan` (the
Claude Workflow engine). Assume the executing engineer has zero repo context and needs
every detail.

### Input
The approved spec, read from the card's `spec` field (`./bin/relay card <ref> --json`). Read
it fully.

### Task right-sizing
Prefer **~3 coarse, vertical-slice tasks** for a typical MMF (measured cheaper: fewer tasks =
fewer per-task review passes, no retry spike). A task is a coherent slice that ends in an
independently testable deliverable and is worth a fresh reviewer's gate — `/exec-plan` spec-
and quality-reviews each task independently. **Merge** tightly-coupled steps: schema +
migration + context + factory for one area belong in ONE task, not split; fold
setup/config/scaffolding/docs into the task whose deliverable needs them. **Split** only when
a task crosses an independent module boundary, would be a very large diff, or is a risky
refactor that benefits from isolation (e.g. keep a pure schema migration its own task).

### Output: the plan you author (this is the executor's contract) — written to the card's `plan` field
- A short header: **Goal**, **Architecture**, **Tech**, and a **Global Constraints**
  section (project-wide rules copied verbatim from the spec).
- Then a series of **bite-sized tasks**. Each task:
  - `### Task N: <name>` with **Files** (exact create/modify/test paths) and
    **Interfaces** — split as **Consumes** (exact signatures this task uses from earlier
    tasks) and **Produces** (exact function names, params, and return types later tasks rely
    on). Each task's implementer sees only its own task, so this block is how it learns the
    names and types its neighbors use.
  - Steps as checkboxes `- [ ]`, each ONE action: write failing test → run it (expect
    fail) → minimal implementation → run it (expect pass) → commit. Include the ACTUAL
    test code and implementation code in fenced blocks — no placeholders, no "similar to".
    The executor sees only this plan, so the code in it is the executor's source of truth
    and the reviewer's diff target; write it in full.
  - End each task with an independently testable deliverable + the commit message to use.
- **Task checkbox convention:** every task's steps use `- [ ]`. The executor flips them to
  `- [x]` as it completes each task, so keep them clean GitHub task-list checkboxes.

### No placeholders
No "TBD", no "add error handling", no "write tests for the above" without the code. Every
step an engineer needs is on the page.

### Self-review then return
After writing the plan, re-read it for: placeholder scan; internal consistency; scope
(single coherent unit of work); ambiguity; **spec coverage** (point each spec
requirement to a task — add a task for any gap); and **type/signature consistency** across
tasks (a function defined as `clear_layers/1` in Task 3 but called as `clear_full_layers/1`
in Task 7 is a bug — the Consumes/Produces names must match exactly). Fix inline. Then write
the plan to the card (`./bin/relay plan <ref> @<tmpfile>`), summarize the task breakdown, and
point the user to `/exec-plan <ref>`. Do NOT launch `/exec-plan` yourself — that's a separate,
human-gated step.
