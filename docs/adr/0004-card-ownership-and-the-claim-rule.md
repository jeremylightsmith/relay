# ADR 0004 — Card ownership & the claim rule

## Status

Accepted

## Context

"Who holds the baton", human or agent, is a first-class property of a card (see
[`docs/vision.md`](../vision.md)). It has to be decided on the server and the same way for
every mover, and it has to survive the card's whole life, because the board shows who did the
work, not only who is doing it now.

Ownership lives on the card, never on the stage. A card has zero or more owners
(`Schemas.CardOwner`, `actor_type` `:user` with a `user_id`, or `:agent` for the single Hamaca
AI). Who holds the baton is derived from them, never stored: `Hamaca.Cards.active_owner_type/1`
is `:ai`, `:human` or `nil`. A stage is the agent's only in the sense that an enabled flow works
it (`Hamaca.Flows.ai_stage_ids/1`). Every move goes through `Hamaca.Cards.move_card/4`, so that's
where the policy lives.

## Decision

1. **The mover decides.** An **unowned** card claims an owner when a cross-stage move takes it
   into a main-lane work or planning stage (`Schemas.Stage.work_types/0`):
   - a human (`{:user, id}`) moving it into any work or planning stage becomes its sole owner,
     whether or not a flow works there;
   - a non-human mover (the engine or an API key, acting as `:agent`) moving it into a work stage
     that a flow works delegates it to the Hamaca AI;
   - anything else leaves it unowned: a queue, review or done stage, any substage, or an agent
     moving it into a stage no flow works.
2. **The AI never co-owns.** Assigning the AI removes every human owner; adding a human to an
   AI-owned card removes the AI. Several humans may co-own a card.
3. **Reviews never transfer ownership.** A reviewer approves or rejects; a rejected card comes
   back with the same owner.
4. **A human-owned card is off-limits to agents.** The scheduler never pulls or resumes one
   (`Hamaca.Runs.Policy.agent_may_hold?/1`). If a human takes over a card mid-run, the run's
   job is revoked and the run parks until the card is handed back to the AI. It then resumes at
   the node it stopped on, in a fresh agent session, because the human may have changed anything.
5. **Ownership is provenance, so there's no hand-back.** An owned card keeps its owners through
   every move (`maybe_claim/3` leaves an owned card untouched, which also delivers rule 3). When
   an AI-owned card reaches a review or done stage, the AI stays its owner. "Needs you" comes from
   the card's status, never from un-owning it.
6. **No owner sits in the wrong stage.** Any owner can legitimately be in any stage (a human
   working a card in an AI column, the AI's card in Review or Done), so the UI never flags an
   owner/stage combination as a mismatch.

Explicit changes sit beside the claim rule. **Take over** in the drawer
(`Hamaca.Cards.take_over/2`) makes the current user sole owner, and assigning the AI
(`Hamaca.Cards.assign_ai/2`) is the mirror hand-off. `./hamaca own` / `./hamaca release` set the
owners to the AI or to nobody. None of them changes the card's status.

## Consequences

- The claim happens once, inside `move_card/4`'s transaction, for every mover. No client keeps
  authoritative ownership state.
- History and the Done column show who actually did the work.
- A human can always stop an agent by taking the card. Handing the card back is the only thing
  that lets the agent continue.
- Every user owner must be a member of the card's board, checked on every owner write
  (`{:error, :owner_not_member}`).

## Alternatives considered

- **The stage decides: the AI claims any card dropped in an AI column.** Rejected: a person
  dragging a card into an AI column to work it themselves would be locked out of their own card,
  and the agent would fight them for it.
- **Hand ownership back when a card reaches a human stage.** Rejected: it destroys provenance,
  the record of who did the work, which is the point of keeping ownership.

## Open questions

- **The owner-list write doesn't enforce rule 2.** `Hamaca.Cards.set_owners/3`, which
  `PATCH /api/cards/:ref` with `owners` uses, stores the list it's given, so
  `["agent", "user:<id>"]` creates a mixed card that reads as `:ai`. `add_owner/3`, `take_over/2`
  and `assign_ai/2` all enforce exclusivity. Should `set_owners/3` refuse a mixed list, or
  resolve it?
