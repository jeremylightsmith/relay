# 16 — Reopen: the default rework gesture

**Why.** `docs/designs/Relay Rework Loop.dc.html` settled the rework model: the pipeline
flows forward once; **re-entering it is a human gesture, never an inference** (its §01).
Treatment A — Reopen — is the chosen default: no runs, no versions, no new nouns.

**Scope.**

- A **Reopen** action on Done/shipped cards: drops the card back onto a chosen stage
  (default Spec) with a `reopened` timeline event carrying the reason; the card flows
  forward again — same card, same artifacts, edited in place; history lives in the
  activity log.
- The engine needs **zero new knowledge**: a reopened card is just a card sitting in a
  from-stage; the scheduler picks it up like any other (the flow's re-entry context is
  the reopen reason + the card's history, same as CHANGES REQUESTED).
- Match the artboard's Treatment A board/card views ("↩ reopened" affix, "moved out ·
  was here" ghost, the banner pointing at the shipped spec to edit in place).
- Card-state validity per ADR 0003 (a Done card re-entering a Work stage) — name any
  rule this forces.

**Out of scope.** Sub-cards (its own card), review-reject routing (already board
machinery + flow re-entry).

**Acceptance criteria.**

1. Reopening a Done card with a reason lands it on Spec with the reopen event on its
   timeline; with the Spec flow enabled, the scheduler picks it up on the next tick and
   the brainstorm node sees the reopen reason.
2. The shipped spec is presented for in-place editing per the artboard's banner.
3. No engine/scheduler code branches on "backward movement" — grep-provable.
4. `mix precommit` passes.
