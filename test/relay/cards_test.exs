defmodule Relay.CardsTest do
  use Relay.DataCase, async: true

  alias Relay.Boards.Board
  alias Relay.Cards
  alias Relay.Cards.Card

  setup do
    board = insert(:board, key: "RLY")
    stage = insert(:stage, board: board, position: 1)
    %{board: board, stage: stage}
  end

  describe "create_card/2" do
    test "creates a card in the stage with the given title", %{board: board, stage: stage} do
      assert {:ok, %Card{} = card} = Cards.create_card(stage, %{title: "Ship MMF 03"})

      assert card.title == "Ship MMF 03"
      assert card.stage_id == stage.id
      assert card.board_id == board.id
      assert card.tag == nil
      assert card.ref_number == 1
      assert card.position == 1
    end

    test "assigns sequential per-board refs and persists the bumped card_seq",
         %{board: board, stage: stage} do
      {:ok, card1} = Cards.create_card(stage, %{title: "First"})
      {:ok, card2} = Cards.create_card(stage, %{title: "Second"})
      {:ok, card3} = Cards.create_card(stage, %{title: "Third"})

      assert Enum.map([card1, card2, card3], & &1.ref_number) == [1, 2, 3]
      assert Cards.ref(board, card3) == "RLY-3"
      assert Repo.get!(Board, board.id).card_seq == 3
    end

    test "ref sequences are independent across boards", %{stage: stage} do
      other_board = insert(:board, key: "OPS")
      other_stage = insert(:stage, board: other_board, position: 1)

      {:ok, _a1} = Cards.create_card(stage, %{title: "A1"})
      {:ok, a2} = Cards.create_card(stage, %{title: "A2"})
      {:ok, b1} = Cards.create_card(other_stage, %{title: "B1"})

      assert a2.ref_number == 2
      assert b1.ref_number == 1
      assert Cards.ref(other_board, b1) == "OPS-1"
    end

    test "appends each new card at the bottom of its stage", %{board: board, stage: stage} do
      other_stage = insert(:stage, board: board, position: 2)

      {:ok, c1} = Cards.create_card(stage, %{title: "A"})
      {:ok, c2} = Cards.create_card(stage, %{title: "B"})
      {:ok, c3} = Cards.create_card(other_stage, %{title: "C"})

      assert c1.position == 1
      assert c2.position == 2
      assert c3.position == 1
      assert c3.ref_number == 3
    end

    test "returns an error changeset and leaves no ref gap on a blank title",
         %{board: board, stage: stage} do
      assert {:error, changeset} = Cards.create_card(stage, %{title: ""})

      assert "can't be blank" in errors_on(changeset).title
      assert Repo.aggregate(Card, :count) == 0
      assert Repo.get!(Board, board.id).card_seq == 0

      {:ok, card} = Cards.create_card(stage, %{title: "After the failure"})
      assert card.ref_number == 1
    end

    # Under the SQL sandbox all tasks funnel through the test's connection,
    # so this exercises interleaved allocation; the FOR UPDATE board-row
    # lock additionally serializes truly concurrent connections in prod.
    test "near-simultaneous creates get distinct, gap-free refs", %{stage: stage} do
      refs =
        1..8
        |> Task.async_stream(
          fn i ->
            {:ok, card} = Cards.create_card(stage, %{title: "Card #{i}"})
            card.ref_number
          end,
          max_concurrency: 8,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, ref_number} -> ref_number end)

      assert Enum.sort(refs) == Enum.to_list(1..8)
    end
  end

  describe "list_cards/1" do
    test "returns the board's cards ordered by stage then position", %{board: board, stage: stage} do
      stage2 = insert(:stage, board: board, position: 2)

      {:ok, a1} = Cards.create_card(stage, %{title: "A1"})
      {:ok, b1} = Cards.create_card(stage2, %{title: "B1"})
      {:ok, a2} = Cards.create_card(stage, %{title: "A2"})

      assert Enum.map(Cards.list_cards(board), & &1.id) == [a1.id, a2.id, b1.id]
    end

    test "orders within a stage by position, not insertion order", %{board: board, stage: stage} do
      second = insert(:card, stage: stage, title: "Second", position: 2, ref_number: 2)
      first = insert(:card, stage: stage, title: "First", position: 1, ref_number: 1)

      assert Enum.map(Cards.list_cards(board), & &1.id) == [first.id, second.id]
    end

    test "does not include another board's cards", %{board: board, stage: stage} do
      other_stage = insert(:stage)
      {:ok, _theirs} = Cards.create_card(other_stage, %{title: "Elsewhere"})
      {:ok, mine} = Cards.create_card(stage, %{title: "Mine"})

      assert Enum.map(Cards.list_cards(board), & &1.id) == [mine.id]
    end
  end
end
