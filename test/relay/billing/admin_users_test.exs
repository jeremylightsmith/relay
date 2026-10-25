defmodule Relay.Billing.AdminUsersTest do
  use Relay.DataCase, async: true

  alias Relay.Billing
  alias Relay.Billing.Payments.Local
  alias Relay.Billing.Standing

  @today ~D[2026-06-10]

  defp row(user), do: Enum.find(Billing.list_admin_users(@today), &(&1.id == user.id))

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

  # A user who owns one board, with an optional billing account built from `account_attrs`.
  defp owner(account_attrs \\ nil) do
    user = insert(:user)
    insert(:board, owner: user)
    account = account_attrs && insert(:billing_account, Map.merge(%{user: user}, account_attrs))
    {user, account}
  end

  defp free_owner, do: owner(%{})

  defp relayconf_owner do
    promo = insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)

    owner(
      Map.merge(card_fields(:visa_4242), %{
        promo_code_id: promo.id,
        promo_months_left: 2,
        paid_through: ~D[2026-06-30]
      })
    )
  end

  defp lapsed_owner, do: owner(%{paid_through: ~D[2026-05-31]})
  defp past_due_owner, do: owner(%{paid_through: ~D[2026-06-09]})
  defp comped_owner, do: owner(%{comped: true})

  defp held_owner, do: owner(%{held_on: ~D[2026-06-01], paid_through: ~D[2026-06-30]})

  defp declined_owner(failed?) do
    {user, account} = owner(card_fields(:visa_4242))
    if failed?, do: insert(:billing_payment_attempt, billing_account: account, status: :failed, kind: :returned)
    {user, account}
  end

  defp member_only_user do
    user = insert(:user)
    insert(:membership, user: user, board: insert(:board))
    user
  end

  describe "list_admin_users/1" do
    test "a never-paid owner is on Free with no paid through and the full price" do
      {user, _account} = free_owner()

      assert %{
               plan: :free,
               standing: :free,
               paid_through_shown: nil,
               rate_cents: 2000,
               code_label: nil,
               member_count: 1,
               owned_board_count: 1
             } = row(user)
    end

    test "an active owner on RELAYCONF shows the discounted rate and the code's progress" do
      {user, _account} = relayconf_owner()

      assert %{
               plan: :active,
               rate_cents: 1000,
               code_label: "RELAYCONF 1/3",
               paid_through_shown: ~D[2026-06-30]
             } = row(user)
    end

    test "an owner past the grace is on Free, showing the paid through they lapsed from" do
      {user, _account} = lapsed_owner()

      assert %{plan: :free, standing: :free, rate_cents: 2000, paid_through_shown: ~D[2026-05-31]} = row(user)
    end

    test "an owner inside the grace is past due" do
      {user, _account} = past_due_owner()
      assert %{plan: :past_due} = row(user)
    end

    test "a comped owner who never paid shows a $0 rate and no paid through" do
      {user, _account} = comped_owner()
      assert %{plan: :comped, rate_cents: 0, paid_through_shown: nil} = row(user)
    end

    test "an owner on hold is paused for the hold" do
      {user, _account} = held_owner()
      assert %{plan: :paused, standing: {:paused, :hold}} = row(user)
    end

    test "a never-paid owner with a card is on Free, declined attempt or not" do
      {declined, _account} = declined_owner(true)
      {clean, _account} = declined_owner(false)
      assert %{plan: :free, standing: :free} = row(declined)
      assert %{plan: :free, standing: :free} = row(clean)
    end

    test "a user who owns no boards is member only with no billing values" do
      user = member_only_user()

      assert %{
               plan: :member_only,
               rate_cents: nil,
               code_label: nil,
               paid_through_shown: nil,
               member_count: 0,
               board_count: 1
             } = row(user)
    end

    test "member_count is the distinct people on the boards a user owns, the owner included" do
      user = insert(:user)
      u2 = insert(:user)
      u3 = insert(:user)
      a = insert(:board, owner: user)
      b = insert(:board, owner: user)
      insert(:membership, board: a, user: user)
      insert(:membership, board: a, user: u2)
      insert(:membership, board: a, user: nil)
      insert(:membership, board: b, user: u2)
      insert(:membership, board: b, user: u3)

      assert %{member_count: 3, owned_board_count: 2, board_count: 1} = row(user)
    end

    test "a board owner with no billing account is on Free" do
      {user, nil} = owner()
      assert %{plan: :free, paid_through_shown: nil, rate_cents: 2000, account: nil} = row(user)
    end

    test "rows come newest first, ties broken by id desc" do
      older = insert(:user, inserted_at: ~U[2020-01-01 00:00:00Z])
      newer = insert(:user, inserted_at: ~U[2021-01-01 00:00:00Z])
      tie_first = insert(:user, inserted_at: ~U[2019-01-01 00:00:00Z])
      tie_second = insert(:user, inserted_at: ~U[2019-01-01 00:00:00Z])
      ids = [older.id, newer.id, tie_first.id, tie_second.id]

      listed = for r <- Billing.list_admin_users(@today), r.id in ids, do: r.id
      assert listed == [newer.id, older.id, tie_second.id, tie_first.id]
    end

    test "carries name, email, created date and the membership board count" do
      user = insert(:user, name: "Older", email: "older@example.com", inserted_at: ~U[2020-01-01 00:00:00Z])
      insert(:membership, user: user)
      insert(:membership, user: user)

      assert %{
               name: "Older",
               email: "older@example.com",
               inserted_at: ~U[2020-01-01 00:00:00Z],
               board_count: 2,
               owned_board_count: 0
             } = row(user)
    end

    test "loads every row in one query" do
      free_owner()
      relayconf_owner()
      lapsed_owner()
      past_due_owner()
      comped_owner()
      held_owner()
      declined_owner(true)
      member_only_user()

      {rows, count} = count_repo_queries(self(), fn -> Billing.list_admin_users(@today) end)

      assert count == 1
      assert length(rows) >= 9
    end
  end

  describe "admin_summary/1" do
    test "counts users, paying rows, their monthly total and Free rows" do
      rows =
        for {plan, rate} <- [
              free: 2000,
              active: 1000,
              past_due: 2000,
              paused: 2000,
              comped: 0,
              member_only: nil
            ],
            do: %{plan: plan, rate_cents: rate}

      assert Billing.admin_summary(rows) == %{users: 6, paying: 2, mrr_cents: 3000, free: 1}
    end

    test "is all zeros for no rows" do
      assert Billing.admin_summary([]) == %{users: 0, paying: 0, mrr_cents: 0, free: 0}
    end
  end

  test "format_dollars/1 drops whole-dollar cents and groups thousands" do
    assert Billing.format_dollars(0) == "$0"
    assert Billing.format_dollars(5) == "$0.05"
    assert Billing.format_dollars(1000) == "$10"
    assert Billing.format_dollars(1250) == "$12.50"
    assert Billing.format_dollars(65_000) == "$650"
    assert Billing.format_dollars(125_000) == "$1,250"
  end

  describe "admin plans" do
    test "admin_plan/2 is member only with no owned boards, else the standing's kind" do
      assert Billing.admin_plan(:active, 0) == :member_only
      assert Billing.admin_plan({:past_due, ~D[2026-06-10]}, 2) == :past_due
    end

    test "admin_plans/0 is every standing kind then member only" do
      assert Billing.admin_plans() == Standing.kinds() ++ [:member_only]
    end

    test "paying_plans/0 is active and past due" do
      assert Billing.paying_plans() == [:active, :past_due]
    end
  end
end
