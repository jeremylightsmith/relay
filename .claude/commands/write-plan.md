---
description: Turn a card's approved spec into the plan header and tasks stored on that card for the Code flow to run.
---

Run `/write-plan <ref>`. The card ref comes from `$ARGUMENTS`; the **card is the source of
truth** — read the approved spec from its `spec` field and write the plan back to the card:
its **header** to the `plan` field and its **tasks**, each with a full body, as the card's tasks.
Never a shared repo file.

You author the plan **yourself, in the main conversation context** with the regular model —
do NOT delegate to a subagent. The plan's quality depends on the decisions reached in this
conversation (the spec is only a compression of them); a fresh planning subagent lacks that
context, so authoring in-context is how those decisions reach the plan.

## Steps
1. **Resolve the card and spec.** Take the card ref from `$ARGUMENTS`; if absent, ask the user
   which card to plan. Read the approved spec from the card's `spec` field:

       ./relay card <ref> --json

   If the `spec` field is empty or missing, stop — there's no approved spec to plan from. Tell
   the user to produce one first with `/brainstorm <ref>`, then come back to `/write-plan <ref>`.
   Do NOT invent a spec. Otherwise, read it fully. If `./relay card <ref>` shows a
   **CHANGES REQUESTED** block, treat resolving that feedback as this pass's primary goal.

   **Delta re-plan (rejected card):** if the card already has a **non-empty `plan`** AND an open
   `rejection` (the `rejection` field is non-null, i.e. a `CHANGES REQUESTED` block is shown),
   do NOT re-plan greenfield. The card has shipped work that a reviewer sent back. Instead:
   (a) read the rejection `note` — it is usually "X is wrong," meaning X already exists but is
   broken or half-built; (b) **check what is actually implemented against the code** (read the
   repo / `git log` / `git diff main...` for this card's branch) to see what shipped; (c) plan
   **only the delta** — the fix the note asks for plus any genuine gaps — never re-planning or
   rebuilding work that already shipped and passed. Because the new tasks then contain only the
   new work, the branch diff matches the plan and the Code flow's `final_review` node needs no
   special-casing.
2. **Author the plan** in-context, following the guidance below: one header file and one body
   file per task, in your scratch directory (see "Writing it to the card").
3. **Self-review** (checklist at the end), fixing inline.
4. **Write the plan to the card** — clear stale tasks, write the header, add the tasks in ONE
   call, then check the result (see "Writing it to the card"). Do NOT leave a durable repo-root
   `plan.md` (the Code flow materializes the header per-run at `$RELAY_PLAN`).

   Then summarize the task breakdown to the user. There is no runner command to launch by hand
   anymore (RLY-139): once the card is approved into `Plan:Done`, the Code flow
   (`docs/designs/flows/code.json`, if enabled for this board in Settings › Flows) picks it up
   automatically — dispatch is server-side. Do NOT move or approve the card yourself — that's a
   separate, human-gated step.

---

## Plan authoring guidance

You are writing an implementation plan to be executed autonomously by the Code flow (the
server-side flow engine, ADR 0006 — `docs/designs/flows/code.json`). Assume the executing
engineer has zero repo context and needs every detail.

### Input
The approved spec, read from the card's `spec` field (`./relay card <ref> --json`). Read
it fully. **Design fidelity is the spec's call, not yours** — artboards drift from the shipped
app, so match a mockup only where the spec **explicitly** says a UI should match a named
`docs/designs/*.dc.html` artboard (`/brainstorm` settles this with the human and records the
decision in the spec). When the spec does name one, open that artboard and read the relevant
section so its concrete values (classes, tokens, measurements, states) reach the plan. A spec
can instead name a **card mockup** — `Match card mockup "<caption>"`, one of the HTML mockups
the Design stage uploaded to the card. Pull them outside the repo (`./relay mockups <ref>
--pull "$(dirname "$RELAY_NODE_SCRATCH")/mockups" --json` maps each caption to its file —
interactively, with no `$RELAY_NODE_SCRATCH`, omit the DIR to get the gitignored
`tmp/<ref>/mockups/`; skip the inlined `<style>` block when reading) and read the named one the same way. Where the spec
does not tie a UI to an artboard or card mockup, do **not** go hunting one — even if the card
carries mockups — plan to the spec and the existing design system.

### Task right-sizing
Prefer **~3 coarse, vertical-slice tasks** for a typical MMF (measured cheaper: fewer tasks =
fewer per-task review passes, no retry spike). A task is a coherent slice that ends in an
independently testable deliverable and is worth a fresh reviewer's gate — the Code flow's
`spec_review` and `quality_review` nodes review each task independently. **Merge** tightly-coupled steps: schema +
migration + context + factory for one area belong in ONE task, not split; fold
setup/config/scaffolding/docs into the task whose deliverable needs them. **Split** only when
a task crosses an independent module boundary, would be a very large diff, or is a risky
refactor that benefits from isolation (e.g. keep a pure schema migration its own task).

### Output part 1: the header — written to the card's `plan` field
The header holds only what EVERY task needs; nothing per-task goes in it.
- **Goal**, **Architecture**, **Tech**, and a **Global Constraints** section (project-wide
  rules copied verbatim from the spec).
- **`## Verification`** — declares the gate the runner runs, because not every card is a
  Phoenix card. Two lines:
  - **`Gate:`** the command(s) that must pass. **Default `mix precommit`** (the Elixir/LiveView
    app). A card that only touches **`flutter/`** declares `dart format --set-exit-if-changed .`
    + `flutter analyze` + `flutter test` (run in `flutter/`) instead — matching CI's Flutter Deploy
    `validate` job; `mix precommit` does not exercise Dart. A card touching both declares both.
    (A committed `.githooks/pre-commit` auto-formats staged Dart, so `dart format` is a belt-and-
    suspenders check, not a formatting step.)
  - **`Smoke:`** how the acceptance smoke drives it. Default: the running web app on
    `:4003` via Playwright. A **Flutter** card declares the iOS-simulator smoke (boot the app,
    screenshot each state, compare to `docs/designs/Relay Mobile.dc.html`). Say "none" only for
    a card with no runtime surface.
  The `plan-implementer`, the whole-suite gate, the `smoke-tester`, and the `acceptance-tester`
  all read these lines, so they must be exact.
- **Cover the card's acceptance criteria.** Read the card's `acceptance_criteria` field
  (`./relay card <ref> --json`) and make sure the tasks actually deliver every criterion — a
  criterion no task covers is a gap: add a task for it. Do **NOT** copy the criteria into the
  header or a task: the `acceptance-tester` reads them off the card at the Code stage, so a copy
  would only drift.

### Output part 2: the tasks — one title and one body each
Each task is a card task with a short **title** (what a human scans on the card and in the run
log) and a **body** (the task's whole spec). The Code flow's `implement`, `spec_review`,
`quality_review` and `fix_findings` nodes each fetch ONE task's body by id
(`./relay task show <ref> <id>`) and see no other task's body, so a body must stand alone.
Each body carries:
- **Files** (exact create/modify/test paths) and **Interfaces** — split as **Consumes** (exact
  signatures this task uses from earlier tasks) and **Produces** (exact function names, params,
  and return types later tasks rely on). This block is how an implementer who sees only its own
  task learns the names and types its neighbors use.
- **Steps** as `- [ ]` checkboxes, each ONE action: write failing test → run it (expect fail) →
  minimal implementation → run it (expect pass) → commit. Include the ACTUAL test code and
  implementation code in fenced blocks — no placeholders, no "similar to". The body is the
  implementer's source of truth and the reviewer's diff target; write it in full.
- **Design fidelity (only where the spec calls for it):** if the spec says this task's UI
  must match a `docs/designs/*.dc.html` artboard or a card mockup, name it in the body — the
  artboard file, or `card mockup "<caption>"` with the caption exactly as the card lists it —
  and list the **specific elements/states that must match it**, each with the mockup's concrete value
  (exact daisyUI classes, design tokens, px measurements, and the states the mockup shows).
  Fold those into the task's **test code as concrete assertions** (assert the exact class /
  token / px the mockup uses — see `core_components_test.exs`, which pins "44px dashed strip …
  Relay Board.dc.html lines ~75–81"), so "matches the mockup" is a checked deliverable, not a
  hope. The implementer and reviewers act only on what you name here — anything you leave out,
  they won't match. Non-visual tasks, and UI with no governing artboard or card mockup, skip
  this.
- The independently testable **deliverable** and the **commit message** to use.

The order you pass the tasks in is the order the Code flow works them.

### No placeholders
No "TBD", no "add error handling", no "write tests for the above" without the code. Every
step an engineer needs is in the header or the task's body.

### Self-review
After writing the files, re-read them for: placeholder scan; internal consistency; scope
(single coherent unit of work); ambiguity; **spec coverage** (point each spec requirement to
a task — add a task for any gap); **design coverage** (every UI the spec ties to a
`docs/designs/*.dc.html` artboard or a card mockup names it and carries the mockup's concrete values
in the task body and its tests); **type/signature consistency** across tasks (a function
defined as `clear_layers/1` in one task but called as `clear_full_layers/1` in another is a
bug — the Consumes/Produces names must match exactly); and **no per-task content in the
header** (Files, steps, code and commit messages belong in bodies). Fix inline.

## Writing it to the card

Write the files under your scratch directory — `$(dirname "$RELAY_NODE_SCRATCH")` when the flow
runs you, a temp directory otherwise — never an invented `/tmp` path and never the repo root.
Then, in this order:

1. **Clear stale tasks first.** `./relay tasks add` **appends** after the card's last task — it
   never replaces — so a re-plan that skips this step leaves duplicates for the Code flow to
   build twice. List what is there:

       ./relay tasks list <ref> --json

   - **Greenfield plan or re-plan** (no open rejection): remove every existing task.
   - **Delta re-plan** (open rejection): keep the tasks that are already done (`"done": true` —
     the record of shipped work, which the Code flow skips) and remove every task that is not.

   Remove each one with:

       ./relay task rm <ref> <id>

2. **Write the header:**

       ./relay plan <ref> @<dir>/header.md

3. **Add every task in ONE call**, in execution order — one `--task` per task, its title then
   its body file:

       ./relay tasks add <ref> --task "<title>" @<dir>/task1.md --task "<title>" @<dir>/task2.md --task "<title>" @<dir>/task3.md

   The batch is all-or-nothing: if it is refused (e.g. a blank title), nothing was added — fix
   it and re-run the same single call.

4. **Check the result.** `./relay tasks list <ref>` must show exactly the titles you intended,
   in order, with no leftovers; spot-check one body with `./relay task show <ref> <id>`, and
   `./relay card <ref> --json` must show a `plan` that is the header alone.

The Plan flow's `write_plan` node declares that it writes both `plan` and `tasks`: a run
that reports success with either still empty is failed by the engine at the Plan stage.

## Headless / runner use (no human to dialogue with)

When the board's flow engine runs this command as the `write_plan` node there is no human in
the loop. The node's `run` is a bare `/write-plan {ref}`, so every operational rule lives here.

- **The work is pre-authorized.** Proceed without asking for confirmation. Read the card, write
  the header and the tasks, stop.
- **Blast radius: do not touch git, do not touch other cards.** No branches, no commits, no
  pushes, no stage moves. The only writes you make are to the card you were given: its tasks
  (`./relay task rm`, `./relay tasks add`) and its header (`./relay plan <ref> @<file>`).
- **Terminal STOP.** When the header and tasks are on the card, you are done — stop. Explicitly
  do **NOT** start implementing, and do not move or approve the card into `Plan:Done` yourself —
  the Code flow's dispatch is automatic and server-side (RLY-139) once a human does that. The
  interactive steps above say approval is "a separate, human-gated step"; headless this is a
  hard stop, because there is no human standing at that gate to be asked.
- **No approved spec → raise `needs-input`, never a silent stop.** Step 1 tells the interactive
  path to stop and tell the user. Headless there is no user to tell, and a silent stop reads to
  the engine as `succeeded` — which the writes guard would then fail with a confusing "plan is
  still empty". So if the card's `spec` field is empty or missing, park the card where the
  problem actually is, writing the questions to a scratch file under `$RELAY_NODE_SCRATCH`'s
  directory (never an invented `/tmp` path — see
  [`relay.md`](../../relay.md#the-relay_node_scratch-contract)):

      questions_file="$(dirname "$RELAY_NODE_SCRATCH")/questions.json"
      cat > "$questions_file" <<'JSON'
      [
        {
          "prompt": "**No approved spec.** This card has no `spec`, so there is nothing to plan from. How should I proceed?",
          "options": [
            "Run `/brainstorm <ref>` to produce a spec first, then re-run `/write-plan <ref>`. — RECOMMENDED",
            "Paste the spec here and I'll plan directly from it."
          ],
          "allow_text": true
        }
      ]
      JSON
      ./relay needs-input <ref> --questions @"$questions_file"

  Then stop. **Always the structured `--questions @<tmpfile>` JSON-array form** of
  `{prompt, options, allow_text}` objects — never a hand-numbered prose string. The drawer
  renders its one-question-at-a-time stepper only for the structured form; a string degrades to
  a wall of text (RLY-109).

  The engine **parks** a run on the `needs_input` outcome without needing an edge for it, so the
  `plan` flow's single `write_plan → done on: :succeeded` edge is correct as-is and needs no
  change.
- **CHANGES REQUESTED / delta re-plan is already headless-safe** — it reads the rejection off
  the card, not from a human. Follow it exactly as written above: plan **only the delta**, and
  keep the done tasks when clearing stale ones. Do not re-plan greenfield just because no human
  is present to confirm.
- **Do not raise `needs-input` for anything else.** Unlike `/brainstorm`, planning is not a
  dialogue: the spec is the approved input and the plan is a mechanical elaboration of it. An
  empty spec is the one genuine blocker.
