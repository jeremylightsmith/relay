defmodule Relay.BoardsAdminTest do
  use Relay.DataCase, async: true

  alias Relay.Boards

  defp admin_rows(ids), do: Enum.filter(Boards.list_all_boards_for_admin(), &(&1.id in ids))

  describe "list_all_boards_for_admin/0" do
    test "lists every board, archived and non-member boards included, A–Z by name" do
      zeta = insert(:board, name: "zeta", inserted_at: ~U[2020-01-01 00:00:00Z])

      alpha =
        insert(:board,
          name: "Alpha",
          archived_at: ~U[2020-03-01 00:00:00Z],
          inserted_at: ~U[2020-02-01 00:00:00Z]
        )

      mango = insert(:board, name: "mango", inserted_at: ~U[2020-03-01 00:00:00Z])

      assert [a, m, z] = admin_rows([zeta.id, alpha.id, mango.id])
      assert {a.id, m.id, z.id} == {alpha.id, mango.id, zeta.id}
      assert a.archived_at == ~U[2020-03-01 00:00:00Z]
      assert m.archived_at == nil
      assert z.inserted_at == ~U[2020-01-01 00:00:00Z]
    end

    test "breaks name ties by id ascending" do
      first = insert(:board, name: "Same")
      second = insert(:board, name: "Same")

      assert [%{id: a}, %{id: b}] = admin_rows([first.id, second.id])
      assert {a, b} == {first.id, second.id}
    end

    test "reports the owner email, resolved member count and non-archived card count" do
      owner = insert(:user, email: "owner@example.com")
      board = insert(:board, owner: owner, name: "Row board", key: "AB", slug: "admin-row")
      insert(:membership, board: board, user: owner, email: owner.email)
      insert(:membership, board: board)
      insert(:membership, board: board, user: nil, email: "pending@example.com")
      stage = insert(:stage, board: board)
      insert(:card, stage: stage)
      insert(:card, stage: stage)
      insert(:card, stage: stage, archived_at: ~U[2020-01-01 00:00:00Z])

      assert [row] = admin_rows([board.id])
      assert row.name == "Row board"
      assert row.key == "AB"
      assert row.slug == "admin-row"
      assert row.owner_email == "owner@example.com"
      assert row.member_count == 2
      assert row.card_count == 2
    end

    test "reports zero counts for a board with no members or cards" do
      board = insert(:board)

      assert [%{member_count: 0, card_count: 0}] = admin_rows([board.id])
    end
  end

  describe "member_board_ids/1" do
    test "is the set of boards the user is a member of, archived boards included" do
      user = insert(:user)
      active = insert(:board)
      archived = insert(:board, archived_at: ~U[2020-01-01 00:00:00Z])
      other = insert(:board)
      insert(:membership, board: active, user: user)
      insert(:membership, board: archived, user: user)
      insert(:membership, board: other)

      assert Boards.member_board_ids(user) == MapSet.new([active.id, archived.id])
    end

    test "is empty for a user with no memberships" do
      assert Boards.member_board_ids(insert(:user)) == MapSet.new()
    end
  end
end
