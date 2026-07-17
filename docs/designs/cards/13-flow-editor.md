# 13 — Flow editor: edit flows on the board

**Why.** Decided 2026-07-16: flows are not read-only — the board is the editing surface.
This is the biggest new UI in the initiative; it's also where flow *versioning* becomes
visible (runs snapshot the version they started on).

**Scope.**

- Full-page editor from a Flows-tab row, matching `docs/designs/Relay Flow Editor.dc.html`
  (drawn against the real Code flow: 14 nodes · 20 edges · 7 loops, serpentine layout,
  Editing/Unsaved/Save states, delete guard "Referenced by N edges"). One vocabulary
  decision vs the artboard: its edge labels read `ok/passed/fixed` — treat those as
  optional *display labels*; the data and the inspector always carry the canonical
  outcome (`succeeded/failed/…`), never two vocabularies in the schema. Still to design
  or settle in-build (asked for, not drawn): the inline validation-error state, the
  save-confirm with the mid-run version note, and the diff-vs-default affordance:
  - the flow rendered as a graph — node shapes/colors by type, edges labeled with
    outcomes, failed-edges dashed, `max_loops` badges;
  - node inspector as an edit form: `run` prompt (monospace), model chips
    (inherit/haiku/sonnet/opus), effort, `max_retries`, timeout;
  - toolbar: add node (5-type palette), connect edge (outcome + `max_loops`), delete
    (guarded while referenced); trigger editor with three stage selects from the
    board's real stages.
- **Versioning UX**: unsaved-changes bar ("Save as v4 · Discard"); save confirm noting
  "N cards are mid-run on v3 — they finish on v3, new runs use v4"; inline validation
  (W2's rules) blocking save, not erroring after.
- Customized-from-default affordance: "n nodes differ from the shipped default — view
  diff / reset".
- The graph **renderer** is shared: the run panel (run-visibility card) reuses it
  read-only with live node states.

**Out of scope.** The repo-file override layer (per-project-overrides card decides it).

**Acceptance criteria.**

1. Editing the Code flow's `implement` prompt and saving produces v(n+1); a card
   mid-run keeps executing its snapshot version; the next run uses the new one, and
   both versions are visible where the artboard shows them.
2. An invalid edit (edge to a deleted node, second enabled flow pulling from the same
   stage) is blocked at save with an inline error naming the problem.
3. Diff/reset against the shipped default works on a customized flow.
4. Matches the "Relay Flow Editor" artboard's elements/states. `mix precommit` passes.
