defmodule Relay.CardsTest do
  use Relay.DataCase, async: true

  alias Relay.Cards
  alias Schemas.Board
  alias Schemas.Card

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

  describe "update_card/2" do
    test "updates title, description, and tag", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Before"})

      assert {:ok, %Card{} = updated} =
               Cards.update_card(card, %{
                 title: "After",
                 description: "Line one\n\nLine two",
                 tag: "infra"
               })

      assert updated.title == "After"
      assert updated.description == "Line one\n\nLine two"
      assert updated.tag == "infra"
      assert Repo.get!(Card, card.id).description == "Line one\n\nLine two"
    end

    test "rejects a blank title and persists nothing", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Keep me"})

      assert {:error, changeset} = Cards.update_card(card, %{title: ""})
      assert "can't be blank" in errors_on(changeset).title
      assert Repo.get!(Card, card.id).title == "Keep me"
    end

    test "clearing the description stores nil", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})
      {:ok, card} = Cards.update_card(card, %{description: "something"})

      assert {:ok, updated} = Cards.update_card(card, %{description: ""})
      assert updated.description == nil
    end

    test "never changes board_id, stage_id, position, or ref_number", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Pinned"})

      assert {:ok, updated} =
               Cards.update_card(card, %{
                 title: "Still pinned",
                 board_id: card.board_id + 1,
                 stage_id: card.stage_id + 1,
                 position: 99,
                 ref_number: 99
               })

      assert updated.board_id == card.board_id
      assert updated.stage_id == card.stage_id
      assert updated.position == card.position
      assert updated.ref_number == card.ref_number
    end
  end

  describe "get_card_by_ref/2" do
    test "returns the card the ref points at on the board", %{board: board, stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Find me"})

      assert %Card{id: id} = Cards.get_card_by_ref(board, "RLY-1")
      assert id == card.id
    end

    test "returns nil for an unknown ref number", %{board: board} do
      assert Cards.get_card_by_ref(board, "RLY-99") == nil
    end

    test "returns nil for malformed or foreign-key refs", %{board: board, stage: stage} do
      {:ok, _card} = Cards.create_card(stage, %{title: "Here"})

      for ref <- ["", "RLY", "RLY-", "RLY-abc", "RLY-1extra", "RLY--1", "RLY-0", "OPS-1", "rly-1"] do
        assert Cards.get_card_by_ref(board, ref) == nil, "expected nil for #{inspect(ref)}"
      end
    end

    test "never returns another board's card", %{board: board} do
      other_stage = insert(:stage)

      {:ok, _theirs} = Cards.create_card(other_stage, %{title: "Theirs"})

      assert Cards.get_card_by_ref(board, "RLY-1") == nil
    end
  end

  describe "move_card/3" do
    setup %{board: board} do
      %{target: insert(:stage, board: board, position: 2)}
    end

    test "moves a card to another stage at the index, reindexing the target gap-free",
         %{board: board, stage: stage, target: target} do
      # Gappy target positions prove the whole target stage is re-indexed.
      a = insert(:card, stage: target, title: "A", position: 3, ref_number: 10)
      b = insert(:card, stage: target, title: "B", position: 7, ref_number: 11)
      {:ok, card} = Cards.create_card(stage, %{title: "Mover"})

      assert {:ok, %Card{} = moved} = Cards.move_card(card, target, 1)

      assert moved.stage_id == target.id
      assert moved.position == 2
      assert stage_card_ids(board, target) == [a.id, moved.id, b.id]
      assert stage_positions(board, target) == [1, 2, 3]
    end

    test "index 0 inserts at the top of the target stage",
         %{board: board, stage: stage, target: target} do
      existing = insert(:card, stage: target, title: "Existing", position: 1, ref_number: 10)
      {:ok, card} = Cards.create_card(stage, %{title: "Mover"})

      assert {:ok, moved} = Cards.move_card(card, target, 0)

      assert stage_card_ids(board, target) == [moved.id, existing.id]
      assert stage_positions(board, target) == [1, 2]
    end

    test "an index past the end and a negative index clamp into range",
         %{board: board, stage: stage, target: target} do
      existing = insert(:card, stage: target, title: "Existing", position: 1, ref_number: 10)
      {:ok, card_a} = Cards.create_card(stage, %{title: "Bottom"})
      {:ok, card_b} = Cards.create_card(stage, %{title: "Top"})

      {:ok, bottom} = Cards.move_card(card_a, target, 99)
      {:ok, top} = Cards.move_card(card_b, target, -5)

      assert stage_card_ids(board, target) == [top.id, existing.id, bottom.id]
      assert stage_positions(board, target) == [1, 2, 3]
    end

    test "reorders within the same stage keeping positions contiguous",
         %{board: board, stage: stage} do
      {:ok, first} = Cards.create_card(stage, %{title: "First"})
      {:ok, second} = Cards.create_card(stage, %{title: "Second"})
      {:ok, third} = Cards.create_card(stage, %{title: "Third"})

      assert {:ok, moved} = Cards.move_card(third, stage, 0)

      assert moved.stage_id == stage.id
      assert stage_card_ids(board, stage) == [moved.id, first.id, second.id]
      assert stage_positions(board, stage) == [1, 2, 3]
    end

    test "moving into an empty stage lands at position 1", %{stage: stage, target: target} do
      {:ok, card} = Cards.create_card(stage, %{title: "Loner"})

      assert {:ok, moved} = Cards.move_card(card, target, 0)

      assert moved.stage_id == target.id
      assert moved.position == 1
    end

    test "refuses a target stage on another board", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Stay"})
      foreign_stage = insert(:stage)

      assert_raise FunctionClauseError, fn -> Cards.move_card(card, foreign_stage, 0) end
      assert Repo.get!(Card, card.id).stage_id == stage.id
    end
  end

  defp stage_card_ids(board, stage) do
    board |> Cards.list_cards() |> Enum.filter(&(&1.stage_id == stage.id)) |> Enum.map(& &1.id)
  end

  defp stage_positions(board, stage) do
    board
    |> Cards.list_cards()
    |> Enum.filter(&(&1.stage_id == stage.id))
    |> Enum.map(& &1.position)
  end
end
