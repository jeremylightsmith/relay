# ADR 0013 — The Free plan

## Status

Accepted

## Context

Hamaca Cloud has to let people use it before they pay, and has to decide what happens to an
owner who stops paying. A countdown (a time-limited trial) gives a hobbyist trying Hamaca after
hours a clock running against them from the day they sign up, and an all-or-nothing lapse locks
an owner out of everything, including the one board they actually use. A permanent free tier with
a hard limit converts better than a countdown and never strands a lapsed owner's work.

The forces are the same as for the paid plan ([ADR 0012](0012-board-owners-pay-up-front.md)):
simple for the owner, safe for money, invisible to a self-hosted install (billing disabled), and
one enforcement point that every write path already honours.

## Decision

**Every owner is on Free, with one editable board and every feature, until they pay for
unlimited boards. A lapsed or cancelled paid plan drops back to Free; it never pauses the owner's
boards.**

1. **Free = one editable board, every feature.** `Hamaca.Billing.free_board_limit/0` (`1`) is
   the one definition. A **counted** board is one the owner owns that is not archived and not an
   example board. Nothing on Free is feature-gated: agents, flows, the API, the runner and push
   all work on the editable board, and members are unlimited.
2. **No card to start.** Sign-up opens an account on Free (`Hamaca.Billing.ensure_account/1`
   writes no date). Free has no end.
3. **A lapse drops to Free.** A declined renewal past its 1-day grace, or a cancelled plan past
   its `access_until`, is `:free` (the standing rules are in ADR 0012). The owner's other boards
   come back the moment they pay again.
4. **Read-only beyond the limit, never deleted.** A Free owner's counted boards other than the
   editable one are read-only for every member, through the same `board_paused?/1` gate as a
   hold, so every write path enforces Free with no check of its own. The board-key API answers
   **402 `plan_paused`**, with a message that names both causes. Archived and example boards
   don't count, so archiving a board frees the slot.
5. **The owner's pick wins; otherwise the most recently active.** The editable board
   (`Hamaca.Billing.editable_board_id/1`) is `billing_accounts.free_board_id`, set by
   `Hamaca.Billing.choose_free_board/2`, while that board is still counted. Otherwise it is the
   counted board with the newest activity (`coalesce(max(cards.updated_at), boards.updated_at)`,
   ties to the higher board id). A nil pick means "most recently active"; an archived or
   transferred pick is ignored, and deleting the board clears it. An owner over the limit is
   asked once which board stays editable, and can change it any time from the Billing page.
6. **Creating past the limit is refused.** `Hamaca.Billing.can_add_board?/1` refuses creating
   or unarchiving a board past the limit, and `board_notice/1` gives a read-only board its
   banner (`{:free_read_only, editable_name}`), naming the editable board.
7. **Upgrade through the setup Checkout, charging a fresh month from today.** A Free owner who
   saves a card is charged at once for a month starting that day, which becomes their billing
   date. A $0 upgrade (a 100% promo code) skips Checkout: `Hamaca.Billing.upgrade_without_card/2`
   records an `:upgrade` $0 attempt that never reaches Stripe. The clock never charges a Free
   account.

The full model (`free_status/2`, the prompt flag, the queries) is the `Hamaca.Billing` entry in
[`docs/architecture/domain.md`](../architecture/domain.md).

## Consequences

- An owner who stops paying keeps working on their chosen or most active board, and nothing is
  lost. Support doesn't field "all my boards are locked".
- One gate, unchanged in shape: every existing write path enforces Free for free. The gate costs
  one grouped query (the editable board) per check for a Free owner; a paying owner costs nothing
  extra.
- Without a pick, the editable board can move as activity shifts between boards. The banner
  names the editable board, so a read-only one explains itself.
- Clients must tolerate standing values they don't know. The mobile app parses an unknown
  standing to null and hides its Plan row, so a new standing never breaks an old build.
- The schema still carries a `trial_ends_on` column and a `:trial_end` attempt kind that nothing
  produces any more. Removing them is a cleanup with no behaviour change.

## Alternatives considered

**A time-limited trial, then pay or pause.** A countdown followed by an all-or-nothing lock gives
the owner a deadline and then a cliff, and needs its own reminder email and edge cases. Free from
day one is one rule.

**A trial, then drop to Free.** Two transitions to understand instead of one, for no gain.

**Pause on lapse.** Simpler to enforce (no editable-board computation), but it strands the
owner's live work, which is exactly the cliff this ADR removes.
