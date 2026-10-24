defmodule Relay.Billing.ClockTest do
  use Relay.DataCase, async: true

  alias Relay.Billing
  alias Relay.Billing.Clock
  alias Relay.Billing.Payments.Local
  alias Schemas.BillingAccount
  alias Schemas.BillingPaymentAttempt

  defmodule RaisingPayments do
    @moduledoc false
    @behaviour Relay.Billing.Payments

    @impl true
    defdelegate create_setup_checkout(customer_id, user, return_url), to: Local
    @impl true
    defdelegate fetch_setup(id), to: Local
    @impl true
    defdelegate find_payment(customer_id, payment_intent_id, attempt), to: Local

    @impl true
    def charge("cus_boom", _payment_method_id, _amount_cents, _key, _meta), do: raise("Stripe exploded")

    def charge(customer_id, payment_method_id, amount_cents, key, meta),
      do: Local.charge(customer_id, payment_method_id, amount_cents, key, meta)
  end

  setup do
    Process.put(:billing_enabled, true)
    :ok
  end

  defp card_fields(card) do
    card = Local.card(card)

    %{
      card_payment_method_id: card.payment_method_id,
      card_brand: card.brand,
      card_last4: card.last4,
      card_exp_month: card.exp_month,
      card_exp_year: card.exp_year
    }
  end

  defp account(card, attrs) do
    insert(:billing_account, card |> card_fields() |> Map.put(:stripe_customer_id, "cus_test") |> Map.merge(attrs))
  end

  defp attempts(account),
    do: Repo.all(from a in BillingPaymentAttempt, where: a.billing_account_id == ^account.id, order_by: a.id)

  defp reload(account), do: Repo.get!(BillingAccount, account.id)

  describe "a trial ending" do
    setup do
      %{account: account(:visa_4242, %{trial_ends_on: ~D[2026-04-03]})}
    end

    test "with a good card is charged a first month from the day after", %{account: account} do
      assert %{charged: 1, resolved: 0} = Billing.run_clock(~D[2026-04-04])

      assert [attempt] = attempts(account)

      assert %{
               status: :succeeded,
               kind: :trial_end,
               source: :clock,
               amount_cents: 2000,
               period_start: ~D[2026-04-04],
               period_end: ~D[2026-05-03],
               idempotency_key: idempotency_key
             } = attempt

      assert idempotency_key == "billing-#{account.id}-2026-04-04-1"
      assert attempt.receipt_url
      assert %{paid_through: ~D[2026-05-03], billing_day: 4} = reload(account)
    end

    test "is charged once however often the clock runs", %{account: account} do
      Billing.run_clock(~D[2026-04-04])
      assert %{charged: 0} = Billing.run_clock(~D[2026-04-04])
      assert [_one] = attempts(account)
    end

    test "is not charged before the trial is over", %{account: account} do
      assert %{charged: 0} = Billing.run_clock(~D[2026-04-03])
      assert attempts(account) == []
    end
  end

  test "a trial ending with no card is not charged and pauses" do
    account = insert(:billing_account, trial_ends_on: ~D[2026-04-03])

    assert %{charged: 0} = Billing.run_clock(~D[2026-04-04])
    assert attempts(account) == []
    assert Billing.standing(account.user_id, ~D[2026-04-04]) == {:paused, :trial_ended}
  end

  test "a trial's declined first charge is not retried and gets no grace" do
    account = account(:visa_0341, %{trial_ends_on: ~D[2026-04-03]})

    Billing.run_clock(~D[2026-04-04])
    Billing.run_clock(~D[2026-04-05], final_pass?: true)

    assert [%{status: :failed, decline_reason: "insufficient funds"}] = attempts(account)
    assert Billing.standing(account.user_id, ~D[2026-04-04]) == {:paused, :trial_ended}
  end

  test "a declined renewal is tried once, retried once on the final pass, then pauses" do
    account = account(:visa_0341, %{paid_through: ~D[2026-08-11], billing_day: 12})

    assert %{charged: 1} = Billing.run_clock(~D[2026-08-12])
    assert [first] = attempts(account)
    assert %{status: :failed, kind: :renewal, source: :clock} = first
    assert first.idempotency_key == "billing-#{account.id}-2026-08-12-1"
    assert reload(account).paid_through == ~D[2026-08-11]
    assert Billing.standing(account.user_id, ~D[2026-08-12]) == {:past_due, ~D[2026-08-12]}

    assert %{charged: 0} = Billing.run_clock(~D[2026-08-12])
    assert [_one] = attempts(account)

    assert %{charged: 1} = Billing.run_clock(~D[2026-08-12], final_pass?: true)
    assert [_first, second] = attempts(account)
    assert %{status: :failed, attempt_number: 2} = second
    assert second.idempotency_key == "billing-#{account.id}-2026-08-12-2"

    assert %{charged: 0} = Billing.run_clock(~D[2026-08-12], final_pass?: true)
    assert [_, _] = attempts(account)

    assert %{charged: 0} = Billing.run_clock(~D[2026-08-13], final_pass?: true)
    assert [_, _] = attempts(account)
    assert Billing.standing(account.user_id, ~D[2026-08-13]) == {:paused, :unpaid}
  end

  test "a renewal on the 31st's short-month day keeps the 31st" do
    account = account(:visa_4242, %{paid_through: ~D[2026-02-27], billing_day: 31})

    Billing.run_clock(~D[2026-02-28])

    assert [%{status: :succeeded, kind: :renewal, period_start: ~D[2026-02-28], period_end: ~D[2026-03-30]}] =
             attempts(account)

    assert %{paid_through: ~D[2026-03-30], billing_day: 31} = reload(account)
  end

  test "an unanswered charge is unknown, then resolved with Stripe — never resent" do
    account = account(:timeout, %{paid_through: ~D[2026-08-11], billing_day: 12})

    assert %{charged: 1} = Billing.run_clock(~D[2026-08-12])
    assert [%{status: :unknown, error: error}] = attempts(account)
    assert is_binary(error)
    assert reload(account).paid_through == ~D[2026-08-11]

    assert %{resolved: 1, charged: 0} = Billing.run_clock(~D[2026-08-12])
    assert [%{status: :succeeded, stripe_payment_intent_id: "pi_local_attempt-" <> _id}] = attempts(account)
    assert reload(account).paid_through == ~D[2026-09-11]
  end

  test "an overdue pending attempt is resolved; a recent one is left alone" do
    now = ~U[2026-08-12 12:00:00Z]
    overdue_account = account(:visa_4242, %{trial_ends_on: ~D[2026-09-01]})
    recent_account = account(:visa_4242, %{trial_ends_on: ~D[2026-09-01]})

    overdue =
      insert(:billing_payment_attempt,
        billing_account: overdue_account,
        status: :pending,
        stripe_customer_id: "cus_test",
        stripe_payment_method_id: "pm_local_4242",
        period_start: ~D[2026-08-12],
        period_end: ~D[2026-09-11],
        inserted_at: DateTime.add(now, -11, :minute)
      )

    recent =
      insert(:billing_payment_attempt,
        billing_account: recent_account,
        status: :pending,
        inserted_at: DateTime.add(now, -5, :minute)
      )

    assert %{resolved: 1} = Billing.run_clock(~D[2026-08-12], now: now)
    assert Repo.get!(BillingPaymentAttempt, overdue.id).status == :succeeded
    assert reload(overdue_account).paid_through == ~D[2026-09-11]
    assert Repo.get!(BillingPaymentAttempt, recent.id).status == :pending
  end

  test "the launch backfill starts a trial for every user without one" do
    no_account = insert(:user)
    no_trial = insert(:billing_account, trial_ends_on: nil)
    has_trial = insert(:billing_account, trial_ends_on: ~D[2026-11-20])

    assert %{backfilled: 2} = Billing.run_clock(~D[2026-11-01])

    assert Billing.get_account(no_account).trial_ends_on == ~D[2026-12-01]
    assert reload(no_trial).trial_ends_on == ~D[2026-12-01]
    assert reload(has_trial).trial_ends_on == ~D[2026-11-20]
  end

  test "comped, held and cancelled accounts are never charged" do
    due = %{paid_through: ~D[2026-08-11], billing_day: 12}
    comped = account(:visa_4242, Map.put(due, :comped, true))
    held = account(:visa_4242, Map.merge(due, %{held_on: ~D[2026-08-01], hold_reason: "fraud check"}))
    cancelled = account(:visa_4242, Map.merge(due, %{cancelled_on: ~D[2026-08-01], access_until: ~D[2026-08-11]}))

    assert %{charged: 0} = Billing.run_clock(~D[2026-08-12])
    assert attempts(comped) == [] and attempts(held) == [] and attempts(cancelled) == []
  end

  test "with billing disabled the clock does nothing" do
    Process.put(:billing_enabled, false)
    account = account(:visa_4242, %{trial_ends_on: ~D[2026-04-03]})
    insert(:user)

    assert Billing.run_clock(~D[2026-04-04]) == %{backfilled: 0, resolved: 0, charged: 0}
    assert attempts(account) == []
  end

  test "one account blowing up never stops the rest, and is unknown rather than failed" do
    Process.put(:billing_payments, RaisingPayments)
    due = %{paid_through: ~D[2026-08-11], billing_day: 12}
    boom = account(:visa_4242, Map.put(due, :stripe_customer_id, "cus_boom"))
    fine = account(:visa_4242, Map.put(due, :stripe_customer_id, "cus_ok"))

    Billing.run_clock(~D[2026-08-12])

    assert [%{status: :unknown}] = attempts(boom)
    assert [%{status: :succeeded}] = attempts(fine)
  end

  describe "Relay.Billing.Clock" do
    test "lock_key/0 is a fixed integer and final_pass_hour/0 is 23" do
      assert is_integer(Clock.lock_key())
      assert Clock.final_pass_hour() == 23
    end

    test "disabled, it schedules no tick" do
      pid = start_supervised!({Clock, enabled: false, name: :billing_clock_test})
      assert %{timer: nil} = :sys.get_state(pid)
    end

    test "enabled, it schedules its first tick" do
      pid = start_supervised!({Clock, enabled: true, name: :billing_clock_enabled_test})
      assert %{timer: timer} = :sys.get_state(pid)
      assert is_reference(timer)
    end

    test "a tick runs the clock for today" do
      account = account(:visa_4242, %{trial_ends_on: Date.add(Date.utc_today(), -1)})
      pid = allow!(start_supervised!({Clock, enabled: false, name: :billing_clock_test}))

      send(pid, :tick)
      _ = :sys.get_state(pid)

      assert [%{status: :succeeded}] = attempts(account)
    end

    test "a tick while another node holds the lock does nothing" do
      account = account(:visa_4242, %{trial_ends_on: Date.add(Date.utc_today(), -1)})
      other_node = start_supervised!({Postgrex, Keyword.drop(Repo.config(), [:pool, :pool_size])})
      Postgrex.query!(other_node, "SELECT pg_advisory_lock($1)", [Clock.lock_key()])
      pid = allow!(start_supervised!({Clock, enabled: false, name: :billing_clock_test}))

      send(pid, :tick)
      _ = :sys.get_state(pid)

      assert attempts(account) == []
    end
  end
end
