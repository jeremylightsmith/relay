# ADR 0004 — Card ownership & the claim rule

## Status
Accepted (2026-07-11)

## Context

"Who holds the baton" — human vs. agent — is a first-class property of a card (see
`docs/vision.md`). RLY-47 makes it **deterministic, server-side, and permanently
recorded**: ownership is claimed when a card *moves*, and it records **who DID the work**,
not merely who is doing it. Every mover (board drag, "Move to…", the REST
`POST /api/cards/:ref/move`, `approve`/`reject`/`send_back`, and the `bin/relay` runner)
flows through `Relay.Cards.move_card/4`, so the policy lives in exactly one seam.

Ownership is derived against the RLY-46 stage model (ADR 0003), not a design-only "stage
type" column: a **work/planning stage** is a main-lane stage
(`parent_id == nil`) whose `type` is `:work` or `:planning`; an **AI-enabled** stage is
such a stage with `ai_enabled: true`; review gates (`type: :review`), queues
(`type: :queue`), done (`type: :done`), and sub-lanes never claim.

## Decision

1. **The mover decides.** When an **unowned** card enters a stage on a cross-stage move:
   - a **human** (`{:user, id}`) moving it into **any** work/planning stage — AI-enabled or
     not — becomes its sole owner (this locks the agent out);
   - otherwise, a non-human mover (`:agent` — the runner/API) into an **AI-enabled** work
     stage delegates it to **Relay AI**;
   - moves into a queue, done, review gate, or an agent's move into a human-only work stage
     leave the card unowned.
2. **AI ownership is exclusive.** Relay AI and humans never co-own a card. Assigning the AI
   clears every human owner; adding a human to an AI-owned card removes the AI (a take-over).
   Enforced in `Cards.add_owner/3` so no entry point can create a mixed state.
3. **Reviews never transfer ownership.** A reviewer approves or rejects; a rejected card
   resumes with the same owner.
4. **A human-owned card is off-limits to agents.** The runner skips human-owned cards when
   pulling work (in addition to the WIP and blocked guards).
5. **No hand-back — ownership is provenance.** An already-owned card keeps its owners through
   *every* subsequent move; when an AI-owned card reaches a human, review, or done stage the
   agent **keeps** ownership. "Needs you" comes from card *state* (sub-states), never from
   un-owning. A card in Done still shows Relay AI as the one who did the work. A single guard
   in `maybe_claim/3` (owned cards are returned untouched) delivers both #3 and #5.
6. **Ownership is never a stage "mismatch."** Because any owner may legitimately sit in any
   stage under #1 and #5 (a human handling a card in an AI column; the AI's card parked in
   Review/Done), the UI does **not** flag an owner/stage combination as an error. The earlier
   MMF-06 "This stage is meant for humans/agents" warning is retired.

**Take over** lives in the drawer owners rail beside Relay AI (`Cards.take_over/2`); it flips
ownership to the current user instantly and leaves the card's status untouched. Assigning
Relay AI (`Cards.assign_ai/2`) is the mirror hand-off.

## Consequences

- The claim is applied once, inside `move_card/4`'s transaction, for every mover — no client
  bookkeeping is authoritative. The runner's `own`/`release` verbs remain as idempotent
  manual overrides.
- Ownership is stable provenance: history and the Done column reflect who actually did the
  work.
- Supersedes **RLY-27** (auto-own a card = rule 1) and **RLY-28** (human-only cards = a human
  owning a card locks agents out, rule 4). No backfill of any pre-existing AI+human mixed
  rows — the exclusivity invariant is enforced going forward only.

## Alternatives considered

- **The stage decides (AI claims any drop into an AI column).** Rejected: a person dragging a
  card into an AI column to work it themselves would be locked out of their own card, and the
  runner would fight them for it. "The mover decides" matches intent.
- **Hand back ownership at a human stage.** Rejected: it destroys provenance — the record of
  who did the work — which is the whole point.
