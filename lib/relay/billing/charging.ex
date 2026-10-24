defmodule Relay.Billing.Charging do
  @moduledoc """
  The one charging path (RE460, ADR 0012), called only from `Relay.Billing`: the clock's
  first charges and renewals, a card being saved, and resolving answers we never got. A port of
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

  alias Relay.Billing
  alias Relay.Billing.Payments
  alias Relay.Billing.Periods
  alias Relay.Billing.Standing
  alias Relay.Repo
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

  @doc "The attempt facts `Standing.of/3` reads for `account`."
  @spec facts(BillingAccount.t() | nil) :: Standing.facts()
  def facts(%BillingAccount{paid_through: nil, id: id}) do
    %{
      first_charge_declined?:
        Repo.exists?(from p in BillingPaymentAttempt, where: p.billing_account_id == ^id and p.status == :failed)
    }
  end

  def facts(_account), do: %{first_charge_declined?: false}

  @doc """
  Charges every account the clock decision says is due on `today`, each isolated so one failure
  never stops the rest. Answers how many attempts were made.
  """
  @spec charge_due(Date.t(), boolean()) :: non_neg_integer()
  def charge_due(%Date{} = today, final_pass?) do
    from(a in BillingAccount,
      where: not is_nil(a.card_payment_method_id) and not a.comped and is_nil(a.held_on) and is_nil(a.cancelled_on),
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
  decision says. The account must exist.
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
    charged = through_attempt(account_id, &card_saved_decision(&1, today))
    {:ok, %{account: Repo.get!(BillingAccount, account_id), charged: charged}}
  end

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

  # The clock decision, on the locked row: charge only a card on file, never a held, comped,
  # cancelled or paused account, and never one holding an open attempt.
  defp clock_decision(account, today, final_pass?) do
    cond do
      not chargeable?(account) -> :none
      open_attempt?(account.id) -> :none
      Standing.paused?(Standing.of(account, facts(account), today)) -> :none
      is_nil(account.paid_through) -> trial_end_decision(account, today)
      today == Periods.next_renewal(account.paid_through) -> grace_day_decision(account, final_pass?)
      true -> :none
    end
  end

  defp chargeable?(account),
    do:
      Standing.card_on_file?(account) and is_nil(account.held_on) and not account.comped and is_nil(account.cancelled_on)

  # Never paid: the day after the trial, unless its first charge was already declined.
  defp trial_end_decision(%{trial_ends_on: %Date{} = ends_on} = account, today) do
    if Date.after?(today, ends_on) and not facts(account).first_charge_declined?,
      do: fresh_month(:trial_end, :clock, today),
      else: :none
  end

  defp trial_end_decision(_account, _today), do: :none

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

  # The card-saved decision, on the locked row with the card already stored.
  defp card_saved_decision(account, today) do
    if open_attempt?(account.id) or not Standing.card_on_file?(account) do
      :none
    else
      case Standing.of(account, facts(account), today) do
        {:past_due, _until} -> renewal(account, :card_saved)
        # A hold pauses until lifted, whatever the card; any other pause returns on a fresh month.
        {:paused, :hold} -> :none
        {:paused, _trial_ended_unpaid_or_cancelled} -> fresh_month(:returned, :card_saved, today)
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

    %BillingPaymentAttempt{
      billing_account_id: account.id,
      status: :pending,
      kind: charge.kind,
      source: charge.source,
      amount_cents: Billing.price_cents(),
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

  # "Relay · Apr 4 – May 3, 2026"
  defp description(attempt),
    do: "Relay · #{month_day(attempt.period_start)} – #{month_day(attempt.period_end)}, #{attempt.period_end.year}"

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

    account
    |> Ecto.Changeset.change(
      [paid_through: later(account.paid_through, attempt.period_end), billing_day: attempt.billing_day] ++ cancellation
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
