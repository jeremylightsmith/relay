defmodule Relay.Billing.ChargingTest do
  use Relay.DataCase, async: true

  alias Relay.Billing
  alias Relay.Billing.Charging
  alias Relay.Billing.Payments.Local
  alias Relay.Billing.Periods
  alias Schemas.BillingAccount
  alias Schemas.BillingPaymentAttempt

  @today ~D[2026-06-10]

  setup do
    Process.put(:billing_enabled, true)
    :ok
  end

  defp account_for(user, attrs), do: insert(:billing_account, Map.merge(%{user: user}, attrs))

  defp attempts(account),
    do: Repo.all(from a in BillingPaymentAttempt, where: a.billing_account_id == ^account.id, order_by: a.id)

  defp reload(account), do: Repo.get!(BillingAccount, account.id)

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

  test "pending_overdue_minutes/0 is 10" do
    assert Charging.pending_overdue_minutes() == 10
  end

  describe "complete_setup/3" do
    test "a trial user saves the card, is not charged, and the change is broadcast" do
      user = insert(:user)
      account = account_for(user, %{trial_ends_on: Date.add(@today, 10)})
      :ok = Billing.subscribe(user.id)

      assert {:ok, %{account: saved, charged: :none}} = Billing.complete_setup("local_4242_#{user.id}", user.id, @today)

      assert %BillingAccount{
               card_brand: "visa",
               card_last4: "4242",
               card_exp_month: 8,
               card_exp_year: 2028,
               card_payment_method_id: "pm_local_4242"
             } = saved

      assert saved.stripe_customer_id == "cus_local_#{user.id}"
      assert reload(account).card_last4 == "4242"
      assert attempts(account) == []
      user_id = user.id
      assert_receive {:billing_changed, ^user_id}
    end

    test "a paused (unpaid) account pays a fresh month from today" do
      user = insert(:user)
      account = account_for(user, %{paid_through: Date.add(@today, -20), billing_day: 3})
      assert Billing.standing(user, @today) == {:paused, :unpaid}

      assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, @today)

      {_start, last} = Periods.period(@today, @today.day)
      assert [%{status: :succeeded, kind: :returned, source: :card_saved, period_start: @today}] = attempts(account)
      assert %{paid_through: ^last, billing_day: 10} = reload(account)
      assert Billing.standing(user, @today) == :active
    end

    test "a past-due account renews the period after paid_through, keeping its billing day" do
      user = insert(:user)
      account = account_for(user, %{paid_through: Date.add(@today, -1), billing_day: @today.day})

      assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, @today)

      assert [%{status: :succeeded, kind: :renewal, source: :card_saved, period_start: @today, billing_day: 10}] =
               attempts(account)

      assert reload(account).paid_through == ~D[2026-07-09]
    end

    test "a paused (cancelled) account pays and its cancellation is cleared" do
      user = insert(:user)

      account =
        account_for(user, %{
          paid_through: ~D[2026-05-31],
          billing_day: 1,
          cancelled_on: ~D[2026-05-15],
          access_until: ~D[2026-05-31]
        })

      assert Billing.standing(user, @today) == {:paused, :cancelled}

      assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, @today)
      assert %{cancelled_on: nil, access_until: nil} = reload(account)
      assert Billing.standing(user, @today) == :active
    end

    test "a declined card leaves a paused account paused" do
      user = insert(:user)
      account = account_for(user, %{paid_through: Date.add(@today, -20), billing_day: 3})

      assert {:ok, %{charged: :declined}} = Billing.complete_setup("local_0341_#{user.id}", user.id, @today)
      assert [%{status: :failed, decline_reason: "insufficient funds"}] = attempts(account)
      assert Billing.standing(user, @today) == {:paused, :unpaid}
    end

    test "another user's setup is refused and nothing changes" do
      user_a = insert(:user)
      user_b = insert(:user)
      account_a = account_for(user_a, %{paid_through: Date.add(@today, -20), billing_day: 3})
      account_b = account_for(user_b, %{paid_through: Date.add(@today, -20), billing_day: 3})

      assert Billing.complete_setup("local_4242_#{user_b.id}", user_a.id, @today) == {:error, :wrong_user}
      assert %{card_last4: nil, stripe_customer_id: nil} = reload(account_a)
      assert %{card_last4: nil, stripe_customer_id: nil} = reload(account_b)
      assert attempts(account_a) == [] and attempts(account_b) == []
    end

    test "the same session completing twice (return URL + webhook) charges once" do
      user = insert(:user)
      account = account_for(user, %{paid_through: Date.add(@today, -20), billing_day: 3})

      assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, @today)
      assert {:ok, %{charged: :none}} = Billing.complete_setup("local_4242_#{user.id}", nil, @today)

      assert [%{status: :succeeded}] = attempts(account)
    end

    test "a held or comped account saves the card but is not charged" do
      held_user = insert(:user)
      held = account_for(held_user, %{paid_through: Date.add(@today, -20), billing_day: 3, held_on: ~D[2026-06-01]})
      comped_user = insert(:user)
      comped = account_for(comped_user, %{comped: true})

      assert {:ok, %{charged: :none}} = Billing.complete_setup("local_4242_#{held_user.id}", held_user.id, @today)
      assert {:ok, %{charged: :none}} = Billing.complete_setup("local_4242_#{comped_user.id}", comped_user.id, @today)
      assert attempts(held) == [] and attempts(comped) == []
      assert Billing.standing(held_user, @today) == {:paused, :hold}
    end

    test "an open attempt blocks a card-saved charge" do
      user = insert(:user)
      account = account_for(user, %{paid_through: Date.add(@today, -20), billing_day: 3})
      insert(:billing_payment_attempt, billing_account: account, status: :unknown)

      assert {:ok, %{charged: :none}} = Billing.complete_setup("local_4242_#{user.id}", user.id, @today)
      assert [%{status: :unknown}] = attempts(account)
    end

    test "an unknown setup id is not found" do
      user = insert(:user)
      assert Billing.complete_setup("nope", user.id, @today) == {:error, :not_found}
    end

    test "a user with no account yet gets one holding the card" do
      user = insert(:user)

      assert {:ok, %{account: %{card_last4: "4242"}, charged: :none}} =
               Billing.complete_setup("local_4242_#{user.id}", nil, @today)
    end
  end

  describe "handle_webhook_event/1" do
    test "a setup-mode checkout.session.completed saves the card" do
      user = insert(:user)
      account_for(user, %{trial_ends_on: Date.add(Date.utc_today(), 10)})

      event = %{
        "type" => "checkout.session.completed",
        "data" => %{"object" => %{"id" => "local_4242_#{user.id}", "mode" => "setup"}}
      }

      assert Billing.handle_webhook_event(event) == :ok
      assert Billing.get_account(user).card_last4 == "4242"
    end

    test "setup_intent.succeeded saves the card" do
      user = insert(:user)
      account_for(user, %{trial_ends_on: Date.add(Date.utc_today(), 10)})
      event = %{"type" => "setup_intent.succeeded", "data" => %{"object" => %{"id" => "local_0341_#{user.id}"}}}

      assert Billing.handle_webhook_event(event) == :ok
      assert Billing.get_account(user).card_last4 == "0341"
    end

    test "a payment-mode session or any other event is left alone" do
      user = insert(:user)
      account_for(user, %{trial_ends_on: Date.add(Date.utc_today(), 10)})
      object = %{"id" => "local_4242_#{user.id}", "mode" => "payment"}

      assert Billing.handle_webhook_event(%{"type" => "checkout.session.completed", "data" => %{"object" => object}}) ==
               :ok

      assert Billing.handle_webhook_event(%{"type" => "invoice.paid", "data" => %{"object" => object}}) == :ok
      assert Billing.handle_webhook_event(%{}) == :ok
      assert Billing.get_account(user).card_last4 == nil
    end
  end

  describe "setup_checkout_url/2" do
    test "answers the checkout URL and stores the new customer" do
      user = insert(:user)

      assert {:ok, url} = Billing.setup_checkout_url(user, "https://relay.test/account/billing")
      assert %URI{host: "relay.test", path: "/dev/billing-checkout", query: query} = URI.parse(url)

      assert URI.decode_query(query) == %{
               "succeed" => "/account/billing?setup=local_4242_#{user.id}",
               "decline" => "/account/billing?setup=local_0341_#{user.id}"
             }

      assert Billing.get_account(user).stripe_customer_id == "cus_local_#{user.id}"
    end

    test "keeps a customer the account already has" do
      user = insert(:user)
      account_for(user, %{stripe_customer_id: "cus_existing"})

      assert {:ok, _url} = Billing.setup_checkout_url(user, "https://relay.test/account/billing")
      assert Billing.get_account(user).stripe_customer_id == "cus_existing"
    end
  end

  describe "summary/2" do
    test "an active account: its payments, card, renewal and cancellability" do
      user = insert(:user)

      account =
        account_for(user, Map.merge(card_fields(:visa_4242), %{paid_through: ~D[2026-05-03], billing_day: 4}))

      paid =
        insert(:billing_payment_attempt,
          billing_account: account,
          status: :succeeded,
          kind: :trial_end,
          period_start: ~D[2026-04-04],
          period_end: ~D[2026-05-03],
          amount_cents: 2000,
          resolved_at: ~U[2026-04-04 00:05:00Z],
          receipt_url: "https://pay.stripe.com/receipts/local/k"
        )

      insert(:billing_payment_attempt, billing_account: account, status: :failed, resolved_at: ~U[2026-04-03 00:05:00Z])

      summary = Billing.summary(user, ~D[2026-04-20])

      assert summary.payments == [
               %{
                 id: paid.id,
                 paid_on: ~D[2026-04-04],
                 period_start: ~D[2026-04-04],
                 period_end: ~D[2026-05-03],
                 amount_cents: 2000,
                 receipt_url: "https://pay.stripe.com/receipts/local/k"
               }
             ]

      assert summary.card == %{brand_label: "Visa", last4: "4242", exp_month: 8, exp_year: 2028}
      assert summary.standing == :active
      assert summary.paid_through == ~D[2026-05-03]
      assert summary.renews_on == ~D[2026-05-04]
      assert summary.cancellable? == true
      assert summary.resumable? == false
      assert summary.trial_days_left == nil
      assert summary.first_charge_on == nil
    end

    test "payments are newest first" do
      user = insert(:user)
      account = account_for(user, %{paid_through: ~D[2026-06-03], billing_day: 4})

      a =
        insert(:billing_payment_attempt,
          billing_account: account,
          status: :succeeded,
          resolved_at: ~U[2026-04-04 00:00:00Z]
        )

      b =
        insert(:billing_payment_attempt,
          billing_account: account,
          status: :succeeded,
          resolved_at: ~U[2026-05-04 00:00:00Z]
        )

      assert Enum.map(Billing.summary(user, ~D[2026-05-10]).payments, & &1.id) == [b.id, a.id]
    end

    test "a trial: days left, first charge and the price" do
      user = insert(:user)
      account_for(user, %{trial_ends_on: ~D[2026-04-03]})

      summary = Billing.summary(user, ~D[2026-03-23])

      assert summary.standing == :trial
      assert summary.trial_ends_on == ~D[2026-04-03]
      assert summary.trial_days_left == 11
      assert summary.first_charge_on == ~D[2026-04-04]
      assert summary.amount_cents == 2000
      assert summary.card == nil
      assert summary.payments == []
      assert summary.renews_on == nil
    end

    test "a trial with no code previews the full price and no promo" do
      user = insert(:user)
      account_for(user, %{trial_ends_on: ~D[2026-04-03]})

      summary = Billing.summary(user, ~D[2026-03-23])

      assert summary.promo == nil
      assert summary.amount_cents == 2000
      assert summary.full_price_cents == 2000
    end

    test "a trial holding a code previews the discounted first charge and when full price starts" do
      user = insert(:user)
      account_for(user, %{trial_ends_on: ~D[2026-04-03]})
      insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)
      {:ok, _account} = Billing.redeem_code(user, "RELAYCONF", ~D[2026-03-20])

      summary = Billing.summary(user, ~D[2026-03-23])

      assert summary.amount_cents == 1000
      assert summary.full_price_cents == 2000
      assert summary.first_charge_on == ~D[2026-04-04]
      assert summary.promo == %{code: "RELAYCONF", percent_off: 50, months_left: 3, full_price_from: ~D[2026-07-04]}
    end

    test "an active account holding a code previews its discounted renewal" do
      user = insert(:user)
      promo_code = insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)

      account_for(user, %{
        paid_through: ~D[2026-05-03],
        billing_day: 4,
        promo_code_id: promo_code.id,
        promo_months_left: 2
      })

      summary = Billing.summary(user, ~D[2026-04-20])

      assert summary.renews_on == ~D[2026-05-04]
      assert summary.amount_cents == 1000
      assert summary.promo.full_price_from == ~D[2026-07-04]
    end

    test "an active account whose code is used up previews the full price" do
      user = insert(:user)
      promo_code = insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)

      account_for(user, %{
        paid_through: ~D[2026-05-03],
        billing_day: 4,
        promo_code_id: promo_code.id,
        promo_months_left: 0
      })

      summary = Billing.summary(user, ~D[2026-04-20])

      assert summary.amount_cents == 2000
      assert summary.promo.months_left == 0
      assert summary.promo.full_price_from == nil
    end

    test "a cancelled plan does not renew and is resumable" do
      user = insert(:user)

      account_for(user, %{
        paid_through: ~D[2026-05-03],
        billing_day: 4,
        cancelled_on: ~D[2026-04-10],
        access_until: ~D[2026-05-03]
      })

      summary = Billing.summary(user, ~D[2026-04-20])

      assert summary.standing == {:cancelled, ~D[2026-05-03]}
      assert summary.renews_on == nil
      assert summary.resumable? == true
      assert summary.cancellable? == false
    end

    test "a user with no account is a trial with nothing yet" do
      summary = Billing.summary(insert(:user), ~D[2026-03-23])

      assert %{standing: :trial, trial_ends_on: nil, trial_days_left: nil, first_charge_on: nil} = summary
      assert %{card: nil, payments: []} = summary
    end
  end

  test "brand_label/1 names the card brands" do
    assert Billing.brand_label("visa") == "Visa"
    assert Billing.brand_label("mastercard") == "Mastercard"
    assert Billing.brand_label("amex") == "Amex"
    assert Billing.brand_label("discover") == "Discover"
    assert Billing.brand_label("jcb") == "Jcb"
    assert Billing.brand_label(nil) == "Card"
  end
end
