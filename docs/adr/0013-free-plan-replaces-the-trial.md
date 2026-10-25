# ADR 0013 — The Free plan replaces the trial

## Status

Accepted (2026-10-25)

Amends [ADR 0012](0012-board-owners-pay-up-front.md): supersedes its §4 (the 30-day trial), §6
(the standing set), §7 (what a lapsed plan pauses) and §10's trial-ending and paused emails.
Everything else in ADR 0012 — the owner pays, pay up front from your own billing date,
`paid_through` as the only grant of paid access, the 1-day grace, our own clock, the one off
switch, promo codes — stands.

## Context

ADR 0012 gave every new owner a 30-day no-card trial and paused **every** board the moment a
trial ended unpaid or a paid plan lapsed. That makes the first month free and every month after
it all-or-nothing: an owner who doesn't pay loses edit access to everything, including the one
board they actually use, and a hobbyist trying Relay after hours has a clock running against
them from the day they sign up. A permanent free tier with a hard limit converts better than a
countdown and never strands a lapsed owner's work.

The forces stay the same as ADR 0012's: simple for the owner, safe for money, invisible to a
self-hosted install (billing disabled), and one enforcement point every write path already
honours.

## Decision

**Every owner is on Free — one live owned board, every feature — until they pay $20 a month for
unlimited boards. A lapsed paid plan drops back to Free instead of pausing every board.**

1. **Free = one editable board, every feature.** `Relay.Billing.free_board_limit/0` (`1`) is the
   one definition. A **counted** board is one the owner owns, not archived and not an example
   board. Nothing on Free is feature-gated: agents, flows, the API and the runner all work on the
   editable board.
2. **$20 a month buys unlimited boards.** Paid standings (`:active`, `{:past_due, _}`,
   `{:cancelled, _}` inside its access window, and `:comped`) have no board limit
   (`Relay.Billing.Standing.unlimited?/1`).
3. **A lapse drops to Free, not to a pause.** A declined renewal past its 1-day grace, or a
   cancelled plan past its `access_until`, is `:free`. The only pause left is a superadmin hold.
4. **Read-only, never deleted.** A Free owner's counted boards beyond the limit are read-only for
   every member — the same read-only mode a paused board had — and nothing is deleted. Archived
   and example boards don't count, so archiving one frees the slot.
5. **The editable board is computed, not stored.** It is the counted board with the newest
   activity (`coalesce(max(cards.updated_at), boards.updated_at)`, ties to the higher board id) —
   `Relay.Billing.editable_board_id/1`. Slice 2 ([RE471 Choose which board stays editable on
   Free]) adds an explicit pick on top.
6. **`board_paused?/1` stays the one gate.** `Relay.Billing.board_paused?/1` answers true for a
   held owner's boards **or** a board that is read-only on Free, so every write path that already
   honoured a pause — the board LiveView, board settings, the `/api/all` writes, the board-key
   `/api`, the run scheduler — honours Free with no new check. The board-key API keeps answering
   **402 `plan_paused`** (same code, same runner contract fixture, no `./relay` change); only the
   message widens to "paused or on Free". `can_add_board?/1` refuses creating or unarchiving a
   board past the limit; `board_notice/1` gives the banner (`{:free_read_only, editable_name}`).
7. **The standing set** is `:free | :active | :comped | {:past_due, until} |
   {:cancelled, access_until} | {:paused, :hold}`, derived, never stored
   (`Relay.Billing.Standing`), checked in the order hold, comped, cancelled, never paid
   (`:free`), paid. `Standing.kinds/0` is `[:free, :active, :past_due, :cancelled, :comped,
   :paused]`; `Standing.pause_reasons/0` is `[:hold]`.
8. **Upgrade through the setup Checkout, charging a fresh month from today.** A Free owner (never
   paid, lapsed, or cancelled out) who saves a card is charged at once for a month starting that
   day, which becomes their billing date. A $0 upgrade (a 100% promo code) skips Checkout:
   `Relay.Billing.upgrade_without_card/2` records an `:upgrade`-sourced $0 attempt that never
   reaches Stripe. The clock never charges a Free account — it only renews paid ones.
9. **Two emails, each once:** **card declined** (unchanged) and **dropped to Free**
   (`Relay.Billing.Notifier.dropped_to_free_email/1`, notice kind `:dropped_to_free`), sent the
   first day a paid plan's grace is over. The trial-ending and paused emails are gone; a new
   account is opened by `ensure_account/1`, which writes no date.
10. **The launch migration comps multi-board trial owners.** `FreemiumLaunch` comps every
    never-paid, uncomped, unheld account owning more than one counted board (with an admin entry
    naming the count, for manual outreach), so nobody's boards go read-only on launch day;
    everyone else simply reads as Free. It also rewrites the retired notice kinds so the schema
    keeps loading. There is no launch backfill of dates; the `trial_ends_on` column stays, unused.

## Consequences

- An owner who stops paying keeps working on their most active board; their other boards are
  intact and come back the moment they upgrade. Support no longer fields "all my boards are
  locked".
- One gate, unchanged in shape: every existing write path enforces Free for free, but the gate
  now costs one grouped query (the editable board) per check for a Free owner. A paying owner
  costs nothing extra.
- The editable board can change under an owner as activity shifts between boards (slice 2's
  explicit pick fixes this); until then the banner names the editable board so the read-only one
  explains itself.
- **An older mobile build** receiving `"standing": "free"` doesn't know the value, so it parses
  to null and hides the Settings Plan row. That is the intended degradation — no server shim;
  the app ships a `free` value and a "Free" label.
- Historical attempt rows keep their `:trial_end` kind (nothing new produces it), and the
  `trial_ends_on` column is left in place until a later cleanup.
- Landing-page pricing still describes the trial until slice 4 ([RE473 Landing pricing: three
  tiers (Self-host, Free, Cloud $20)]).

## Alternatives considered

**Keep the trial, then drop to Free.** A countdown followed by a limit gives the owner two
transitions to understand and keeps the trial-ending email and its edge cases; Free from day one
is one rule.

**Pause on lapse, as before.** Simpler to enforce (no editable-board computation), but it
strands the owner's live work and is exactly the cliff this ADR removes.

**Store the editable board.** A stored pick needs a migration, a backfill and a rule for when it
goes stale (archived, deleted, transferred); computing it from activity needs none of that, and
slice 2 can layer an explicit choice on top.
