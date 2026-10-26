defmodule Hamaca.Billing.PromoChargingTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Billing
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
    def charge(_customer_id, _payment_method_id, _amount_cents, _key, _meta), do: raise("charge/5 must not be called")
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

  defp relayconf, do: insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)

  defp redeem!(account, code, on) do
    {:ok, account} = Billing.redeem_code(account.user_id, code, on)
    account
  end

  describe "discounted_cents/2" do
    test "takes the percent off, rounded half-up to the cent" do
      assert Billing.discounted_cents(2000, 50) == 1000
      assert Billing.discounted_cents(2000, 100) == 0
      assert Billing.discounted_cents(2000, 1) == 1980
      assert Billing.discounted_cents(2000, 33) == 1340
      assert Billing.discounted_cents(1999, 50) == 1000
      assert Billing.discounted_cents(1999, 67) == 660
    end
  end

  describe "next_charge/1" do
    test "no account is the full price" do
      assert Billing.next_charge(nil) == %{amount_cents: 2000, promo_code: nil, percent_off: nil}
    end

    test "an account holding a code with months left gets its percent off" do
      relayconf()
      account = :billing_account |> insert() |> redeem!("RELAYCONF", ~D[2026-03-10])
      assert account.promo_months_left == 3

      assert Billing.next_charge(account) == %{amount_cents: 1000, promo_code: "RELAYCONF", percent_off: 50}
    end

    test "an account whose code has no months left pays the full price" do
      promo_code = relayconf()
      account = insert(:billing_account, promo_code_id: promo_code.id, promo_months_left: 0)

      assert Billing.next_charge(account) == %{amount_cents: 2000, promo_code: nil, percent_off: nil}
    end

    test "a code disabled after it was redeemed still discounts the account holding it" do
      promo_code = relayconf()
      account = :billing_account |> insert() |> redeem!("RELAYCONF", ~D[2026-03-10])
      {:ok, _disabled} = Billing.disable_promo_code(promo_code.id, ~U[2026-03-11 12:00:00Z])
      account = account |> Ecto.Changeset.change(promo_months_left: 2) |> Repo.update!()

      assert %{amount_cents: 1000} = Billing.next_charge(account)
    end
  end

  describe "timeline B: RELAYCONF redeemed on a paid plan" do
    setup do
      relayconf()

      account =
        :visa_4242 |> account(%{paid_through: ~D[2026-04-03], billing_day: 4}) |> redeem!("RELAYCONF", ~D[2026-03-10])

      %{account: account}
    end

    test "charges $10 three times, then $20", %{account: account} do
      months_left =
        for today <- [~D[2026-04-04], ~D[2026-05-04], ~D[2026-06-04], ~D[2026-07-04]] do
          Billing.run_clock(today)
          reload(account).promo_months_left
        end

      assert Enum.take(months_left, 3) == [2, 1, 0]

      attempts = attempts(account)
      assert Enum.map(attempts, & &1.status) == [:succeeded, :succeeded, :succeeded, :succeeded]
      assert Enum.map(attempts, & &1.amount_cents) == [1000, 1000, 1000, 2000]
      assert Enum.map(attempts, & &1.promo_code) == ["RELAYCONF", "RELAYCONF", "RELAYCONF", nil]
      assert Enum.map(attempts, & &1.promo_percent_off) == [50, 50, 50, nil]
      assert reload(account).paid_through == ~D[2026-08-03]
    end
  end

  test "a declined discounted charge doesn't use up a month" do
    relayconf()

    account =
      :visa_0341 |> account(%{paid_through: ~D[2026-04-03], billing_day: 4}) |> redeem!("RELAYCONF", ~D[2026-03-10])

    Billing.run_clock(~D[2026-04-04])

    assert [%{status: :failed, amount_cents: 1000, promo_code: "RELAYCONF"}] = attempts(account)
    assert reload(account).promo_months_left == 3
  end

  test "an unknown discounted charge uses up a month only once it resolves as paid" do
    relayconf()

    account =
      :timeout |> account(%{paid_through: ~D[2026-04-03], billing_day: 4}) |> redeem!("RELAYCONF", ~D[2026-03-10])

    Billing.run_clock(~D[2026-04-04])

    assert [%{status: :unknown}] = attempts(account)
    assert reload(account).promo_months_left == 3

    Billing.run_clock(~D[2026-04-04])

    assert [%{status: :succeeded}] = attempts(account)
    assert reload(account).promo_months_left == 2
  end

  test "a code redeemed mid-plan discounts the next renewal, not the current period" do
    relayconf()
    account = account(:visa_4242, %{paid_through: ~D[2026-05-03], billing_day: 4})

    redeem!(account, "RELAYCONF", ~D[2026-04-20])
    assert attempts(account) == []

    Billing.run_clock(~D[2026-05-04])

    assert [%{status: :succeeded, amount_cents: 1000, promo_code: "RELAYCONF"}] = attempts(account)
  end

  describe "a 100% code with no card" do
    setup do
      Process.put(:billing_payments, RaisingPayments)
      insert(:promo_code, code: "FRIENDS", percent_off: 100, months: 2)
      account = :billing_account |> insert() |> redeem!("FRIENDS", ~D[2026-03-10])
      %{account: account}
    end

    test "stays on Free, uncharged by the clock, until the owner upgrades", %{account: account} do
      Billing.run_clock(~D[2026-04-04], final_pass?: true)

      assert attempts(account) == []
      assert Billing.standing(account.user_id, ~D[2026-04-04]) == :free
    end

    test "upgraded, renews $0 months without calling Stripe, then drops to Free when they run out", %{
      account: account
    } do
      owner = Repo.get!(Schemas.User, account.user_id)
      assert Billing.upgrade_without_card(owner, ~D[2026-04-04]) == {:ok, :paid}

      assert [
               %{
                 status: :succeeded,
                 source: :upgrade,
                 amount_cents: 0,
                 stripe_payment_intent_id: nil,
                 promo_percent_off: 100
               }
             ] = attempts(account)

      assert %{paid_through: ~D[2026-05-03], promo_months_left: 1} = reload(account)

      Billing.run_clock(~D[2026-05-04])

      assert [_first, %{status: :succeeded, source: :clock, amount_cents: 0}] = attempts(account)
      assert reload(account).promo_months_left == 0

      Billing.run_clock(~D[2026-06-04])

      assert length(attempts(account)) == 2
      assert Billing.standing(account.user_id, ~D[2026-06-05]) == :free
    end
  end
end
