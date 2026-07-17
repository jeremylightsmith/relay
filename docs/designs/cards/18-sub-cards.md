# 18 — Sub-cards: decomposition and bigger rework

**Why.** The Rework Loop artboard's second pick (Treatment D): when a fix deserves its
own tracking — or work splits into pieces — add a **child card**. One primitive covers
decomposition *and* rework; to Relay every card is identical, parent/child is a link it
never reasons about.

**Scope.**

- A card can hold child cards; **a child is just a normal card** flowing the full
  pipeline on its own (engine/scheduler unchanged — that's the design's whole point).
- Parent renders its children as a checklist of real cards with live state, per the
  artboard's Treatment D views ("↳ child of …" affix on the board, "N open children"
  on the parent).
- **Settle the artboard's named open question first** (its lean, to confirm at
  /brainstorm): a shipped parent *stays Complete* with an "open children" badge —
  no regression feeling; the fix flows on its own.

**Out of scope.** Runs-as-records (Treatment B — back pocket), two boards (C),
revision-in-place (E), branches (F): all heavier than "usually one fix" warrants.

**Acceptance criteria.**

1. Adding a child to a Done card creates a normal card that flows Spec→…→Done
   independently, with parent/child visible on both per the artboard.
2. Parent state under an open child matches the settled rule; the badge counts open
   children live.
3. Engine and scheduler diffs contain no parent/child awareness.
4. `mix precommit` passes.
