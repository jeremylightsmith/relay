# ADR 0012 — Board owners pay up front, on their own billing date

## Status

Accepted

## Context

Hamaca Cloud needs revenue, and the hosted app runs agents and keeps boards for people who
aren't paying for them. The paid plan has to stay simple for a board owner ("I paid, so my boards
work") and safe for money: never charge twice, never charge for time that couldn't be used, and
never unlock a board by accident. It also has to vanish entirely for a self-hosted install, which
must never see a limit, a banner or a refusal.

Throughway solved the same problem in its ADR 0014 (paid-up-front billing): an hourly clock of its
own, off-session charges with idempotency keys, a derived standing, and `paid_through` as the only
grant of paid access. Hamaca's case is simpler (one price, no per-seat rate, no credit ledger), so
it ports those rules rather than inventing new ones.

What an owner gets without paying is the Free plan, decided in
[ADR 0013](0013-the-free-plan.md). This ADR decides how paying works.

## Decision

**The board owner pays $20 a month, up front, from their own billing date, for unlimited boards.
A payment buys the next month. An owner who hasn't paid, or whose plan has lapsed, is on Free.
There is never a debt.**

1. **The owner pays.** A board's standing is its owner's (`boards.owner_id`). Members never pay
   and never see a payment surface for a board they don't own. There is one `billing_accounts`
   row per user. The price is `Hamaca.Billing.price_cents/0` (2000 unless `STRIPE_PRICE_CENTS`
   says otherwise).
2. **Pay up front from your own billing date.** A payment from Free (an upgrade) covers one month
   from the day it is made, and that day of the month becomes the account's `billing_day`
   (1–31). A month without that day renews on its last day (`Hamaca.Billing.Periods`). A renewal
   buys the period starting `paid_through + 1`.
3. **`paid_through` is the only grant of paid access.** No invoices, no debt, no proration, no
   refunds, no back-billing. A renewal that isn't paid simply doesn't move `paid_through`.
4. **A 1-day grace for a declined renewal**, with one retry on that day's final clock pass.
   During the grace the owner is past due but keeps unlimited boards. After it, they are on
   Free.
5. **Standing is derived, never stored**: `:free | :active | :comped | {:past_due, until} |
   {:cancelled, access_until} | {:paused, :hold}` (`Hamaca.Billing.Standing`), checked in the
   order hold, comped, cancelled, never paid (`:free`), paid. `:active`, past due, cancelled
   (inside its window) and `:comped` have no board limit (`Standing.unlimited?/1`). Comped
   accounts are never charged. A superadmin hold is the only pause: it makes every one of the
   owner's boards read-only until lifted. Cancelling keeps unlimited boards through
   `paid_through`, then the owner is on Free; resuming before then keeps the billing date.
6. **Read-only, never deleted, behind one gate.** `Hamaca.Billing.board_paused?/1` is the check
   every write path honours: the board LiveView, board settings, the `/api/all` writes, the
   board-key `/api` (402 `plan_paused`) and the run scheduler (dispatches nothing). A board it
   closes behaves like an archived board for every member. It is true for a held owner's boards
   and for the boards [ADR 0013](0013-the-free-plan.md) makes read-only on Free. Nothing is deleted.
7. **Our own clock, not Stripe subscriptions.** The hourly `Hamaca.Billing.Clock` makes
   off-session Stripe PaymentIntents. Each attempt is a `billing_payment_attempts` row committed
   before Stripe is called, with its own idempotency key. At most one attempt per account is
   open. An `unknown` outcome (timeout, 5xx) is resolved with Stripe before any retry and is
   never retried blind. The clock only renews accounts that have paid; a Free owner pays by
   upgrading.
8. **One off switch.** `Hamaca.Billing.enabled?/0` (`BILLING_ENABLED`, which needs both Stripe
   keys outside dev). Off, as on a self-hosted install, there is no clock, no limit, no billing
   page, no banner and no 402, and sign-up opens no billing account.
9. **Two emails, each sent once.** **Card declined** on the first declined clock attempt of a
   period (its retry sends nothing more), and **dropped to Free** on the first day after a paid
   plan's grace ends. Each is recorded in `billing_notices` (unique per account, kind and period)
   before it is sent, so a re-run, a second node or a retry never sends it twice. There is no
   email for cancel, hold or comp; payment receipts stay with Stripe (`receipt_email`).
10. **Promo codes: X paid months at Y% off.** The superadmin creates codes; an owner redeems one
    on the Billing page or through a `/?code=…` sign-up link.
    - **A code discounts the next X charges**, starting with the upgrade for a Free owner, or
      the next renewal for a paying one. It never refunds or re-prices the current month. A
      50%-off, 3-month code means three $10 months, then $20.
    - **One code per account, ever.** Redeeming stores the code and `promo_months_left = X` on
      the account. Each paid attempt that used the discount decrements it under the same row
      lock as the charge. A declined attempt doesn't use up a month; an unknown one uses it only
      once it resolves as paid.
    - **Amount** = `price_cents × (100 − percent_off) / 100`, rounded to the cent, while
      `promo_months_left > 0`, otherwise `price_cents`. One function,
      `Hamaca.Billing.next_charge/1`, serves the clock and the Billing page. Each attempt
      records the amount, code and percent it applied, so history stays accurate after a code
      changes.
    - **A code** has `code` (case-insensitive, unique, stored upper-case), `percent_off`
      (1–100), `months` (≥ 1), optional `max_redemptions`, optional `expires_on`, and
      `disabled_at`. A redemption is refused when the code is unknown, disabled, expired, full,
      or the account already has one (`Hamaca.Billing.promo_refusals/0`); the count is checked
      under a lock, so two people can't take the last slot.
    - **A 100% code charges $0:** Stripe is skipped and a paid $0 attempt is recorded, so
      `paid_through` still moves and no card is needed during those months.
    - **Disabling a code** stops new redemptions. Accounts that already hold it keep their
      remaining months.

The full read and write model is the `Hamaca.Billing` entry in
[`docs/architecture/domain.md`](../architecture/domain.md).

## Consequences

- One rule set, ported from Throughway, means one place to reason about money. The rules are
  pure (`Standing`, `Periods`) and table-tested.
- `Hamaca.Billing` must stay a leaf (Brand, Config, Mailer, Repo and Schemas only), because
  `Hamaca.Accounts` (the account at sign-up) and `Hamaca.Runs` (the scheduler's gate) depend on
  it.
- Owning the clock means owning its failure modes. Double charges are prevented by the
  idempotency key and the one-open-attempt index, not by Stripe's subscription engine, and an
  unknown outcome blocks further charges until it is resolved.
- Every write surface has to honour `board_paused?/1`. A new write path that forgets it is a
  free unlimited board.
- No refunds or proration keeps the code small, but a mid-month cancel forfeits the rest of that
  month's money (unlimited boards continue to `paid_through`).

## Alternatives considered

**Stripe Billing subscriptions.** Stripe would own the clock, retries and dunning, but its model
(invoices, proration, a subscription state we'd mirror) is exactly the debt-and-reconcile shape
this ADR rules out, and Throughway already proved the simpler own-clock design.

**Per-seat or per-board pricing.** Charging members or boards complicates "who pays" for a product
whose unit is the owner's workspace. One flat owner price can grow into team plans later.
