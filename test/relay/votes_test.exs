defmodule Relay.VotesTest do
  use Relay.DataCase, async: true

  alias Relay.Events
  alias Relay.Votes

  describe "toggle_vote/2" do
    test "adds then removes, idempotently, and enforces uniqueness" do
      card = insert(:card)
      user = insert(:user)

      assert {:ok, :added} = Votes.toggle_vote(user, card)
      assert Votes.count(card.id) == 1
      assert Votes.voted?(user, card)

      assert {:ok, :removed} = Votes.toggle_vote(user, card)
      assert Votes.count(card.id) == 0
      refute Votes.voted?(user, card)
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
end
