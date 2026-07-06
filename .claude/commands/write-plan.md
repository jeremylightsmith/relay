---
description: Turn an approved spec into the repo-root plan.md that /exec-plan runs.
---

You **orchestrate** plan authoring — you do NOT write the plan yourself. Delegate the
authoring to a **Fable subagent**: Fable 5 is the strongest model for one-shot
decomposition of a well-specified spec, and delegating keeps its long authoring turn out of
your context.

## Orchestrate
1. **Resolve the spec.** Take the spec path from `$ARGUMENTS`; if absent, ask the user which
   spec under `docs/superpowers/specs/` to use. Do this yourself, before delegating.
2. **Delegate authoring.** Launch ONE `Agent` — `subagent_type: general-purpose`,
   `model: fable` — passing it the **Author's brief** below plus the resolved spec path as
   its prompt. It reads the spec, writes `plan.md` at the repo root, runs the self-review,
   and returns the `plan.md` path + a one-paragraph summary of the task breakdown. Wait for
   it to finish.
3. **Hand back to the human.** Relay the subagent's summary, tell the user the `plan.md`
   path, and ask them to review and approve. Do NOT launch `/exec-plan` — approval is a
   separate, human-gated step.

---

## Author's brief (the delegated Fable subagent runs everything below)

You are writing an implementation plan to be executed autonomously by `/exec-plan` (the
Claude Workflow engine). Assume the executing engineer has zero repo context and needs
every detail.

### Input
The approved spec, at the path provided to you. Read it fully.

### Task right-sizing
A task is the **smallest unit that carries its own test cycle and is worth a fresh
reviewer's gate** — `/exec-plan` spec- and quality-reviews each task independently, so draw
boundaries where a reviewer could meaningfully reject one task while approving its neighbor.
Fold setup, config, scaffolding, and docs steps into the task whose deliverable needs them;
don't make them standalone tasks. Each task ends with an independently testable deliverable.

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
in Task 7 is a bug — the Consumes/Produces names must match exactly). Fix inline. Then
return the `plan.md` path and a one-paragraph summary of the task breakdown to your caller.
Do NOT show anything to the user or launch `/exec-plan` yourself — your caller handles the
human-gated review.
