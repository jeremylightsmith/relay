---
name: brainstorm
description: Use BEFORE any feature, component, UI, or behavior work, and before entering plan mode — for every project however small, when no approved design exists yet. Also invocable as /brainstorm.
---

# Brainstorm

Turn an idea into a fully-formed design through collaborative dialogue.

This skill takes an **optional card ref** as its first argument (`$ARGUMENTS`), e.g.
`/brainstorm RLY-42`. The **card is the home for this unit of work** — its `spec` field, read
and written with `./bin/relay`, is where the approved design lives, never a shared repo file.

<HARD-GATE>
Do NOT write code, scaffold, run a plan, or take any implementation action until a design is
presented AND the user approves it. This applies to EVERY project regardless of perceived
simplicity.
</HARD-GATE>

**"Too simple to need a design"?** No. Every project goes through this — a one-function
helper, a config tweak, a copy change. "Simple" work is exactly where unexamined assumptions
cause the most wasted effort. The design can be a few sentences, but you MUST present it and
get approval before moving on.

## Which card?
- **Ref given** (`/brainstorm RLY-42`) → read that card first (`./bin/relay card <ref>`) for
  context and brainstorm against it. If `./bin/relay card <ref>` shows a **CHANGES REQUESTED**
  block, treat resolving that feedback as this pass's primary goal. On approval, write the
  spec back to that card.
- **No ref given** → first confirm with the user that the goal is to **create a new card**. On
  confirmation, create it in **Backlog** and capture its ref:

      ./bin/relay create "<title>" --stage Backlog --json

  New cards are **intake**: they land in Backlog for a human to triage and prioritize later —
  never drop a fresh card straight into a planning column (Spec/Plan/Code). Brainstorm as
  usual, then write the approved spec to the new card and report its ref.

## Process
1. Explore current project context (files, docs, recent commits). If a card ref was given,
   read the card first (above) for context.
2. Ask clarifying questions ONE at a time (prefer multiple-choice). Understand purpose,
   constraints, success criteria. If the request is really several subsystems, decompose
   first and brainstorm the first piece.
   - **Re-interview when the request contradicts a shipped decision.** If it conflicts with
     how an already-merged feature works, stop and interview the user about the intended
     behavior — don't silently re-litigate a shipped decision from a one-line request (this
     caught the workspace-cascade direction).
   - **Group MMFs that touch the same files onto one branch / one plan.** When two roadmap
     MMFs edit the same modules (e.g. M06 + M07 both touched `profile.ex`, `index.ex`, and the
     client card), brainstorm and plan them together to avoid merge conflicts and contradictory
     edits, and note the shared files in the spec header.
3. Propose 2–3 approaches with trade-offs and a recommendation.
4. Present the design in sections scaled to complexity (architecture, components, data
   flow, error handling, testing); get approval section by section. YAGNI ruthlessly.

## Design principles
- **Design for isolation.** Break the system into units that each have one clear purpose,
  communicate through well-defined interfaces, and can be understood and tested
  independently. For each unit you should be able to say what it does, how it's used, and
  what it depends on. If you can't understand a unit without reading its internals, or can't
  change its internals without breaking consumers, the boundaries need work. (A file growing
  large is usually a signal it does too much — and focused units are easier to implement and
  review, which your per-task gates reward.)
- **Work with the existing codebase.** Explore the current structure first and follow
  established patterns (Phoenix/LiveView/Ecto idioms per `AGENTS.md`). Where existing code
  genuinely blocks the work — a tangled module, unclear boundaries — fold a *targeted*
  improvement into the design, the way a good developer improves code they're touching. Do
  NOT propose unrelated refactoring; stay focused on the current goal.

## After approval
- Write the approved spec to the **card**, not a shared repo file. Save it to a temp file and:

      ./bin/relay spec <ref> @<tmpfile>

  Do **NOT** write or commit a spec file under a shared `docs/…` specs directory — that home is
  retired; work travels with the card.
- Self-review: placeholder scan, internal consistency, scope, ambiguity — fix inline.
- Point the user to `/write-plan <ref>`. Do NOT start implementation or launch execution.

## Headless / runner use (no human to dialogue with)
When the board runner invokes this skill there is no human to dialogue with in real time, but
that does **not** mean skip the questions. Do the **same** clarifying-question discovery you'd
do interactively (Process step 2) — surface every question you'd ask a human. Headless mode
changes only *how* you deliver them, not *whether* you ask.

- **If you have questions, ask them.** Collect *all* of them and send a **single**
  `needs-input` call formatted as a numbered list, then STOP. Do not guess-and-write a spec
  when real questions remain. Tell the human the reply shape:

      ./bin/relay needs-input <ref> "Before I spec this I need a few decisions — reply like 1. … 2. … :
      1. <question one>
      2. <question two>
      3. <question three>"

  Calling `needs-input` blocks the card on a human and posts your questions to its timeline;
  the runner stops working it until the human answers.

- **On re-entry** (the card comes back after the human answers): the answers are in the card
  timeline — `./bin/relay card <ref>` shows your question comment and the human's answer
  comment (also honor any CHANGES REQUESTED block). Read them, incorporate, then write the
  spec to the card (`./bin/relay spec <ref> @<tmpfile>`) and stop — or send one more batched
  `needs-input` only if something is genuinely still ambiguous.

- **Only write the spec directly, without asking, when there are genuinely no meaningful
  questions.** The board's `Spec:Review` lane is the approval gate for the spec itself.
