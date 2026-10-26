defmodule Relay.Billing.NotifierClockTest do
  @moduledoc "The billing clock's once-only emails (RE464, RE469): card declined, dropped to Free."

  use Relay.DataCase, async: true

  import Swoosh.TestAssertions

  alias Relay.Billing
  alias Relay.Billing.Notifier
  alias Relay.Billing.Payments.Local
  alias Schemas.BillingAccount
  alias Schemas.BillingNotice
  alias Schemas.BillingPaymentAttempt

  @declined "We couldn't charge your card for Hamaca"
  @dropped "Your Hamaca plan is now Free"

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

  # An account owned by `email`, with `card`'s fields (or none) and `attrs`.
  defp account(email, card, attrs) do
    fields = if card, do: card |> card_fields() |> Map.put(:stripe_customer_id, "cus_test"), else: %{}
    insert(:billing_account, fields |> Map.merge(attrs) |> Map.put(:user, build(:user, email: email)))
  end

  defp attempts(account),
    do: Repo.all(from a in BillingPaymentAttempt, where: a.billing_account_id == ^account.id, order_by: a.id)

  defp notices(account),
    do:
      Repo.all(
        from n in BillingNotice,
          where: n.billing_account_id == ^account.id,
          order_by: n.id,
          select: {n.kind, n.period_key}
      )

  defp notice_count, do: Repo.aggregate(BillingNotice, :count)

  describe "dropped to Free" do
    test "a paid account past its grace is told once, keyed on its first Free day" do
      today = ~D[2026-10-25]
      paid_through = Date.add(today, -2)
      account = account("lapsed@example.com", nil, %{paid_through: paid_through, billing_day: 24})

      assert %{notified: 1} = Billing.run_clock(today)
      assert %{notified: 0} = Billing.run_clock(today)

      assert_email_sent(fn email ->
        assert email.subject == @dropped
        assert email.to == [{"", "lapsed@example.com"}]

        assert email.text_body =~
                 "We couldn't renew your Hamaca plan, so you're on Free now. Free includes one editable board; " <>
                   "your other boards are read-only and nothing has been deleted. Upgrade any time to unlock them all: " <>
                   Notifier.billing_url()
      end)

      assert_no_email_sent()
      assert notices(account) == [{:dropped_to_free, Date.add(paid_through, 2)}]
    end

    test "a never-paid account of any age is never noticed, whatever its old trial date" do
      account("new@example.com", nil, %{})
      account("old@example.com", nil, %{trial_ends_on: ~D[2026-03-01]})
      account("ending@example.com", nil, %{trial_ends_on: ~D[2026-04-03]})
      account("card@example.com", :visa_4242, %{trial_ends_on: ~D[2026-04-03]})

      for today <- [~D[2026-04-01], ~D[2026-04-04], ~D[2026-10-25]] do
        assert %{notified: 0} = Billing.run_clock(today, final_pass?: true)
      end

      assert_no_email_sent()
      assert notice_count() == 0
    end

    test "the notice kinds are the declined card and the drop to Free" do
      assert BillingNotice.kinds() == [:card_declined, :dropped_to_free]
    end
  end

  describe "timeline C: a declined renewal" do
    setup do
      %{account: account("renewal@example.com", :visa_0341, %{paid_through: ~D[2026-08-11], billing_day: 12})}
    end

    test "is told once that the card was declined, retry included, and not yet on Free", %{account: account} do
      assert %{notified: 1} = Billing.run_clock(~D[2026-08-12])
      assert_email_sent(subject: @declined, to: "renewal@example.com")
      assert_no_email_sent()
      assert notices(account) == [{:card_declined, ~D[2026-08-12]}]
      assert Billing.standing(account.user_id, ~D[2026-08-12]) == {:past_due, ~D[2026-08-12]}

      assert %{notified: 0} = Billing.run_clock(~D[2026-08-12])
      assert %{charged: 1, notified: 0} = Billing.run_clock(~D[2026-08-12], final_pass?: true)
      assert [%{status: :failed}, %{status: :failed, attempt_number: 2}] = attempts(account)
      assert_no_email_sent()
      assert notices(account) == [{:card_declined, ~D[2026-08-12]}]
    end

    test "is told once, the day after the grace, that the plan is now Free", %{account: account} do
      Billing.run_clock(~D[2026-08-12])
      Billing.run_clock(~D[2026-08-12], final_pass?: true)
      assert_email_sent(subject: @declined)

      assert %{notified: 1} = Billing.run_clock(~D[2026-08-13])
      assert %{notified: 0} = Billing.run_clock(~D[2026-08-13])

      assert_email_sent(subject: @dropped, to: "renewal@example.com")
      assert_no_email_sent()
      assert notices(account) == [{:card_declined, ~D[2026-08-12]}, {:dropped_to_free, ~D[2026-08-13]}]
      assert Billing.standing(account.user_id, ~D[2026-08-13]) == :free
    end

    test "a later period notifies again", %{account: account} do
      Billing.run_clock(~D[2026-08-12])
      Billing.run_clock(~D[2026-08-12], final_pass?: true)
      Billing.run_clock(~D[2026-08-13])
      assert_email_sent(subject: @declined)
      assert_email_sent(subject: @dropped)

      account |> Ecto.Changeset.change(paid_through: ~D[2026-09-11]) |> Repo.update!()

      assert %{notified: 1} = Billing.run_clock(~D[2026-09-12])
      assert_email_sent(subject: @declined, to: "renewal@example.com")
      assert %{notified: 1} = Billing.run_clock(~D[2026-09-13])
      assert_email_sent(subject: @dropped, to: "renewal@example.com")
      assert_no_email_sent()

      assert notices(account) == [
               {:card_declined, ~D[2026-08-12]},
               {:dropped_to_free, ~D[2026-08-13]},
               {:card_declined, ~D[2026-09-12]},
               {:dropped_to_free, ~D[2026-09-13]}
             ]
    end
  end

  test "active, comped, held, never-paid and cancelled-and-lapsed accounts get nothing" do
    lapsed = %{paid_through: ~D[2026-08-11], billing_day: 12}
    account("comped@example.com", nil, Map.put(lapsed, :comped, true))
    account("held@example.com", nil, Map.put(lapsed, :held_on, ~D[2026-08-01]))
    account("never-paid@example.com", nil, %{})

    account(
      "cancelled@example.com",
      nil,
      Map.merge(lapsed, %{cancelled_on: ~D[2026-08-01], access_until: ~D[2026-08-11]})
    )

    active = account("active@example.com", :visa_4242, lapsed)

    assert %{notified: 0} = Billing.run_clock(~D[2026-08-12])
    assert %{notified: 0} = Billing.run_clock(~D[2026-08-14])
    assert_no_email_sent()
    assert notice_count() == 0
    assert Repo.get!(BillingAccount, active.id).paid_through == ~D[2026-09-11]
  end

  test "a decline while saving a card sends nothing" do
    account = account("saved@example.com", nil, %{paid_through: ~D[2026-08-11], billing_day: 12})

    insert(:billing_payment_attempt,
      billing_account: account,
      status: :failed,
      source: :card_saved,
      period_start: ~D[2026-08-12]
    )

    assert Notifier.notify_due(~D[2026-08-12]) == 0
    refute_email_sent(subject: @declined)
    assert notices(account) == []
  end

  test "with billing disabled nothing is noticed" do
    Process.put(:billing_enabled, false)
    account("lapsed@example.com", nil, %{paid_through: ~D[2026-03-29], billing_day: 30})

    assert Billing.run_clock(~D[2026-04-01]) == %{resolved: 0, charged: 0, notified: 0}
    assert_no_email_sent()
    assert notice_count() == 0
  end

  test "the unique index, not the code, refuses a second identical notice" do
    account = insert(:billing_account)
    insert(:billing_notice, billing_account: account, kind: :dropped_to_free, period_key: ~D[2026-08-12])

    assert_raise Ecto.ConstraintError, ~r/billing_notices_once/, fn ->
      Repo.insert(%BillingNotice{billing_account_id: account.id, kind: :dropped_to_free, period_key: ~D[2026-08-12]})
    end
  end
end

defmodule Relay.Billing.NotifierClockMailOffTest do
  # `async: false`: the info line "no mail provider configured" only reaches `capture_log` under a
  # VM-wide module level (see `Relay.Billing.NotifierDisabledLogTest`), removed on exit.
  use Relay.DataCase, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias Relay.Billing
  alias Relay.Billing.Notifier
  alias Relay.Billing.Payments.Local
  alias Schemas.BillingNotice
  alias Schemas.BillingPaymentAttempt

  setup do
    Process.put(:billing_enabled, true)
    Logger.put_module_level(Notifier, :info)
    on_exit(fn -> Logger.delete_module_level(Notifier) end)
  end

  test "with no mail provider, notices are recorded, nothing is sent, and charging is unaffected" do
    Process.put(:mail_enabled, false)
    card = Local.card(:visa_0341)

    account =
      insert(:billing_account,
        user: build(:user, email: "renewal@example.com"),
        stripe_customer_id: "cus_test",
        card_payment_method_id: card.payment_method_id,
        card_brand: card.brand,
        card_last4: card.last4,
        card_exp_month: card.exp_month,
        card_exp_year: card.exp_year,
        paid_through: ~D[2026-08-11],
        billing_day: 12
      )

    log =
      capture_log([level: :info], fn ->
        Billing.run_clock(~D[2026-08-12])
        Billing.run_clock(~D[2026-08-12], final_pass?: true)
        Billing.run_clock(~D[2026-08-13])
      end)

    assert_no_email_sent()

    assert [%{status: :failed}, %{status: :failed}] =
             Repo.all(from a in BillingPaymentAttempt, where: a.billing_account_id == ^account.id, order_by: a.id)

    assert Billing.standing(account.user_id, ~D[2026-08-13]) == :free
    assert log =~ "no mail provider configured"

    assert Repo.all(
             from n in BillingNotice,
               where: n.billing_account_id == ^account.id,
               order_by: n.id,
               select: {n.kind, n.period_key}
           ) == [{:card_declined, ~D[2026-08-12]}, {:dropped_to_free, ~D[2026-08-13]}]
  end
end
