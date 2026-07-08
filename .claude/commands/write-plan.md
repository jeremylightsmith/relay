---
description: Turn an approved spec into the repo-root plan.md that /exec-plan runs.
---

You author the plan **yourself, in the main conversation context** with the regular model —
do NOT delegate to a subagent. The plan's quality depends on the decisions reached in this
conversation (the spec is only a compression of them); a fresh planning subagent lacks that
context, so authoring in-context is how those decisions reach the plan.

## Steps
1. **Resolve the spec.** Take the spec path from `$ARGUMENTS`; if absent, ask the user which
   spec under `docs/superpowers/specs/` to use. Read it fully.
2. **Write `plan.md`** at the repo root, following the guidance below.
3. **Self-review** (checklist at the end), fixing inline.
4. **Hand back to the human.** Summarize the task breakdown, tell the user the `plan.md`
   path, and ask them to review and approve. Do NOT launch `/exec-plan` — approval is a
   separate, human-gated step.

---

## Plan authoring guidance

You are writing an implementation plan to be executed autonomously by `/exec-plan` (the
Claude Workflow engine). Assume the executing engineer has zero repo context and needs
every detail.

### Input
The approved spec, at the path provided to you. Read it fully.

### Task right-sizing
Prefer **~3 coarse, vertical-slice tasks** for a typical MMF (measured cheaper: fewer tasks =
fewer per-task review passes, no retry spike). A task is a coherent slice that ends in an
independently testable deliverable and is worth a fresh reviewer's gate — `/exec-plan` spec-
and quality-reviews each task independently. **Merge** tightly-coupled steps: schema +
migration + context + factory for one area belong in ONE task, not split; fold
setup/config/scaffolding/docs into the task whose deliverable needs them. **Split** only when
a task crosses an independent module boundary, would be a very large diff, or is a risky
refactor that benefits from isolation (e.g. keep a pure schema migration its own task).

### Output: `plan.md` at the REPO ROOT (this is the executor's contract)
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
After writing `plan.md`, re-read it for: placeholder scan; internal consistency; scope
(single coherent unit of work); ambiguity; **spec coverage** (point each spec
requirement to a task — add a task for any gap); and **type/signature consistency** across
tasks (a function defined as `clear_layers/1` in Task 3 but called as `clear_full_layers/1`
in Task 7 is a bug — the Consumes/Produces names must match exactly). Fix inline. Then tell
the user the `plan.md` path with a one-paragraph summary of the task breakdown, and ask them
to review. Do NOT launch `/exec-plan` yourself — that's a separate, human-gated step.
