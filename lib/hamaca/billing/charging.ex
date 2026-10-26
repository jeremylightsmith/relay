defmodule Hamaca.Billing.Charging do
  @moduledoc """
  The one charging path (RE460, ADR 0012), called only from `Hamaca.Billing`: the clock's
  renewals, a card being saved (a Free account upgrades), the $0 upgrade (`upgrade/2`, RE469),
  the superadmin's retry (`admin_retry/2`, RE463), and resolving answers we never got. A port of
  Throughway's `through_attempt` lifecycle — three steps, Stripe outside any transaction:

    1. **open** (tx 1): lock the account row (`FOR UPDATE`), re-derive the decision on the
       locked row, and insert a `:pending` attempt — committed before Stripe hears of it. The
       one-open-per-account index refuses a second open attempt, so it is never charged twice;
    2. **send**: `Payments.impl().charge/5` under the attempt's idempotency key,
       `"billing-<account_id>-<period_start>-<attempt_number>"`;
    3. **settle** (tx 2): re-lock the account and the attempt and write the answer only while the
       attempt is still open.

  Only a bank's refusal is a decline (`:failed`). Anything else — processing, a timeout, a 5xx,
  a raise after tx 1 committed — is `:unknown`: the account is untouched, no further charge
  opens, and `resolve_open/1` asks Stripe (`find_payment/3`) before anything is retried.
  `{:billing_changed, user_id}` goes out after each commit.
  """

  import Ecto.Query

  alias Hamaca.Billing
  alias Hamaca.Billing.Payments
  alias Hamaca.Billing.Periods
  alias Hamaca.Billing.Standing
  alias Hamaca.Brand
  alias Hamaca.Repo
  alias Schemas.BillingAccount
  alias Schemas.BillingPaymentAttempt
  alias Schemas.User

  require Logger

  @pending_overdue_minutes 10
  @one_open_index :billing_payment_attempts_one_open_per_account
  # The PaymentIntent statuses that mean the charge failed for good.
  @failed_intent_statuses ["requires_payment_method", "canceled"]

  @typedoc "What a charge came to; `:not_charged` only when resolving (Stripe never saw it)."
  @type outcome :: :none | :paid | :declined | :unknown | :not_charged

  @doc "How old a `:pending` attempt must be, in minutes, before the clock asks Stripe about it."
  @spec pending_overdue_minutes() :: 10
  def pending_overdue_minutes, do: @pending_overdue_minutes

  @doc "The attempt facts `Standing.of/3` reads for `account` (looks up its declined attempts; `facts/2`)."
  @spec facts(BillingAccount.t() | nil) :: Standing.facts()
  def facts(%BillingAccount{paid_through: nil, id: id} = account) do
    facts(
      account,
      Repo.exists?(from p in BillingPaymentAttempt, where: p.billing_account_id == ^id and p.status == :failed)
    )
  end

  def facts(account), do: facts(account, false)

  @doc """
  Pure: the facts `Standing.of/3` reads for `account`, given whether it has ≥ 1 `:failed` attempt
  (`declined?`). A paid account, or no account, has neither fact.
  """
  @spec facts(BillingAccount.t() | nil, boolean()) :: Standing.facts()
  def facts(%BillingAccount{paid_through: nil} = account, declined?) when is_boolean(declined?),
    do: %{first_charge_declined?: declined?, next_charge_free?: next_charge_free?(account)}

  def facts(_account, declined?) when is_boolean(declined?),
    do: %{first_charge_declined?: false, next_charge_free?: false}

  defp next_charge_free?(account), do: Billing.next_charge(account).amount_cents == 0

  @doc """
  Charges every account the clock decision says is due on `today`, each isolated so one failure
  never stops the rest. A candidate has a card, or discounted months left (a free one needs no
  card — `chargeable?/1` decides). Answers how many attempts were made.
  """
  @spec charge_due(Date.t(), boolean()) :: non_neg_integer()
  def charge_due(%Date{} = today, final_pass?) do
    from(a in BillingAccount,
      where:
        (not is_nil(a.card_payment_method_id) or a.promo_months_left > 0) and not a.comped and is_nil(a.held_on) and
          is_nil(a.cancelled_on),
      select: a.id
    )
    |> Repo.all()
    |> Enum.count(&(charge_isolated(&1, today, final_pass?) != :none))
  end

  defp charge_isolated(account_id, today, final_pass?) do
    through_attempt(account_id, &clock_decision(&1, today, final_pass?))
  rescue
    error ->
      Logger.error(
        "Billing.Charging: account #{account_id} was not charged. " <> Exception.format(:error, error, __STACKTRACE__)
      )

      :none
  end

  @doc """
  Stores `setup`'s customer and card on the user's account, then charges as the card-saved
  decision says: a past-due account renews, a Free one pays a fresh month from `today`. The
  account must exist.
  """
  @spec save_card(Payments.setup(), Date.t()) :: {:ok, %{account: BillingAccount.t(), charged: outcome()}}
  def save_card(setup, %Date{} = today) do
    {1, [account_id]} =
      Repo.update_all(
        from(a in BillingAccount, where: a.user_id == ^setup.user_id, select: a.id),
        set: [
          stripe_customer_id: setup.customer_id,
          card_payment_method_id: setup.payment_method_id,
          card_brand: setup.brand,
          card_last4: setup.last4,
          card_exp_month: setup.exp_month,
          card_exp_year: setup.exp_year,
          updated_at: now()
        ]
      )

    :ok = Billing.broadcast_changed(setup.user_id)
    charged = through_attempt(account_id, &pay_now_decision(&1, today, :card_saved))
    {:ok, %{account: Repo.get!(BillingAccount, account_id), charged: charged}}
  end

  @doc """
  The $0 upgrade (RE469) on account `account_id`: a Free account whose next charge is $0 (a 100%
  promo code, so no card is needed) pays a fresh month from `today`, recorded as an `:upgrade`
  `:returned` attempt that never reaches Stripe. `:none` for any other standing, a priced next
  charge, or an open attempt.
  """
  @spec upgrade(pos_integer(), Date.t()) :: outcome()
  def upgrade(account_id, %Date{} = today), do: through_attempt(account_id, &upgrade_decision(&1, today))

  defp upgrade_decision(account, today) do
    if Standing.of(account, facts(account), today) == :free and not open_attempt?(account.id) and
         next_charge_free?(account),
       do: fresh_month(:returned, :upgrade, today),
       else: :none
  end

  @doc """
  The superadmin's "Retry charge now" (RE463) on account `account_id`: the card-saved rule —
  a past-due account renews, a Free one pays a fresh month from `today` — recorded as an
  `:admin` attempt. `:none` when an attempt is open or there is no card.
  An `:admin` decline sends no email and never spends the clock's grace-day retry.
  """
  @spec admin_retry(pos_integer(), Date.t()) :: outcome()
  def admin_retry(account_id, %Date{} = today), do: through_attempt(account_id, &pay_now_decision(&1, today, :admin))

  @doc """
  Asks Stripe about every `:unknown` attempt and every `:pending` one older than
  `pending_overdue_minutes/0` at `now`, settling what it answers. Answers how many settled.
  """
  @spec resolve_open(DateTime.t()) :: non_neg_integer()
  def resolve_open(%DateTime{} = now) do
    cutoff = DateTime.add(now, -@pending_overdue_minutes, :minute)

    from(a in BillingPaymentAttempt,
      where: a.status == :unknown or (a.status == :pending and a.inserted_at <= ^cutoff)
    )
    |> Repo.all()
    |> Enum.count(&(resolve_isolated(&1) in [:paid, :declined, :not_charged]))
  end

  defp resolve_isolated(attempt) do
    answer =
      attempt.stripe_customer_id
      |> Payments.impl().find_payment(attempt.stripe_payment_intent_id, %{
        id: attempt.id,
        inserted_at: attempt.inserted_at
      })
      |> found_answer(attempt)

    settle(attempt, answer)
  rescue
    error ->
      Logger.error(
        "Billing.Charging: attempt #{attempt.id} was not resolved. " <> Exception.format(:error, error, __STACKTRACE__)
      )

      :unknown
  end

  defp found_answer({:ok, %{status: "succeeded"} = found}, _attempt),
    do: {:succeeded, %{id: found.id, receipt_url: found.receipt_url}}

  defp found_answer({:ok, %{status: status} = found}, _attempt) when status in @failed_intent_statuses,
    do: {:failed, found.decline_reason || "payment " <> status}

  defp found_answer({:ok, :none}, _attempt), do: :not_charged
  defp found_answer({:ok, %{status: status, id: id}}, _attempt), do: {:unknown, status, id}

  defp found_answer({:error, reason}, attempt), do: {:unknown, inspect(reason), attempt.stripe_payment_intent_id}

  # The clock decision, on the locked row: renew only a paid account with a card on file (or a $0
  # month, which needs none), never a held, comped or cancelled one, never a never-paid (Free) one
  # — it pays by upgrading — and never one holding an open attempt.
  defp clock_decision(account, today, final_pass?) do
    cond do
      not chargeable?(account) -> :none
      is_nil(account.paid_through) -> :none
      open_attempt?(account.id) -> :none
      Standing.paused?(Standing.of(account, facts(account), today)) -> :none
      today == Periods.next_renewal(account.paid_through) -> grace_day_decision(account, final_pass?)
      true -> :none
    end
  end

  defp chargeable?(account),
    do:
      (Standing.card_on_file?(account) or next_charge_free?(account)) and is_nil(account.held_on) and not account.comped and
        is_nil(account.cancelled_on)

  # The grace day: the renewal, once; then one retry on the day's final pass.
  defp grace_day_decision(account, final_pass?) do
    start = Periods.next_renewal(account.paid_through)

    clock_statuses =
      Repo.all(
        from a in BillingPaymentAttempt,
          where: a.billing_account_id == ^account.id and a.period_start == ^start and a.source == :clock,
          select: a.status
      )

    case {clock_statuses, final_pass?} do
      {[], _final_pass?} -> renewal(account, :clock)
      {[:failed], true} -> renewal(account, :clock)
      _tried -> :none
    end
  end

  # The pay-now decision, on the locked row: a card being saved (`:card_saved`, the card already
  # stored) or the superadmin's retry (`:admin`) — one rule, recorded under its source.
  defp pay_now_decision(account, today, source) do
    if open_attempt?(account.id) or not Standing.card_on_file?(account) do
      :none
    else
      case Standing.of(account, facts(account), today) do
        {:past_due, _until} -> renewal(account, source)
        # A hold pauses until lifted, whatever the card; Free (never paid, lapsed or cancelled
        # out) upgrades on a fresh month from today.
        {:paused, :hold} -> :none
        :free -> fresh_month(:returned, source, today)
        _no_charge -> :none
      end
    end
  end

  defp renewal(account, source) do
    start = Periods.next_renewal(account.paid_through)
    billing_day = Periods.kept_billing_day(account.billing_day, start)
    {:charge, charge(:renewal, source, start, billing_day)}
  end

  defp fresh_month(kind, source, today), do: {:charge, charge(kind, source, today, today.day)}

  defp charge(kind, source, start, billing_day) do
    {^start, last} = Periods.period(start, billing_day)
    %{kind: kind, source: source, period_start: start, period_end: last, billing_day: billing_day}
  end

  defp open_attempt?(account_id) do
    Repo.exists?(
      from a in BillingPaymentAttempt,
        where: a.billing_account_id == ^account_id and a.status in ^BillingPaymentAttempt.open_statuses()
    )
  end

  # Open (tx 1) → send → settle (tx 2). Answers what the charge came to, or `:none`.
  defp through_attempt(account_id, decide) do
    opened =
      Repo.transact(fn ->
        account = lock_account(account_id)

        case decide.(account) do
          :none -> {:ok, :none}
          {:charge, charge} -> open_attempt(account, charge)
        end
      end)

    case opened do
      {:ok, :none} ->
        :none

      {:ok, %BillingPaymentAttempt{} = attempt} ->
        :ok = Billing.broadcast_changed(attempt_user_id(attempt))
        send_and_settle(attempt)

      {:error, :open_attempt} ->
        :none
    end
  end

  defp lock_account(account_id), do: Repo.one!(from a in BillingAccount, where: a.id == ^account_id, lock: "FOR UPDATE")

  defp open_attempt(account, charge) do
    attempt_number =
      Repo.aggregate(
        from(a in BillingPaymentAttempt,
          where: a.billing_account_id == ^account.id and a.period_start == ^charge.period_start
        ),
        :count
      ) + 1

    next_charge = Billing.next_charge(account)

    %BillingPaymentAttempt{
      billing_account_id: account.id,
      status: :pending,
      kind: charge.kind,
      source: charge.source,
      amount_cents: next_charge.amount_cents,
      promo_code: next_charge.promo_code,
      promo_percent_off: next_charge.percent_off,
      period_start: charge.period_start,
      period_end: charge.period_end,
      billing_day: charge.billing_day,
      attempt_number: attempt_number,
      idempotency_key: "billing-#{account.id}-#{Date.to_iso8601(charge.period_start)}-#{attempt_number}",
      paid_through_before: account.paid_through,
      stripe_customer_id: account.stripe_customer_id,
      stripe_payment_method_id: account.card_payment_method_id
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:billing_account_id, name: @one_open_index)
    |> Repo.insert()
    |> case do
      {:ok, attempt} -> {:ok, attempt}
      {:error, _changeset} -> {:error, :open_attempt}
    end
  end

  # Tx 1 has committed: whatever happens now says nothing about the card, so a raise is
  # `:unknown`, never a decline. A settle that itself fails leaves the attempt `:pending` for
  # `resolve_open/1`.
  defp send_and_settle(attempt) do
    settle(attempt, send_charge(attempt))
  rescue
    error ->
      Logger.error(
        "Billing.Charging: attempt #{attempt.id} has no answer recorded. " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :unknown
  end

  # A $0 month (a 100% promo code) never reaches Stripe: it is paid as it stands.
  defp send_charge(%BillingPaymentAttempt{amount_cents: 0}), do: {:succeeded, %{id: nil, receipt_url: nil}}

  defp send_charge(attempt) do
    meta = %{description: description(attempt), receipt_email: receipt_email(attempt), attempt_id: attempt.id}

    attempt.stripe_customer_id
    |> Payments.impl().charge(attempt.stripe_payment_method_id, attempt.amount_cents, attempt.idempotency_key, meta)
    |> charge_answer()
  rescue
    error -> {:unknown, Exception.message(error), nil}
  end

  defp charge_answer({:ok, %{id: _id} = charged}), do: {:succeeded, charged}
  defp charge_answer({:error, {:declined, reason}}), do: {:failed, reason}
  defp charge_answer({:error, {:processing, payment_intent_id}}), do: {:unknown, "processing", payment_intent_id}
  defp charge_answer({:error, reason}), do: {:unknown, inspect(reason), nil}

  # "Hamaca · Apr 4 – May 3, 2026" — the product name from `Hamaca.Brand`
  defp description(attempt),
    do:
      "#{Brand.name()} · #{month_day(attempt.period_start)} – #{month_day(attempt.period_end)}, #{attempt.period_end.year}"

  defp month_day(date), do: Calendar.strftime(date, "%b %-d")

  defp receipt_email(attempt) do
    Repo.one(
      from u in User,
        join: a in BillingAccount,
        on: a.user_id == u.id,
        where: a.id == ^attempt.billing_account_id,
        select: u.email
    )
  end

  # Tx 2: the answer written only while the attempt is still open.
  defp settle(attempt, answer) do
    {:ok, outcome} =
      Repo.transact(fn ->
        account = lock_account(attempt.billing_account_id)
        locked = Repo.one!(from a in BillingPaymentAttempt, where: a.id == ^attempt.id, lock: "FOR UPDATE")

        if locked.status in BillingPaymentAttempt.open_statuses(),
          do: write_answer(account, locked, answer),
          else: {:ok, settled_outcome(locked)}
      end)

    :ok = Billing.broadcast_changed(attempt_user_id(attempt))
    outcome
  end

  defp write_answer(account, attempt, {:succeeded, charged}) do
    resolve!(attempt, :succeeded, stripe_payment_intent_id: charged.id, receipt_url: charged.receipt_url)

    cancellation = if attempt.kind == :returned, do: [cancelled_on: nil, access_until: nil], else: []
    # A paid month that used the discount spends one of the code's months, under this row lock.
    promo_month = if attempt.promo_code, do: [promo_months_left: max(account.promo_months_left - 1, 0)], else: []

    account
    |> Ecto.Changeset.change(
      [
        paid_through: later(account.paid_through, attempt.period_end),
        billing_day: attempt.billing_day,
        # Leaving Free re-arms the one-time board prompt for a later drop (RE471); the pick survives.
        free_board_prompted_at: nil
      ] ++ cancellation ++ promo_month
    )
    |> Repo.update!()

    {:ok, :paid}
  end

  defp write_answer(_account, attempt, {:failed, reason}) do
    resolve!(attempt, :failed, decline_reason: reason)
    {:ok, :declined}
  end

  defp write_answer(_account, attempt, :not_charged) do
    resolve!(attempt, :not_charged, [])
    {:ok, :not_charged}
  end

  defp write_answer(_account, attempt, {:unknown, error, payment_intent_id}) do
    attempt
    |> Ecto.Changeset.change(
      status: :unknown,
      error: error,
      stripe_payment_intent_id: payment_intent_id || attempt.stripe_payment_intent_id
    )
    |> Repo.update!()

    {:ok, :unknown}
  end

  defp resolve!(attempt, status, changes) do
    attempt
    |> Ecto.Changeset.change([status: status, resolved_at: now()] ++ changes)
    |> Repo.update!()
  end

  defp settled_outcome(%BillingPaymentAttempt{status: :succeeded}), do: :paid
  defp settled_outcome(%BillingPaymentAttempt{status: :failed}), do: :declined
  defp settled_outcome(%BillingPaymentAttempt{status: :not_charged}), do: :not_charged

  defp later(nil, date), do: date
  defp later(%Date{} = current, date), do: if(Date.after?(current, date), do: current, else: date)

  defp attempt_user_id(attempt),
    do: Repo.one!(from a in BillingAccount, where: a.id == ^attempt.billing_account_id, select: a.user_id)

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
