defmodule Relay.Billing.AdminTest do
  # RE463 — the superadmin's billing writes: comp / uncomp, hold / lift hold, extend paid_through,
  # retry the charge now; each writes one admin history entry and broadcasts `billing:<user_id>`.
  # Plus the side panel's read model (`admin_detail/2`) and its small pure helpers.
  use Relay.DataCase, async: true

  alias Relay.Billing
  alias Relay.Billing.Notifier
  alias Relay.Billing.Payments.Local
  alias Schemas.BillingAccount
  alias Schemas.BillingAdminEntry
  alias Schemas.BillingNotice
  alias Schemas.BillingPaymentAttempt

  @today ~D[2026-06-10]

  setup do
    Process.put(:billing_enabled, true)
    %{admin: insert(:user), user: insert(:user)}
  end

  defp account_for(user, attrs), do: insert(:billing_account, Map.merge(%{user: user}, attrs))

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

  defp entries(user) do
    Repo.all(
      from e in BillingAdminEntry,
        join: a in BillingAccount,
        on: a.id == e.billing_account_id,
        where: a.user_id == ^user.id,
        order_by: e.id
    )
  end

  defp attempts(user) do
    Repo.all(
      from p in BillingPaymentAttempt,
        join: a in BillingAccount,
        on: a.id == p.billing_account_id,
        where: a.user_id == ^user.id,
        order_by: p.id
    )
  end

  defp reload(user), do: Repo.get_by!(BillingAccount, user_id: user.id)

  # A paid plan that lapsed past its grace: on Free.
  defp lapsed!(user, attrs \\ %{}),
    do: account_for(user, Map.merge(%{paid_through: ~D[2026-05-31], billing_day: 1}, attrs))

  defp active!(user, attrs \\ %{}),
    do: account_for(user, Map.merge(%{paid_through: ~D[2026-06-30], billing_day: 1}, attrs))

  describe "admin_comp/3" do
    # Scenario 1
    test "comps a Free (lapsed) owner, records one :comp entry by the actor, and broadcasts", %{admin: admin, user: user} do
      lapsed!(user)
      :ok = Billing.subscribe(user.id)

      assert {:ok, %BillingAccount{comped: true}} = Billing.admin_comp(user.id, admin, @today)
      assert Billing.standing(user, @today) == :comped
      assert [%BillingAdminEntry{action: :comp, actor_id: actor_id}] = entries(user)
      assert actor_id == admin.id
      user_id = user.id
      assert_received {:billing_changed, ^user_id}
    end

    # Scenario 2
    test "refuses an already comped account, writing and broadcasting nothing", %{admin: admin, user: user} do
      lapsed!(user)
      {:ok, _} = Billing.admin_comp(user.id, admin, @today)
      :ok = Billing.subscribe(user.id)

      assert Billing.admin_comp(user.id, admin, @today) == {:error, :already_comped}
      assert length(entries(user)) == 1
      user_id = user.id
      refute_received {:billing_changed, ^user_id}
    end

    test "comping clears the Free prompt flag (RE471)", %{admin: admin, user: user} do
      lapsed!(user, %{free_board_prompted_at: ~U[2026-06-01 12:00:00Z]})

      assert {:ok, %BillingAccount{comped: true}} = Billing.admin_comp(user.id, admin, @today)
      assert %BillingAccount{comped: true, free_board_prompted_at: nil} = reload(user)
    end

    # Scenario 19
    test "creates a missing account, with no trial date, and comps it", %{admin: admin, user: user} do
      assert Billing.get_account(user) == nil

      assert {:ok, %BillingAccount{comped: true} = account} = Billing.admin_comp(user.id, admin, @today)
      assert account.trial_ends_on == nil
      assert reload(user).comped
      assert [%BillingAdminEntry{action: :comp}] = entries(user)
    end
  end

  describe "admin_uncomp/3 (scenario 3)" do
    test "a never-paid account drops to Free", %{admin: admin, user: user} do
      account_for(user, %{comped: true})

      assert {:ok, %BillingAccount{comped: false}} = Billing.admin_uncomp(user.id, admin, @today)
      assert Billing.standing(user, @today) == :free
      assert [%BillingAdminEntry{action: :uncomp}] = entries(user)
    end

    test "an account paid through the future is active", %{admin: admin, user: user} do
      account_for(user, %{paid_through: ~D[2026-06-15], comped: true})

      assert {:ok, _account} = Billing.admin_uncomp(user.id, admin, @today)
      assert Billing.standing(user, @today) == :active
    end

    test "refuses an account that is not comped", %{admin: admin, user: user} do
      lapsed!(user)

      assert Billing.admin_uncomp(user.id, admin, @today) == {:error, :not_comped}
      assert entries(user) == []
    end
  end

  describe "admin_hold/4" do
    # Scenario 4
    test "holds an active owner with the trimmed reason", %{admin: admin, user: user} do
      active!(user)
      :ok = Billing.subscribe(user.id)

      assert {:ok, %BillingAccount{held_on: ~D[2026-06-10], hold_reason: "chargeback"}} =
               Billing.admin_hold(user.id, admin, "  chargeback  ", @today)

      assert Billing.standing(user, @today) == {:paused, :hold}
      assert [%BillingAdminEntry{action: :hold, reason: "chargeback"}] = entries(user)
      user_id = user.id
      assert_received {:billing_changed, ^user_id}
    end

    # Scenario 5
    test "a held owner whose renewal is due is not charged by the clock", %{admin: admin, user: user} do
      account_for(user, Map.merge(%{paid_through: ~D[2026-06-09], billing_day: 10}, card_fields(:visa_4242)))
      {:ok, _} = Billing.admin_hold(user.id, admin, "chargeback", @today)

      Billing.run_clock(@today, final_pass?: true)

      assert attempts(user) == []
    end

    # Scenario 6
    test "a blank reason is refused, writing nothing", %{admin: admin, user: user} do
      active!(user)

      assert Billing.admin_hold(user.id, admin, nil, @today) == {:error, :reason_required}
      assert Billing.admin_hold(user.id, admin, "   ", @today) == {:error, :reason_required}
      assert reload(user).held_on == nil
      assert entries(user) == []
    end

    test "an already held account is refused, writing nothing", %{admin: admin, user: user} do
      active!(user, %{held_on: ~D[2026-06-01], hold_reason: "fraud"})
      :ok = Billing.subscribe(user.id)

      assert Billing.admin_hold(user.id, admin, "again", @today) == {:error, :already_held}
      assert reload(user).hold_reason == "fraud"
      assert entries(user) == []
      user_id = user.id
      refute_received {:billing_changed, ^user_id}
    end
  end

  describe "admin_lift_hold/3 (scenario 7)" do
    test "clears the hold and the owner is active again", %{admin: admin, user: user} do
      active!(user)
      {:ok, _} = Billing.admin_hold(user.id, admin, "chargeback", @today)

      assert {:ok, %BillingAccount{held_on: nil, hold_reason: nil}} = Billing.admin_lift_hold(user.id, admin, @today)
      assert Billing.standing(user, @today) == :active
      assert [:hold, :lift_hold] == Enum.map(entries(user), & &1.action)
    end

    test "refuses an unheld account", %{admin: admin, user: user} do
      active!(user)

      assert Billing.admin_lift_hold(user.id, admin, @today) == {:error, :not_held}
      assert entries(user) == []
    end
  end

  describe "admin_extend/5" do
    # Scenario 8
    test "moves paid_through on, keeps the billing day, charges nothing, records the dates", %{
      admin: admin,
      user: user
    } do
      account_for(user, %{paid_through: ~D[2026-06-20], billing_day: 20})

      assert {:ok, %BillingAccount{paid_through: ~D[2026-06-27], billing_day: 20}} =
               Billing.admin_extend(user.id, admin, 7, "outage", @today)

      assert attempts(user) == []

      assert [
               %BillingAdminEntry{
                 action: :extend,
                 days: 7,
                 reason: "outage",
                 paid_through_before: ~D[2026-06-20],
                 paid_through_after: ~D[2026-06-27]
               }
             ] = entries(user)
    end

    # Scenario 9
    test "extending a Free (lapsed) owner past today makes them active", %{admin: admin, user: user} do
      lapsed!(user)

      assert {:ok, %BillingAccount{paid_through: ~D[2026-06-15]}} =
               Billing.admin_extend(user.id, admin, 15, "goodwill", @today)

      assert Billing.standing(user, @today) == :active
    end

    # Scenario 10
    test "refuses days outside 1..365", %{admin: admin, user: user} do
      active!(user)

      for days <- [0, -1, 366] do
        assert Billing.admin_extend(user.id, admin, days, "outage", @today) == {:error, :invalid_days}
      end

      assert entries(user) == []

      assert {:ok, %BillingAccount{paid_through: paid_through}} =
               Billing.admin_extend(user.id, admin, 365, "outage", @today)

      assert paid_through == Date.add(~D[2026-06-30], 365)
      assert Billing.admin_extend_max_days() == 365
    end

    test "refuses a blank reason", %{admin: admin, user: user} do
      active!(user)

      assert Billing.admin_extend(user.id, admin, 7, "", @today) == {:error, :reason_required}
      assert entries(user) == []
    end

    test "refuses a never-paid account", %{admin: admin, user: user} do
      account_for(user, %{})

      assert Billing.admin_extend(user.id, admin, 7, "outage", @today) == {:error, :no_paid_through}
      assert entries(user) == []
    end
  end

  describe "admin_retry_charge/3" do
    # Scenario 11
    test "renews a past-due owner through the charging path as an :admin attempt", %{admin: admin, user: user} do
      account_for(
        user,
        Map.merge(
          %{paid_through: ~D[2026-06-09], billing_day: 10},
          card_fields(:visa_4242)
        )
      )

      assert Billing.admin_retry_charge(user.id, admin, @today) == {:ok, :paid}

      assert [
               %BillingPaymentAttempt{
                 source: :admin,
                 kind: :renewal,
                 period_start: ~D[2026-06-10],
                 status: :succeeded,
                 period_end: period_end
               }
             ] = attempts(user)

      assert reload(user).paid_through == period_end

      assert [
               %BillingAdminEntry{
                 action: :retry_charge,
                 paid_through_before: ~D[2026-06-09],
                 paid_through_after: ^period_end
               }
             ] = entries(user)
    end

    # Scenario 12
    test "a declined retry leaves paid_through and sends no card-declined email", %{admin: admin, user: user} do
      lapsed!(user, card_fields(:visa_0341))

      assert Billing.admin_retry_charge(user.id, admin, @today) == {:ok, :declined}
      assert [%BillingPaymentAttempt{status: :failed, source: :admin}] = attempts(user)
      assert reload(user).paid_through == ~D[2026-05-31]

      Notifier.notify_due(@today)

      account_id = reload(user).id

      refute Repo.exists?(
               from n in BillingNotice, where: n.billing_account_id == ^account_id and n.kind == :card_declined
             )
    end

    # Scenario 13
    test "a never-paid (Free) owner with a card pays a fresh month", %{admin: admin, user: user} do
      account = account_for(user, card_fields(:visa_4242))

      insert(:billing_payment_attempt,
        billing_account: account,
        status: :failed,
        kind: :trial_end,
        source: :clock,
        period_start: ~D[2026-06-02],
        period_end: ~D[2026-07-01],
        billing_day: 2
      )

      assert Billing.admin_retry_charge(user.id, admin, @today) == {:ok, :paid}
      assert %BillingPaymentAttempt{kind: :returned, period_start: ~D[2026-06-10]} = List.last(attempts(user))
      assert Billing.standing(user, @today) == :active
    end

    # Scenario 14
    test "refuses an active, a held and a cardless account", %{admin: admin, user: user} do
      held = insert(:user)
      cardless = insert(:user)
      active!(user, card_fields(:visa_4242))
      lapsed!(held, Map.merge(%{held_on: ~D[2026-06-01], hold_reason: "fraud"}, card_fields(:visa_4242)))
      account_for(cardless, %{paid_through: ~D[2026-06-09], billing_day: 10})

      for owner <- [user, held, cardless] do
        assert Billing.admin_retry_charge(owner.id, admin, @today) == {:error, :not_retryable}
        assert attempts(owner) == []
        assert entries(owner) == []
      end
    end
  end

  # Scenario 15
  test "admin_retryable?/2 needs a card and a past-due or Free standing, never a hold" do
    card = struct(BillingAccount, card_fields(:visa_4242))
    no_card = %BillingAccount{}

    assert Billing.admin_retryable?(card, {:past_due, @today})
    assert Billing.admin_retryable?(card, :free)
    refute Billing.admin_retryable?(no_card, :free)
    refute Billing.admin_retryable?(card, {:paused, :hold})
    refute Billing.admin_retryable?(no_card, {:past_due, @today})
    refute Billing.admin_retryable?(card, :active)
    refute Billing.admin_retryable?(nil, {:past_due, @today})
  end

  test "admin_refusals/0 lists every refusal in order" do
    assert Billing.admin_refusals() == [
             :already_comped,
             :not_comped,
             :reason_required,
             :already_held,
             :not_held,
             :invalid_days,
             :no_paid_through,
             :not_retryable
           ]
  end

  test "BillingAdminEntry.actions/0 lists every admin action in order" do
    assert BillingAdminEntry.actions() == [:comp, :uncomp, :hold, :lift_hold, :extend, :retry_charge]
  end

  test "attempts may be opened by :admin and by the $0 :upgrade" do
    assert BillingPaymentAttempt.sources() == [:clock, :card_saved, :admin, :upgrade]
  end

  # Scenario 16
  describe "admin_detail/2" do
    test "the owner's facts, payment history newest first and admin history", %{admin: admin, user: user} do
      insert(:board, owner: user)
      promo = insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)

      account =
        account_for(
          user,
          Map.merge(
            %{
              paid_through: ~D[2026-06-30],
              billing_day: 1,
              promo_code_id: promo.id,
              promo_months_left: 2,
              stripe_customer_id: "cus_1"
            },
            card_fields(:visa_4242)
          )
        )

      paid =
        insert(:billing_payment_attempt,
          billing_account: account,
          status: :succeeded,
          stripe_payment_intent_id: "pi_1",
          period_start: ~D[2026-06-01],
          period_end: ~D[2026-06-30],
          resolved_at: ~U[2026-06-01 12:00:00Z]
        )

      declined =
        insert(:billing_payment_attempt,
          billing_account: account,
          status: :failed,
          period_start: ~D[2026-07-01],
          period_end: ~D[2026-07-31],
          resolved_at: ~U[2026-07-01 12:00:00Z]
        )

      {:ok, _} = Billing.admin_comp(user.id, admin, @today)

      detail = Billing.admin_detail(user.id, @today)

      assert detail.user_id == user.id
      assert detail.email == user.email
      assert detail.card == %{brand_label: "Visa", last4: "4242"}
      assert detail.code_label == "RELAYCONF 1/3"
      assert detail.stripe_url =~ "/customers/cus_1"
      assert detail.comped?
      refute detail.held?
      assert detail.plan == :comped
      refute Map.has_key?(detail, :trial_ends_on)

      declined_id = declined.id
      paid_id = paid.id

      assert [
               %{id: ^declined_id, outcome: :declined, date: ~D[2026-07-01]},
               %{id: ^paid_id, outcome: :paid, stripe_payment_intent_id: "pi_1", date: ~D[2026-06-01]}
             ] = detail.attempts

      admin_email = admin.email
      assert [%{action: :comp, actor_email: ^admin_email, reason: nil, days: nil}] = detail.entries
    end

    test "is nil for an unknown user id" do
      assert Billing.admin_detail(-1, @today) == nil
    end
  end

  describe "renewal_log/1" do
    # Three accounts' attempts: A paid (with a code), B declined, C still pending.
    defp seed_renewals do
      [owner_a, owner_b, owner_c] = for name <- ["Ada", "Bea", "Cy"], do: insert(:user, name: name)

      a =
        insert(:billing_payment_attempt,
          billing_account: account_for(owner_a, %{}),
          status: :succeeded,
          inserted_at: ~U[2026-06-01 10:00:00Z],
          resolved_at: ~U[2026-06-01 10:00:05Z],
          promo_code: "RELAYCONF",
          amount_cents: 1000,
          stripe_payment_intent_id: "pi_a"
        )

      b =
        insert(:billing_payment_attempt,
          billing_account: account_for(owner_b, %{}),
          status: :failed,
          inserted_at: ~U[2026-06-02 10:00:00Z]
        )

      c =
        insert(:billing_payment_attempt,
          billing_account: account_for(owner_c, %{}),
          status: :pending,
          inserted_at: ~U[2026-06-03 10:00:00Z]
        )

      %{a: a, b: b, c: c, owner_a: owner_a}
    end

    defp ids(rows), do: Enum.map(rows, & &1.id)

    # Scenario 1
    test "nil lists every attempt across accounts, newest first, with its owner and outcome" do
      %{a: a, b: b, c: c, owner_a: owner_a} = seed_renewals()

      rows = Billing.renewal_log(nil)
      assert ids(rows) == [c.id, b.id, a.id]

      [row_c, _row_b, row_a] = rows

      assert %{
               date: ~D[2026-06-01],
               code: "RELAYCONF",
               amount_cents: 1000,
               outcome: :paid,
               stripe_payment_intent_id: "pi_a",
               period_start: period_start,
               period_end: period_end
             } = row_a

      assert {period_start, period_end} == {a.period_start, a.period_end}
      assert row_a.user == %{id: owner_a.id, name: owner_a.name, email: owner_a.email}

      assert %{outcome: :unknown, date: ~D[2026-06-03], code: nil} = row_c
    end

    # Scenario 2
    test "an outcome keeps only the attempts whose status comes to it" do
      %{b: b, c: c} = seed_renewals()

      assert ids(Billing.renewal_log(:declined)) == [b.id]
      assert ids(Billing.renewal_log(:unknown)) == [c.id]
      assert Billing.renewal_log(:not_charged) == []
    end

    # Scenario 3
    test "is capped at renewal_log_limit/0 rows and reads in one query" do
      seed_renewals()

      assert Billing.renewal_log_limit() == 500
      assert {[_, _, _], 1} = count_repo_queries(self(), fn -> Billing.renewal_log(nil) end)
    end
  end

  # Scenario 17
  test "stripe_customer_url/1 links the test or live dashboard by the secret key" do
    assert Billing.stripe_customer_url(nil) == nil

    Process.put(:stripe_secret_key, "sk_test_x")
    assert Billing.stripe_customer_url("cus_1") == "https://dashboard.stripe.com/test/customers/cus_1"

    Process.put(:stripe_secret_key, "sk_live_x")
    assert Billing.stripe_customer_url("cus_1") == "https://dashboard.stripe.com/customers/cus_1"
  end

  # Scenario 18
  test "attempt_outcome/1 maps every attempt status, and attempt_statuses_for/1 inverts it" do
    assert Map.new(BillingPaymentAttempt.statuses(), &{&1, Billing.attempt_outcome(&1)}) == %{
             succeeded: :paid,
             failed: :declined,
             pending: :unknown,
             unknown: :unknown,
             not_charged: :not_charged
           }

    assert Billing.attempt_outcomes() == [:paid, :declined, :unknown, :not_charged]
    assert Billing.attempt_statuses_for(:unknown) == [:pending, :unknown]
    assert Billing.attempt_statuses_for(:paid) == [:succeeded]

    assert Enum.sort(Enum.flat_map(Billing.attempt_outcomes(), &Billing.attempt_statuses_for/1)) ==
             Enum.sort(BillingPaymentAttempt.statuses())
  end
end
