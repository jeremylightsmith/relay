# ADR 0012 — Board owners pay up front, on their own billing date

## Status

Accepted (2026-10-24)

Amended by [ADR 0013](0013-free-plan-replaces-the-trial.md) (2026-10-25): the Free plan replaces
the trial; a lapsed plan drops to Free instead of pausing. §4, §6, §7 and §10's trial-ending and
paused emails are superseded there.

## Context

Relay Cloud needs revenue, and the hosted app runs agents and keeps boards for people who are
not paying for any of it. The model has to stay simple for a board owner ("I paid, so my boards
work") and safe for money: never charge twice, never charge for time that couldn't be used, and
never let a board in for free by accident. It also has to vanish entirely for a self-hosted
install, which must never see a trial, a banner or a refusal.

Throughway solved the same problem in its ADR 0014 (paid-up-front billing): an hourly clock of
its own, off-session charges with idempotency keys, a derived standing and `paid_through` as the
only grant of access. Relay's case is simpler — one price, no coaches × rate, no credit ledger —
so it ports those rules rather than inventing new ones.

## Decision

**The board owner pays $20 a month, up front, from their own billing date. A payment buys the
next month. If the owner hasn't paid, every board they own is paused. There is never a debt.**

1. **The owner pays.** A board's standing is its owner's (`boards.owner_id`); members never pay
   and never see a payment surface for a board they don't own. One `billing_accounts` row per
   user.
2. **Pay up front from your own billing date.** The first payment covers one month from the day
   it is made, and that day of the month (`billing_day`, 1–31) is kept; a month without that day
   renews on its last day. A renewal buys the period starting `paid_through + 1`. A paused
   (returning) account that pays starts a fresh month from that day.
3. **`paid_through` is the only grant of paid access.** No invoices, no debt, no proration, no
   refunds, no back-billing: a renewal that isn't paid simply doesn't move `paid_through`.
4. **A 30-day trial with no card.** A user's trial starts at sign-up (and, at launch, from the
   day billing is switched on — every existing owner is backfilled with a fresh trial). A card
   saved during the trial is first charged when the trial ends. A trial gets no grace: if it ends
   with no card or the first charge is declined, the owner is paused at once.
   *Superseded by [ADR 0013](0013-free-plan-replaces-the-trial.md) §1, §8, §10: there is no trial; every owner starts on Free.*
5. **A 1-day grace for a declined renewal**, with one retry at the end of that day. During grace
   the owner is past due but fully usable.
6. **Standing is derived, never stored**: `:trial | :active | :comped | {:past_due, until} |
   {:cancelled, access_until} | {:paused, :trial_ended | :unpaid | :cancelled | :hold}`, checked
   in the order hold, comped, cancelled, then the trial or paid rules
   (`Relay.Billing.Standing`). Comped accounts are never charged and never pause; an admin hold
   pauses until lifted. Cancelling keeps access through the trial's end or `paid_through`;
   resuming before then keeps the billing date.
   *Superseded by [ADR 0013](0013-free-plan-replaces-the-trial.md) §7: `:free | :active | :comped | {:past_due, _} | {:cancelled, _} | {:paused, :hold}`.*
7. **Paused means read-only, never deleted.** A paused owner's boards behave like an archived
   board — read-only, no cards opening, no board settings — for every member, and the board-key
   API answers **402 `plan_paused`**; the run scheduler dispatches nothing for them. Data is kept.
   *Amended by [ADR 0013](0013-free-plan-replaces-the-trial.md) §3, §4, §6: only a hold pauses every board; a lapse drops to Free, where boards past the limit are read-only the same way.*
8. **Our own clock, not Stripe subscriptions.** An hourly `Relay.Billing.Clock` makes
   off-session Stripe PaymentIntents, each attempt a `billing_payment_attempts` row committed
   before Stripe is called and carrying its own idempotency key. At most one attempt per account
   is open; an `unknown` outcome (timeout, 5xx) is resolved with Stripe before any retry and is
   never retried blind.
9. **One off switch.** `Relay.Billing.enabled?/0` (`BILLING_ENABLED`, which needs both Stripe
   keys outside dev). Off — a self-hosted install — there is no clock, nothing is paused, no
   trial starts, no billing page, no banner and no 402.
10. **Three emails, each once** (RE464). The clock sends **trial ending** two days before
    `trial_ends_on` to an owner with no card who is not comped; **card declined** on the first
    declined clock attempt of a period (its retry sends nothing more); **paused** on the first
    pass that finds the plan paused for `trial_ended` or `unpaid`. Each is recorded in
    `billing_notices` (unique per account, kind and period) before it is sent, so a re-run, a
    second node or a retry never sends it twice. No email for cancel, hold or comp; payment
    receipts stay with Stripe (`receipt_email`).
    *Amended by [ADR 0013](0013-free-plan-replaces-the-trial.md) §9: the trial-ending and paused emails are gone; card declined stays and dropped to Free is added.*

11. **Promo codes (RE462): X paid months at Y% off.** The superadmin creates codes; an owner
    redeems one on the Billing page or through a `/?code=…` sign-up link.
    - **A code applies to paid months, never the trial.** RELAYCONF (50% off, 3 months) gives
      trial → $10 × 3 → $20. A code redeemed mid-plan discounts the next X charges from the next
      renewal on; it doesn't refund or re-price the current month.
    - **One code per account, ever.** Redeeming stores the code and `promo_months_left = X` on
      the billing account. Each **paid** attempt that used the discount decrements it, under the
      same row lock as the charge (tx 2). Declined attempts don't use up a month; an unknown one
      uses it only once it resolves as paid.
    - **Amount** = `price_cents × (100 − percent_off) / 100`, rounded to the cent, while
      `promo_months_left > 0`, otherwise `price_cents` — one function,
      `Relay.Billing.next_charge/1`, called by the clock and by the Billing page preview. Each
      attempt records the amount, the code and the percent it applied, so history stays accurate
      after a code changes.
    - **A code** has `code` (case-insensitive and unique, stored upper-case), `percent_off`
      (1–100), `months` (≥ 1), optional `max_redemptions`, optional `expires_on`, and
      `disabled_at`. A redemption is refused when the code is unknown, disabled, expired (today >
      `expires_on`) or full (redemptions ≥ cap), or when the account already has a code; the
      count is checked under a lock, so two people can't take the last slot. **A 100% code charges
      $0:** the Stripe call is skipped and a paid attempt is recorded for $0, so `paid_through`
      still moves and no card is needed during those months.
    - **Disabling a code** stops new redemptions. Accounts that already redeemed it keep their
      remaining months.

## Consequences

- One rule set, ported from Throughway ADR 0014, means one place to reason about money; the
  rules are pure (`Standing`, `Periods`) and table-tested.
- `Relay.Billing` must stay a leaf (Config, `Relay.Mailer`, Repo, Schemas only), because `Relay.Accounts` (trial
  at sign-up) and `Relay.Runs` (the scheduler's pause) depend on it.
- Owning the clock means owning its failure modes: double charges are prevented by the
  idempotency key and the one-open-attempt index, not by Stripe's subscription engine, and an
  unknown outcome blocks further charges until it is resolved.
- Every write surface — LiveView, `/api/all` writes, the board-key `/api`, the scheduler — has to
  honour a paused board; a new write path that forgets is a free board.
- No refunds or proration keeps the code small but means a mid-month cancel forfeits the rest of
  the month's money (access continues to `paid_through`).

## Alternatives considered

**Stripe Billing subscriptions.** Stripe would own the clock, retries and dunning, but its model
(invoices, proration, a subscription state we'd mirror) is exactly the debt-and-reconcile shape
this ADR rules out, and Throughway already proved the simpler own-clock design.

**Per-seat or per-board pricing.** Charging members or boards complicates "who pays" for a
product whose unit is the owner's workspace; one flat owner price can grow into Team plans later.
