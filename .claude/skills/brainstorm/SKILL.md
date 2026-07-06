---
name: brainstorm
description: Use BEFORE any feature, component, UI, or behavior work, and before entering plan mode — for every project however small, when no approved design exists yet. Also invocable as /brainstorm.
---

# Brainstorm

Turn an idea into a fully-formed design through collaborative dialogue.

<HARD-GATE>
Do NOT write code, scaffold, run a plan, or take any implementation action until a design is
presented AND the user approves it. This applies to EVERY project regardless of perceived
simplicity.
</HARD-GATE>

**"Too simple to need a design"?** No. Every project goes through this — a one-function
helper, a config tweak, a copy change. "Simple" work is exactly where unexamined assumptions
cause the most wasted effort. The design can be a few sentences, but you MUST present it and
get approval before moving on.

## Process
1. Explore current project context (files, docs, recent commits).
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
- Write the spec to `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` and commit it.
- Self-review: placeholder scan, internal consistency, scope, ambiguity — fix inline.
- Tell the user the path and ask them to review. Then point them to `/write-plan <spec>`.
  Do NOT start implementation or launch execution.
