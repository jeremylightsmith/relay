defmodule Hamaca.VotesTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Events
  alias Hamaca.Votes

  describe "toggle_vote/2" do
    test "adds then removes, idempotently, and enforces uniqueness" do
      card = insert(:card)
      user = insert(:user)

      assert {:ok, :added} = Votes.toggle_vote(user, card)
      assert Votes.count(card.id) == 1
      assert Votes.voted_card_ids(user, [card.id]) == MapSet.new([card.id])

      assert {:ok, :removed} = Votes.toggle_vote(user, card)
      assert Votes.count(card.id) == 0
      assert Votes.voted_card_ids(user, [card.id]) == MapSet.new()
    end

    test "broadcasts {:vote_changed, card_id} on the board topic" do
      card = insert(:card)
      user = insert(:user)
      Events.subscribe(card.board_id)

      Votes.toggle_vote(user, card)
      assert_receive {:vote_changed, card_id}
      assert card_id == card.id
    end
  end

  describe "counts and membership" do
    test "counts_for_cards returns a grouped map, missing ids omitted" do
      board = insert(:board)
      card_a = insert(:card, stage: insert(:stage, board: board))
      card_b = insert(:card, stage: insert(:stage, board: board))
      insert(:vote, card: card_a)
      insert(:vote, card: card_a)

      counts = Votes.counts_for_cards([card_a.id, card_b.id])
      assert counts == %{card_a.id => 2}
    end

    test "voted_card_ids returns only the user's voted cards" do
      user = insert(:user)
      board = insert(:board)
      voted = insert(:card, stage: insert(:stage, board: board))
      other = insert(:card, stage: insert(:stage, board: board))
      insert(:vote, card: voted, user: user)

      ids = Votes.voted_card_ids(user, [voted.id, other.id])
      assert MapSet.equal?(ids, MapSet.new([voted.id]))
    end
  end

  describe "supporters/2" do
    test "returns up to `limit` users most-recent first, plus the total" do
      card = insert(:card)
      older = insert(:user)
      newer = insert(:user)
      insert(:vote, card: card, user: older, inserted_at: ~U[2026-01-01 00:00:00Z])
      insert(:vote, card: card, user: newer, inserted_at: ~U[2026-02-01 00:00:00Z])

      {[first | _] = users, total} = Votes.supporters(card, 1)
      assert total == 2
      assert length(users) == 1
      assert first.id == newer.id
    end
  end

  describe "supporters/3 with exclude_user_id:" do
    setup do
      card = insert(:card)
      [r, a, b] = insert_list(3, :user)
      %{card: card, r: r, a: a, b: b}
    end

    defp vote_in_order(card, users) do
      users
      |> Enum.with_index()
      |> Enum.each(fn {user, i} ->
        insert(:vote, card: card, user: user, inserted_at: DateTime.add(~U[2026-01-01 00:00:00Z], i, :day))
      end)
    end

    test "drops the excluded requester from the faces and the count", %{card: c, r: r, a: a, b: b} do
      vote_in_order(c, [r, a, b])

      assert {users, 2} = Votes.supporters(c, 5, exclude_user_id: r.id)
      assert Enum.map(users, & &1.id) == [b.id, a.id]
    end

    test "nil or absent exclusion returns every supporter", %{card: c, r: r, a: a, b: b} do
      vote_in_order(c, [r, a, b])

      assert {users, 3} = Votes.supporters(c, 5)
      assert length(users) == 3
      assert {users, 3} = Votes.supporters(c, 5, exclude_user_id: nil)
      assert length(users) == 3
    end

    test "a card voted only by the requester has no other supporters", %{card: c, r: r} do
      vote_in_order(c, [r])

      assert Votes.supporters(c, 5, exclude_user_id: r.id) == {[], 0}
    end

    test "a requester who never voted excludes nobody", %{card: c, r: r, a: a} do
      vote_in_order(c, [a])

      assert {[only], 1} = Votes.supporters(c, 5, exclude_user_id: r.id)
      assert only.id == a.id
    end
  end
end
