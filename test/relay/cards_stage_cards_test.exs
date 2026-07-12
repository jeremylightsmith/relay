defmodule Relay.CardsStageCardsTest do
  use Relay.DataCase, async: true

  alias Relay.Cards
  alias Schemas.Card
  alias Schemas.CardOwner

  setup do
    board = insert(:board, key: "RLY")
    stage = insert(:stage, board: board, position: 1)
    other = insert(:stage, board: board, position: 2)
    %{board: board, stage: stage, other: other}
  end

  describe "list_stage_cards/2" do
    test "returns at most `limit` cards", %{stage: stage} do
      for i <- 1..10 do
        insert(:card,
          stage: stage,
          updated_at: DateTime.add(~U[2026-07-01 00:00:00Z], i, :second)
        )
      end

      assert length(Cards.list_stage_cards(stage, 8)) == 8
    end

    test "orders newest-first by updated_at then id", %{stage: stage} do
      older = insert(:card, stage: stage, title: "older", updated_at: ~U[2026-07-01 00:00:00Z])
      newer = insert(:card, stage: stage, title: "newer", updated_at: ~U[2026-07-02 00:00:00Z])

      assert [first, second] = Cards.list_stage_cards(stage, 8)
      assert first.id == newer.id
      assert second.id == older.id
    end

    test "is scoped to the one stage", %{stage: stage, other: other} do
      mine = insert(:card, stage: stage)
      _theirs = insert(:card, stage: other)

      assert [%Card{id: id}] = Cards.list_stage_cards(stage, 8)
      assert id == mine.id
    end

    test "excludes archived cards", %{stage: stage} do
      _archived = insert(:card, stage: stage, archived_at: ~U[2026-07-01 00:00:00Z])
      live = insert(:card, stage: stage)

      assert [%Card{id: id}] = Cards.list_stage_cards(stage, 8)
      assert id == live.id
    end

    test "preloads owners and sub_tasks", %{stage: stage} do
      card = insert(:card, stage: stage)
      insert(:card_owner, card: card)

      assert [loaded] = Cards.list_stage_cards(stage, 8)
      assert [%CardOwner{}] = loaded.owners
      assert is_list(loaded.sub_tasks)
    end
  end
end
