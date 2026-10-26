defmodule Hamaca.Billing.ClockTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Billing
  alias Hamaca.Billing.Clock
  alias Hamaca.Billing.Payments.Local
  alias Schemas.BillingAccount
  alias Schemas.BillingPaymentAttempt

  defmodule RaisingPayments do
    @moduledoc false
    @behaviour Hamaca.Billing.Payments

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

  describe "a never-paid (Free) account" do
    # A trial date left over from before Free (RE469) is long past: it must not trigger a charge.
    test "with a card on file is never charged by the clock, on any day or pass" do
      account = account(:visa_4242, %{trial_ends_on: ~D[2026-03-01]})

      for today <- [~D[2026-04-04], ~D[2026-05-04], ~D[2026-10-25]] do
        assert %{charged: 0} = Billing.run_clock(today, final_pass?: true)
      end

      assert attempts(account) == []
      assert Billing.standing(account.user_id, ~D[2026-10-25]) == :free
    end

    test "holding a 100% code is never charged by the clock" do
      insert(:promo_code, code: "FRIENDS", percent_off: 100, months: 2)
      account = insert(:billing_account, trial_ends_on: ~D[2026-03-01])
      {:ok, account} = Billing.redeem_code(account.user_id, "FRIENDS", ~D[2026-03-10])

      for today <- [~D[2026-04-04], ~D[2026-10-25]] do
        assert %{charged: 0} = Billing.run_clock(today, final_pass?: true)
      end

      assert attempts(account) == []
    end
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
    assert Billing.standing(account.user_id, ~D[2026-08-13]) == :free
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
    overdue_account = account(:visa_4242, %{})
    recent_account = account(:visa_4242, %{})

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

  test "the clock answers resolved, charged and notified only, and opens no account" do
    user = insert(:user)

    result = Billing.run_clock(~D[2026-11-01])

    assert result |> Map.keys() |> Enum.sort() == [:charged, :notified, :resolved]
    assert Billing.get_account(user) == nil
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
    account = account(:visa_4242, %{paid_through: ~D[2026-04-03], billing_day: 4})
    insert(:user)

    assert Billing.run_clock(~D[2026-04-04]) == %{resolved: 0, charged: 0, notified: 0}
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

  defp renewal_due_today do
    today = Date.utc_today()
    account(:visa_4242, %{paid_through: Date.add(today, -1), billing_day: today.day})
  end

  describe "Hamaca.Billing.Clock" do
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
      account = renewal_due_today()
      pid = allow!(start_supervised!({Clock, enabled: false, name: :billing_clock_test}))

      send(pid, :tick)
      _ = :sys.get_state(pid)

      assert [%{status: :succeeded}] = attempts(account)
    end

    test "a tick while another node holds the lock does nothing" do
      account = renewal_due_today()
      other_node = start_supervised!({Postgrex, Keyword.drop(Repo.config(), [:pool, :pool_size])})
      Postgrex.query!(other_node, "SELECT pg_advisory_lock($1)", [Clock.lock_key()])
      pid = allow!(start_supervised!({Clock, enabled: false, name: :billing_clock_test}))

      send(pid, :tick)
      _ = :sys.get_state(pid)

      assert attempts(account) == []
    end
  end
end
