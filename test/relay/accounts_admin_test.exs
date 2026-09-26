defmodule Relay.AccountsAdminTest do
  use Relay.DataCase, async: true

  alias Relay.Accounts

  describe "list_users_for_admin/0" do
    test "lists users newest first with name, email, provider, created date and board count" do
      older =
        insert(:user,
          name: "Older",
          email: "older@example.com",
          provider: "google",
          inserted_at: ~U[2020-01-01 00:00:00Z]
        )

      newer = insert(:user, name: "Newer", email: "newer@example.com", inserted_at: ~U[2020-02-01 00:00:00Z])
      insert(:membership, user: older)
      insert(:membership, user: older)

      rows = Enum.filter(Accounts.list_users_for_admin(), &(&1.id in [older.id, newer.id]))

      assert [n, o] = rows
      assert n.id == newer.id
      assert n.board_count == 0
      assert o.id == older.id
      assert o.board_count == 2
      assert o.name == "Older"
      assert o.email == "older@example.com"
      assert o.provider == "google"
      assert o.inserted_at == ~U[2020-01-01 00:00:00Z]
    end

    test "breaks inserted_at ties by id desc" do
      first = insert(:user, inserted_at: ~U[2020-01-01 00:00:00Z])
      second = insert(:user, inserted_at: ~U[2020-01-01 00:00:00Z])

      ids = for r <- Accounts.list_users_for_admin(), r.id in [first.id, second.id], do: r.id
      assert ids == [second.id, first.id]
    end
  end
end
