defmodule Relay.Billing.PromoCodesTest do
  use Relay.DataCase, async: true

  alias Relay.Billing
  alias Schemas.BillingAccount
  alias Schemas.PromoCode

  @today ~D[2026-03-10]

  setup do
    Process.put(:billing_enabled, true)
    :ok
  end

  defp free_user do
    user = insert(:user)
    insert(:billing_account, user: user)
    user
  end

  defp account_of(user), do: Repo.get_by!(BillingAccount, user_id: user.id)

  defp holder_of(code), do: insert(:billing_account, promo_code: code, promo_months_left: code.months)

  defp promo_count, do: Repo.aggregate(PromoCode, :count)

  describe "create_promo_code/1" do
    test "trims and upper-cases the code and casts every field" do
      assert {:ok,
              %PromoCode{
                code: "RELAYCONF",
                percent_off: 50,
                months: 3,
                max_redemptions: 200,
                expires_on: ~D[2026-12-31],
                disabled_at: nil
              }} =
               Billing.create_promo_code(%{
                 "code" => " relayconf ",
                 "percent_off" => "50",
                 "months" => "3",
                 "max_redemptions" => "200",
                 "expires_on" => "2026-12-31"
               })
    end

    test "refuses a code that already exists in another case" do
      insert(:promo_code, code: "RELAYCONF")

      assert {:error, changeset} =
               Billing.create_promo_code(%{"code" => "RelayConf", "percent_off" => "10", "months" => "1"})

      assert errors_on(changeset).code == ["already exists"]
    end

    test "refuses an out-of-range field and inserts nothing" do
      valid = %{"code" => "VALID", "percent_off" => "50", "months" => "3"}

      for {field, value} <- [
            {:percent_off, "0"},
            {:percent_off, "101"},
            {:months, "0"},
            {:max_redemptions, "0"}
          ] do
        assert {:error, changeset} = Billing.create_promo_code(Map.put(valid, to_string(field), value))
        assert Map.has_key?(errors_on(changeset), field), "expected an error on #{field} for #{value}"
      end

      assert {:error, changeset} = Billing.create_promo_code(Map.put(valid, "code", "A B"))
      assert errors_on(changeset).code == ["use 3–32 letters, digits, - or _"]

      assert promo_count() == 0
    end

    test "never casts disabled_at" do
      assert {:ok, %PromoCode{disabled_at: nil}} =
               Billing.create_promo_code(%{
                 "code" => "NODISABLE",
                 "percent_off" => "10",
                 "months" => "1",
                 "disabled_at" => "2026-01-01T00:00:00Z"
               })
    end
  end

  describe "change_promo_code/2" do
    test "answers the validating changeset" do
      changeset = Billing.change_promo_code(%PromoCode{}, %{"code" => " abc ", "percent_off" => "0"})

      assert %Ecto.Changeset{valid?: false} = changeset
      assert Ecto.Changeset.get_change(changeset, :code) == "ABC"
      assert Map.has_key?(errors_on(changeset), :percent_off)
    end
  end

  describe "redeem_code/3" do
    test "stores the code and its months on the account and broadcasts" do
      user = free_user()
      relayconf = insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)
      :ok = Billing.subscribe(user.id)

      assert {:ok, account} = Billing.redeem_code(user, "relayconf", @today)

      assert account.promo_code_id == relayconf.id
      assert account.promo_months_left == 3
      user_id = user.id
      assert_receive {:billing_changed, ^user_id}
    end

    test "creates the account, with no trial date, for a user without one" do
      user = insert(:user)
      relayconf = insert(:promo_code, code: "RELAYCONF")

      assert {:ok, account} = Billing.redeem_code(user, "RELAYCONF", @today)

      assert account.trial_ends_on == nil
      assert account.promo_code_id == relayconf.id
      assert account_of(user).promo_code_id == relayconf.id
    end

    test "an unknown, blank or nil code is :unknown" do
      user = free_user()

      assert Billing.redeem_code(user, "NOPE", @today) == {:error, :unknown}
      assert Billing.redeem_code(user, "", @today) == {:error, :unknown}
      assert Billing.redeem_code(user, nil, @today) == {:error, :unknown}
    end

    test "a disabled code is :disabled and writes nothing" do
      user = free_user()
      insert(:promo_code, code: "OLD", disabled_at: ~U[2026-03-01 00:00:00Z])
      :ok = Billing.subscribe(user.id)

      assert Billing.redeem_code(user, "OLD", @today) == {:error, :disabled}
      assert account_of(user).promo_code_id == nil
      refute_received {:billing_changed, _}
    end

    test "a code is :expired the day after expires_on and redeems on the day itself" do
      insert(:promo_code, code: "MARCH", expires_on: ~D[2026-03-31])

      assert Billing.redeem_code(free_user(), "MARCH", ~D[2026-04-01]) == {:error, :expired}
      assert {:ok, _account} = Billing.redeem_code(free_user(), "MARCH", ~D[2026-03-31])
    end

    test "a code held by max_redemptions accounts is :full" do
      code = insert(:promo_code, code: "TWO", max_redemptions: 2)
      holder_of(code)
      holder_of(code)

      assert Billing.redeem_code(free_user(), "TWO", @today) == {:error, :full}
    end

    test "an account that already holds a code is :already_redeemed, checked first" do
      relayconf = insert(:promo_code, code: "RELAYCONF")
      insert(:promo_code, code: "FRIENDS")
      user = free_user()
      {:ok, _account} = Billing.redeem_code(user, "RELAYCONF", @today)

      assert Billing.redeem_code(user, "FRIENDS", @today) == {:error, :already_redeemed}
      assert account_of(user).promo_code_id == relayconf.id
      assert Billing.redeem_code(user, "NOPE", @today) == {:error, :already_redeemed}
    end
  end

  describe "redeem_code/3 — the cap race" do
    test "two concurrent redemptions of the last slot: exactly one wins" do
      code = insert(:promo_code, code: "LAST", max_redemptions: 1)
      users = [free_user(), free_user()]

      results =
        users
        |> Enum.map(fn user -> Task.async(fn -> Billing.redeem_code(user, "LAST", @today) end) end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, _account}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :full})) == 1
      assert Repo.aggregate(from(a in BillingAccount, where: a.promo_code_id == ^code.id), :count) == 1
    end
  end

  describe "disable_promo_code/2" do
    test "stops new redemptions and leaves holders their months" do
      relayconf = insert(:promo_code, code: "RELAYCONF", months: 3)
      holder = free_user()
      {:ok, _account} = Billing.redeem_code(holder, "RELAYCONF", @today)

      assert {:ok, %PromoCode{disabled_at: ~U[2026-05-01 12:00:00Z]}} =
               Billing.disable_promo_code(relayconf.id, ~U[2026-05-01 12:00:00Z])

      assert account_of(holder).promo_months_left == 3
      assert Billing.redeem_code(free_user(), "RELAYCONF", @today) == {:error, :disabled}
    end

    test "keeps the original disabled_at on an already disabled code" do
      code = insert(:promo_code, disabled_at: ~U[2026-05-01 12:00:00Z])

      assert {:ok, %PromoCode{disabled_at: ~U[2026-05-01 12:00:00Z]}} =
               Billing.disable_promo_code(code.id, ~U[2026-06-01 12:00:00Z])

      assert Repo.get!(PromoCode, code.id).disabled_at == ~U[2026-05-01 12:00:00Z]
    end

    test "an unknown id is :not_found" do
      assert Billing.disable_promo_code(-1, ~U[2026-05-01 12:00:00Z]) == {:error, :not_found}
    end
  end

  describe "list_promo_codes/0" do
    test "lists codes newest first with how many accounts hold each" do
      a = insert(:promo_code, code: "A")
      holder_of(a)
      holder_of(a)
      insert(:promo_code, code: "B")

      assert [%{promo_code: %PromoCode{code: "B"}, used: 0}, %{promo_code: %PromoCode{code: "A"}, used: 2}] =
               Billing.list_promo_codes()
    end
  end

  test "promo_refusals/0 is the refusal set in the order it is checked" do
    assert Billing.promo_refusals() == [:already_redeemed, :unknown, :disabled, :expired, :full]
  end

  describe "database constraints" do
    test "a lower-case code is refused by the database" do
      assert_raise Ecto.ConstraintError, ~r/promo_codes_code_upper/, fn ->
        Repo.insert(%PromoCode{code: "lower", percent_off: 50, months: 3})
      end
    end

    test "a payment attempt may be $0 but not negative" do
      assert %{amount_cents: 0} = insert(:billing_payment_attempt, amount_cents: 0)

      assert_raise Ecto.ConstraintError, ~r/billing_payment_attempts_amount_non_negative/, fn ->
        insert(:billing_payment_attempt, amount_cents: -1)
      end
    end
  end
end
