defmodule Relay.Billing.NotifierClockTest do
  @moduledoc "The billing clock's once-only emails (RE464): trial ending, card declined, plan paused."

  use Relay.DataCase, async: true

  import Swoosh.TestAssertions

  alias Relay.Billing
  alias Relay.Billing.Notifier
  alias Relay.Billing.Payments.Local
  alias Schemas.BillingAccount
  alias Schemas.BillingNotice
  alias Schemas.BillingPaymentAttempt

  @trial_ending "Your Relay trial ends in 3 days"
  @declined "We couldn't charge your card for Relay"
  @paused "Your Relay plan is paused"

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

  describe "trial ending" do
    test "timeline A: a no-card trial is told once, two days before it ends" do
      account = account("nocard@example.com", nil, %{trial_ends_on: ~D[2026-04-03]})

      assert %{notified: 0} = Billing.run_clock(~D[2026-03-31])
      assert_no_email_sent()

      assert %{notified: 1} = Billing.run_clock(~D[2026-04-01])

      assert_email_sent(fn email ->
        assert email.subject == @trial_ending
        assert email.to == [{"", "nocard@example.com"}]
        assert email.text_body =~ "April 3, 2026"
        assert email.text_body =~ "/account/billing"
      end)

      assert_no_email_sent()
      assert notices(account) == [{:trial_ending, ~D[2026-04-03]}]

      assert %{notified: 0} = Billing.run_clock(~D[2026-04-01])
      assert %{notified: 0} = Billing.run_clock(~D[2026-04-02])
      assert_no_email_sent()
      assert notices(account) == [{:trial_ending, ~D[2026-04-03]}]
    end

    test "a trial with a card on file is not told" do
      account("card@example.com", :visa_4242, %{trial_ends_on: ~D[2026-04-03]})
      nocard = account("nocard@example.com", nil, %{trial_ends_on: ~D[2026-04-03]})

      assert %{notified: 1} = Billing.run_clock(~D[2026-04-01])

      assert_email_sent(subject: @trial_ending, to: "nocard@example.com")
      assert_no_email_sent()
      assert notice_count() == 1
      assert notices(nocard) == [{:trial_ending, ~D[2026-04-03]}]
    end

    test "comped, held and cancelled trials get nothing, ending or ended" do
      account("comped@example.com", nil, %{trial_ends_on: ~D[2026-04-03], comped: true})
      account("held@example.com", nil, %{trial_ends_on: ~D[2026-04-03], held_on: ~D[2026-03-01]})

      account("cancelled@example.com", nil, %{
        trial_ends_on: ~D[2026-04-03],
        cancelled_on: ~D[2026-03-20],
        access_until: ~D[2026-04-03]
      })

      assert %{notified: 0} = Billing.run_clock(~D[2026-04-01])
      assert %{notified: 0} = Billing.run_clock(~D[2026-04-05])
      assert_no_email_sent()
      assert notice_count() == 0
    end
  end

  describe "paused" do
    test "timeline A: a trial that ends with no card is told once that it paused" do
      account = account("nocard@example.com", nil, %{trial_ends_on: ~D[2026-04-03]})

      assert %{notified: 1} = Billing.run_clock(~D[2026-04-04])
      assert %{notified: 0} = Billing.run_clock(~D[2026-04-04])

      assert_email_sent(fn email ->
        assert email.subject == @paused
        assert email.to == [{"", "nocard@example.com"}]
        assert email.text_body =~ "Nothing's been deleted."
        assert email.text_body =~ "/account/billing"
      end)

      assert_no_email_sent()
      assert notices(account) == [{:paused, ~D[2026-04-04]}]
    end

    test "a trial's declined first charge is told it was declined and paused, once" do
      account = account("declined@example.com", :visa_0341, %{trial_ends_on: ~D[2026-04-03]})

      assert %{notified: 2} = Billing.run_clock(~D[2026-04-04])

      assert_email_sent(fn email ->
        assert email.subject == @declined
        assert email.to == [{"", "declined@example.com"}]
        assert email.text_body =~ "($20.00)"
      end)

      assert_email_sent(subject: @paused, to: "declined@example.com")
      assert_no_email_sent()
      assert notices(account) == [{:card_declined, ~D[2026-04-04]}, {:paused, ~D[2026-04-04]}]

      assert %{notified: 0} = Billing.run_clock(~D[2026-04-05], final_pass?: true)
      assert_no_email_sent()
    end
  end

  describe "timeline C: a declined renewal" do
    setup do
      %{account: account("renewal@example.com", :visa_0341, %{paid_through: ~D[2026-08-11], billing_day: 12})}
    end

    test "is told once that the card was declined, retry included, and not yet paused", %{account: account} do
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

    test "is told once the day after that the plan paused", %{account: account} do
      Billing.run_clock(~D[2026-08-12])
      Billing.run_clock(~D[2026-08-12], final_pass?: true)
      assert_email_sent(subject: @declined)

      assert %{notified: 1} = Billing.run_clock(~D[2026-08-13])
      assert %{notified: 0} = Billing.run_clock(~D[2026-08-13])

      assert_email_sent(subject: @paused, to: "renewal@example.com")
      assert_no_email_sent()
      assert notices(account) == [{:card_declined, ~D[2026-08-12]}, {:paused, ~D[2026-08-12]}]
    end

    test "a later period notifies again", %{account: account} do
      Billing.run_clock(~D[2026-08-12])
      Billing.run_clock(~D[2026-08-12], final_pass?: true)
      Billing.run_clock(~D[2026-08-13])
      assert_email_sent(subject: @declined)
      assert_email_sent(subject: @paused)

      account |> Ecto.Changeset.change(paid_through: ~D[2026-09-11]) |> Repo.update!()

      assert %{notified: 1} = Billing.run_clock(~D[2026-09-12])
      assert_email_sent(subject: @declined, to: "renewal@example.com")
      assert %{notified: 1} = Billing.run_clock(~D[2026-09-13])
      assert_email_sent(subject: @paused, to: "renewal@example.com")
      assert_no_email_sent()

      assert notices(account) == [
               {:card_declined, ~D[2026-08-12]},
               {:paused, ~D[2026-08-12]},
               {:card_declined, ~D[2026-09-12]},
               {:paused, ~D[2026-09-12]}
             ]
    end
  end

  test "active, comped, held and cancelled-and-lapsed accounts get nothing" do
    lapsed = %{paid_through: ~D[2026-08-11], billing_day: 12}
    account("comped@example.com", nil, Map.put(lapsed, :comped, true))
    account("held@example.com", nil, Map.put(lapsed, :held_on, ~D[2026-08-01]))

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
    account("nocard@example.com", nil, %{trial_ends_on: ~D[2026-04-03]})

    assert Billing.run_clock(~D[2026-04-01]) == %{backfilled: 0, resolved: 0, charged: 0, notified: 0}
    assert_no_email_sent()
    assert notice_count() == 0
  end

  test "the unique index, not the code, refuses a second identical notice" do
    account = insert(:billing_account)
    insert(:billing_notice, billing_account: account, kind: :paused, period_key: ~D[2026-08-12])

    assert_raise Ecto.ConstraintError, ~r/billing_notices_once/, fn ->
      Repo.insert(%BillingNotice{billing_account_id: account.id, kind: :paused, period_key: ~D[2026-08-12]})
    end
  end

  test "the trial notice goes out two days ahead" do
    assert Notifier.trial_notice_days_before() == 2
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

    assert Billing.standing(account.user_id, ~D[2026-08-13]) == {:paused, :unpaid}
    assert log =~ "no mail provider configured"

    assert Repo.all(
             from n in BillingNotice,
               where: n.billing_account_id == ^account.id,
               order_by: n.id,
               select: {n.kind, n.period_key}
           ) == [{:card_declined, ~D[2026-08-12]}, {:paused, ~D[2026-08-12]}]
  end
end
