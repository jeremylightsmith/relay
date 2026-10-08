defmodule Relay.BoardsTypeConfigTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Flows
  alias Schemas.Stage

  setup do
    user = insert(:user)
    board = Boards.get_or_create_default_board(user)
    %{user: user, board: board}
  end

  test "a created stage takes its category's default type and no flow works in it", %{board: board} do
    {:ok, stage} = Boards.create_stage(board, :planning)
    assert stage.type == :planning
    refute Flows.ai_stage?(stage)
  end

  test "switching a stage to a passive type keeps the flow that works in it", %{board: board} do
    code = Enum.find(Boards.list_stages(board), &(&1.name == "Code"))
    assert Flows.ai_stage?(code)
    {:ok, updated} = Boards.update_stage(code, %{type: :review})
    assert updated.type == :review
    assert Flows.ai_stage?(updated)
  end

  describe "Cards.update_stage/2 (RE384)" do
    setup %{board: board} do
      code = Enum.find(Boards.list_stages(board), &(&1.name == "Code"))
      {:ok, card} = Cards.create_card(code, %{title: "WIP"})
      {:ok, card} = Cards.set_status(card, %{status: :working})
      %{code: code, card: card}
    end

    test "changing a stage's type re-snaps its resident cards", %{code: code, card: card} do
      assert {:ok, %Stage{type: :queue}} = Cards.update_stage(code, %{type: :queue})
      assert Relay.Repo.reload!(card).status == :ready
    end

    test "a change that keeps the type leaves cards alone", %{board: board, code: code, card: card} do
      :ok = Relay.Events.subscribe(board.id)
      card_id = card.id

      assert {:ok, %Stage{name: "Build"}} = Cards.update_stage(code, %{name: "Build"})
      assert Relay.Repo.reload!(card).status == :working
      refute_receive {:card_upserted, %{id: ^card_id}}
    end

    test "an invalid change returns the changeset", %{code: code} do
      assert {:error, %Ecto.Changeset{}} = Cards.update_stage(code, %{name: ""})
    end
  end

  test "previous_main_stage returns the nearest earlier main stage", %{board: board} do
    stages = Boards.list_stages(board)
    review = Enum.find(stages, &(&1.name == "Review"))
    code = Enum.find(stages, &(&1.name == "Code"))
    assert %Stage{id: id} = Boards.previous_main_stage(review)
    assert id == code.id

    backlog = Enum.find(stages, &(&1.name == "Backlog"))
    assert Boards.previous_main_stage(backlog) == nil
  end
end
