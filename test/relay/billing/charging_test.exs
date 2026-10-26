defmodule Relay.Billing.ChargingTest do
  use Relay.DataCase, async: true

  alias Relay.Billing
  alias Relay.Billing.Charging
  alias Relay.Billing.Payments
  alias Relay.Billing.Payments.Local
  alias Relay.Billing.Periods
  alias Schemas.BillingAccount
  alias Schemas.BillingPaymentAttempt

  @today ~D[2026-06-10]

  defmodule RaisingPayments do
    @moduledoc false
    @behaviour Payments

    @impl true
    defdelegate create_setup_checkout(customer_id, user, return_url), to: Local
    @impl true
    defdelegate fetch_setup(id), to: Local
    @impl true
    defdelegate find_payment(customer_id, payment_intent_id, attempt), to: Local

    @impl true
    def charge(_customer_id, _payment_method_id, _amount_cents, _key, _meta), do: raise("charge/5 must not be called")
  end

  # Charges through `Local`, and tells the charging process what `meta` it was handed.
  defmodule CapturingPayments do
    @moduledoc false
    @behaviour Payments

    @impl true
    defdelegate create_setup_checkout(customer_id, user, return_url), to: Local
    @impl true
    defdelegate fetch_setup(id), to: Local
    @impl true
    defdelegate find_payment(customer_id, payment_intent_id, attempt), to: Local

    @impl true
    def charge(customer_id, payment_method_id, amount_cents, key, meta) do
      send(self(), {:charged_meta, meta})
      Local.charge(customer_id, payment_method_id, amount_cents, key, meta)
    end
  end

  setup do
    Process.put(:billing_enabled, true)
    :ok
  end

  # RE477 scenario 10
  test "the charge description names Hamaca and the period" do
    Process.put(:billing_payments, CapturingPayments)
    user = insert(:user)

    assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", nil, ~D[2026-10-01])

    assert_received {:charged_meta, %{description: "Hamaca · Oct 1 – Oct 31, 2026"}}
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
    test "a Free never-paid user saves the card and pays a first month from today, broadcast" do
      user = insert(:user)
      account = account_for(user, %{})
      assert Billing.standing(user, @today) == :free
      :ok = Billing.subscribe(user.id)

      assert {:ok, %{account: saved, charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, @today)

      assert %BillingAccount{
               card_brand: "visa",
               card_last4: "4242",
               card_exp_month: 8,
               card_exp_year: 2028,
               card_payment_method_id: "pm_local_4242"
             } = saved

      assert saved.stripe_customer_id == "cus_local_#{user.id}"
      {@today, last} = Periods.period(@today, @today.day)
      assert %{card_last4: "4242", paid_through: ^last, billing_day: 10} = reload(account)
      assert [%{status: :succeeded, kind: :returned, source: :card_saved, period_start: @today}] = attempts(account)
      assert Billing.standing(user, @today) == :active
      user_id = user.id
      assert_receive {:billing_changed, ^user_id}
    end

    test "a lapsed (Free) account pays a fresh month from today" do
      user = insert(:user)
      account = account_for(user, %{paid_through: Date.add(@today, -20), billing_day: 3})
      assert Billing.standing(user, @today) == :free

      assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, @today)

      {_start, last} = Periods.period(@today, @today.day)
      assert [%{status: :succeeded, kind: :returned, source: :card_saved, period_start: @today}] = attempts(account)
      assert %{paid_through: ^last, billing_day: 10} = reload(account)
      assert Billing.standing(user, @today) == :active
    end

    test "a successful upgrade clears the Free prompt flag and keeps the pick (RE471)" do
      user = insert(:user)
      board = insert(:board, owner: user)
      prompted_at = ~U[2026-06-01 12:00:00Z]

      account =
        account_for(user, %{
          paid_through: Date.add(@today, -20),
          billing_day: 3,
          free_board_prompted_at: prompted_at,
          free_board_id: board.id
        })

      assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, @today)

      board_id = board.id
      assert %{free_board_prompted_at: nil, free_board_id: ^board_id} = reload(account)
    end

    test "a declined upgrade keeps the Free prompt flag (RE471)" do
      user = insert(:user)
      board = insert(:board, owner: user)
      prompted_at = ~U[2026-06-01 12:00:00Z]

      account =
        account_for(user, %{
          paid_through: Date.add(@today, -20),
          billing_day: 3,
          free_board_prompted_at: prompted_at,
          free_board_id: board.id
        })

      assert {:ok, %{charged: :declined}} = Billing.complete_setup("local_0341_#{user.id}", user.id, @today)

      assert reload(account).free_board_prompted_at == prompted_at
    end

    test "a past-due account renews the period after paid_through, keeping its billing day" do
      user = insert(:user)
      account = account_for(user, %{paid_through: Date.add(@today, -1), billing_day: @today.day})

      assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, @today)

      assert [%{status: :succeeded, kind: :renewal, source: :card_saved, period_start: @today, billing_day: 10}] =
               attempts(account)

      assert reload(account).paid_through == ~D[2026-07-09]
    end

    test "a lapsed cancelled account pays a fresh month and its cancellation is cleared" do
      user = insert(:user)

      account =
        account_for(user, %{
          paid_through: Date.add(@today, -10),
          billing_day: 1,
          cancelled_on: Date.add(@today, -25),
          access_until: Date.add(@today, -10)
        })

      assert Billing.standing(user, @today) == :free

      assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, @today)
      assert [%{status: :succeeded, kind: :returned, period_start: @today, billing_day: 10}] = attempts(account)
      assert %{cancelled_on: nil, access_until: nil, billing_day: 10} = reload(account)
      assert Billing.standing(user, @today) == :active
    end

    test "a declined card leaves a Free account on Free" do
      user = insert(:user)
      account = account_for(user, %{paid_through: Date.add(@today, -20), billing_day: 3})

      assert {:ok, %{charged: :declined}} = Billing.complete_setup("local_0341_#{user.id}", user.id, @today)
      assert [%{status: :failed, decline_reason: "insufficient funds"}] = attempts(account)
      assert Billing.standing(user, @today) == :free
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

    test "a user with no account yet gets one holding the card, and is upgraded" do
      user = insert(:user)

      assert {:ok, %{account: %{card_last4: "4242"}, charged: :paid}} =
               Billing.complete_setup("local_4242_#{user.id}", nil, @today)
    end
  end

  describe "upgrade_without_card/2" do
    setup do
      Process.put(:billing_payments, RaisingPayments)
      :ok
    end

    test "a Free account holding a 100% code upgrades on a $0 month that never reaches Stripe" do
      insert(:promo_code, code: "FRIENDS", percent_off: 100, months: 2)
      user = insert(:user)
      {:ok, account} = Billing.redeem_code(user, "FRIENDS", @today)
      user_id = user.id
      :ok = Billing.subscribe(user_id)

      assert Billing.upgrade_without_card(user, @today) == {:ok, :paid}

      assert [
               %{
                 status: :succeeded,
                 amount_cents: 0,
                 source: :upgrade,
                 kind: :returned,
                 period_start: @today,
                 stripe_payment_intent_id: nil
               }
             ] = attempts(account)

      {@today, last} = Periods.period(@today, @today.day)
      assert %{paid_through: ^last, billing_day: 10, promo_months_left: 1} = reload(account)
      assert Billing.standing(user, @today) == :active
      assert_receive {:billing_changed, ^user_id}
    end

    test "a Free account at full price needs checkout and is not charged" do
      user = insert(:user)
      account = account_for(user, %{})

      assert Billing.upgrade_without_card(user, @today) == {:error, :checkout_required}
      assert attempts(account) == []
    end

    test "an active account needs checkout, even holding a 100% code" do
      promo_code = insert(:promo_code, code: "FRIENDS", percent_off: 100, months: 2)
      user = insert(:user)

      account =
        account_for(user, %{paid_through: Date.add(@today, 10), promo_code_id: promo_code.id, promo_months_left: 2})

      assert Billing.upgrade_without_card(user, @today) == {:error, :checkout_required}
      assert attempts(account) == []
    end

    test "a user with no account at full price needs checkout" do
      assert Billing.upgrade_without_card(insert(:user), @today) == {:error, :checkout_required}
    end
  end

  describe "handle_webhook_event/1" do
    test "a setup-mode checkout.session.completed saves the card" do
      user = insert(:user)
      account_for(user, %{})

      event = %{
        "type" => "checkout.session.completed",
        "data" => %{"object" => %{"id" => "local_4242_#{user.id}", "mode" => "setup"}}
      }

      assert Billing.handle_webhook_event(event) == :ok
      assert Billing.get_account(user).card_last4 == "4242"
    end

    test "setup_intent.succeeded saves the card" do
      user = insert(:user)
      account_for(user, %{})
      event = %{"type" => "setup_intent.succeeded", "data" => %{"object" => %{"id" => "local_0341_#{user.id}"}}}

      assert Billing.handle_webhook_event(event) == :ok
      assert Billing.get_account(user).card_last4 == "0341"
    end

    test "a payment-mode session or any other event is left alone" do
      user = insert(:user)
      account_for(user, %{})
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
      assert summary.free == nil
      assert summary.upgrade_free? == false
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

    test "a Free account: its boards against the limit, the full price and no trial facts" do
      user = insert(:user)
      account_for(user, %{trial_ends_on: ~D[2026-04-03]})
      board = insert(:board, owner: user, name: "Only")

      summary = Billing.summary(user, ~D[2026-03-23])

      assert summary.standing == :free

      assert summary.free == %{
               limit: 1,
               editable_board_id: board.id,
               over_limit?: false,
               boards: [%{id: board.id, slug: board.slug, name: "Only", editable?: true, active_at: board.updated_at}]
             }

      assert summary.upgrade_free? == false
      assert summary.amount_cents == 2000
      assert summary.full_price_cents == 2000
      assert summary.promo == nil
      assert summary.card == nil
      assert summary.payments == []
      assert summary.renews_on == nil
      assert summary.cancellable? == false
      for key <- [:trial_ends_on, :trial_days_left, :first_charge_on], do: refute(Map.has_key?(summary, key))
    end

    test "a code redeemed on Free previews the discounted upgrade and when full price starts" do
      today = ~D[2026-03-23]
      user = insert(:user)
      insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)
      {:ok, _account} = Billing.redeem_code(user, "RELAYCONF", today)

      summary = Billing.summary(user, today)

      assert summary.amount_cents == 1000
      assert summary.upgrade_free? == false

      assert summary.promo == %{
               code: "RELAYCONF",
               percent_off: 50,
               months_left: 3,
               full_price_from: Periods.renewal_after(today, today.day, 3)
             }

      assert summary.promo.full_price_from == ~D[2026-06-23]
    end

    test "a 100% code on Free makes the upgrade free" do
      user = insert(:user)
      insert(:promo_code, code: "FRIENDS", percent_off: 100, months: 2)
      {:ok, _account} = Billing.redeem_code(user, "FRIENDS", ~D[2026-03-23])

      summary = Billing.summary(user, ~D[2026-03-23])

      assert summary.amount_cents == 0
      assert summary.upgrade_free? == true
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

    test "a user with no account is on Free with nothing yet" do
      summary = Billing.summary(insert(:user), ~D[2026-03-23])

      assert %{standing: :free, card: nil, payments: [], promo: nil, upgrade_free?: false} = summary
      assert summary.free == %{limit: 1, boards: [], editable_board_id: nil, over_limit?: false}
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

  describe "facts/2" do
    test "a never-paid account with a declined attempt and no promo: declined, not free" do
      assert Charging.facts(%BillingAccount{paid_through: nil}, true) ==
               %{first_charge_declined?: true, next_charge_free?: false}
    end

    test "a paid account has neither fact" do
      assert Charging.facts(%BillingAccount{paid_through: ~D[2026-06-30]}, true) ==
               %{first_charge_declined?: false, next_charge_free?: false}
    end

    test "no account has neither fact" do
      assert Charging.facts(nil, true) == %{first_charge_declined?: false, next_charge_free?: false}
    end
  end
end
