defmodule Relay.BoardsStageConfigTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Repo
  alias Schemas.CardOwner

  defp seeded_board do
    Boards.get_or_create_default_board(insert(:user))
  end

  # Seeded main-stage order: Backlog, Spec | Plan, Code, Review, Deploy | Done
  defp main_names(board) do
    board
    |> Boards.list_stages()
    |> Enum.filter(&(&1.lane == :main))
    |> Enum.map(& &1.name)
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

  defp categories(board) do
    board
    |> Boards.list_stages()
    |> Enum.filter(&(&1.lane == :main))
    |> Enum.map(& &1.category)
  end

  describe "update_stage/2" do
    test "persists name, description, and owner" do
      board = seeded_board()
      stage = stage_named(board, "Backlog")

      assert {:ok, updated} =
               Boards.update_stage(stage, %{
                 name: "Inbox",
                 description: "Raw ideas land here",
                 owner: :ai
               })

      assert updated.name == "Inbox"

      reloaded = Boards.get_stage(board, stage.id)
      assert reloaded.name == "Inbox"
      assert reloaded.description == "Raw ideas land here"
      assert reloaded.owner == :ai
    end

    test "rejects a blank name and persists nothing" do
      board = seeded_board()
      stage = stage_named(board, "Backlog")

      assert {:error, %Ecto.Changeset{}} = Boards.update_stage(stage, %{name: ""})
      assert Boards.get_stage(board, stage.id).name == "Backlog"
    end

    test "changing the stage owner never touches card owner rows" do
      board = seeded_board()
      stage = stage_named(board, "Code")
      card = insert(:card, stage: stage)
      human = insert(:user)
      owner_row = insert(:card_owner, card: card, user: human)

      assert {:ok, %{owner: :human}} = Boards.update_stage(stage, %{owner: :human})

      assert [%CardOwner{} = row] = Repo.all(CardOwner)
      assert row.id == owner_row.id
      assert row.actor_type == :user
      assert row.user_id == human.id
    end
  end

  describe "reorder_stage/2" do
    test ":up swaps with the stage above within a category" do
      board = seeded_board()

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Spec"), :up)
      assert moved.category == :unstarted
      assert main_names(board) == ["Spec", "Backlog", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test ":down across a boundary adopts the next category and leaves the neighbour untouched" do
      board = seeded_board()
      plan = stage_named(board, "Plan")

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Spec"), :down)

      # Spec alone crosses the band, landing at the TOP of Planning: the flat
      # board order is unchanged. Plan — which the old bidirectional swap
      # dragged up into :unstarted (the reported bug) — stays put.
      assert moved.category == :planning
      assert Boards.get_stage(board, plan.id).category == :planning
      assert main_names(board) == ["Backlog", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]

      assert categories(board) ==
               [:unstarted, :planning, :planning, :in_progress, :in_progress, :in_progress, :complete]
    end

    test ":up across a boundary adopts the previous category and leaves the neighbour untouched" do
      board = seeded_board()
      spec = stage_named(board, "Spec")

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Plan"), :up)

      # Plan lands at the BOTTOM of Unstarted; Spec keeps its category.
      assert moved.category == :unstarted
      assert Boards.get_stage(board, spec.id).category == :unstarted
      assert main_names(board) == ["Backlog", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test ":down into an empty adjacent category lands there instead of skipping past it" do
      board = seeded_board()
      {:ok, _} = Boards.delete_stage(stage_named(board, "Plan"))

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Spec"), :down)
      assert moved.category == :planning
      assert main_names(board) == ["Backlog", "Spec", "Code", "Review", "Deploy", "Done"]

      # A second :down crosses on into In progress, again without touching Code.
      assert {:ok, again} = Boards.reorder_stage(Boards.get_stage(board, moved.id), :down)
      assert again.category == :in_progress
      assert Boards.get_stage(board, stage_named(board, "Code").id).category == :in_progress
    end

    test ":up into an empty adjacent category lands there instead of skipping past it" do
      board = seeded_board()
      {:ok, _} = Boards.delete_stage(stage_named(board, "Plan"))

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Code"), :up)
      assert moved.category == :planning
      assert main_names(board) == ["Backlog", "Spec", "Code", "Review", "Deploy", "Done"]
    end

    test "the first and last categories no-op at the board's edges" do
      board = seeded_board()

      assert {:ok, %{position: 1, category: :unstarted}} =
               Boards.reorder_stage(stage_named(board, "Backlog"), :up)

      assert {:ok, %{name: "Done", category: :complete}} =
               Boards.reorder_stage(stage_named(board, "Done"), :down)

      assert main_names(board) == ["Backlog", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test "swapping skips over sub-lane children" do
      board = seeded_board()
      {:ok, _child} = Boards.enable_lane(stage_named(board, "Code"), :review)

      assert {:ok, _moved} = Boards.reorder_stage(stage_named(board, "Review"), :up)
      assert main_names(board) == ["Backlog", "Spec", "Plan", "Review", "Code", "Deploy", "Done"]
    end

    test "reordering never touches card owners and keeps main positions contiguous" do
      board = seeded_board()
      code = stage_named(board, "Code")
      card = insert(:card, stage: code)
      owner_row = insert(:card_owner, card: card, user: insert(:user))

      {:ok, _} = Boards.reorder_stage(stage_named(board, "Spec"), :down)
      {:ok, _} = Boards.reorder_stage(Boards.get_stage(board, code.id), :up)

      assert [%CardOwner{} = row] = Repo.all(CardOwner)
      assert row.id == owner_row.id

      positions =
        board |> Boards.list_stages() |> Enum.filter(&(&1.lane == :main)) |> Enum.map(& &1.position)

      assert positions == Enum.to_list(1..7)
    end
  end

  describe "create_stage/2" do
    test "appends a default stage at the end of the category" do
      board = seeded_board()

      assert {:ok, stage} = Boards.create_stage(board, :unstarted)
      assert stage.name == "New stage"
      assert stage.owner == :human
      assert stage.category == :unstarted
      assert stage.lane == :main

      assert main_names(board) ==
               ["Backlog", "Spec", "New stage", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test "appends to a category that has become empty" do
      board = seeded_board()
      {:ok, _} = Boards.delete_stage(stage_named(board, "Done"))

      assert {:ok, stage} = Boards.create_stage(board, :complete)
      assert stage.category == :complete
      assert main_names(board) == ["Backlog", "Spec", "Plan", "Code", "Review", "Deploy", "New stage"]
    end

    test "keeps positions unique across mains and sub-lane children" do
      board = seeded_board()
      {:ok, _child} = Boards.enable_lane(stage_named(board, "Code"), :done)

      assert {:ok, _stage} = Boards.create_stage(board, :in_progress)

      positions = board |> Boards.list_stages() |> Enum.map(& &1.position)
      assert positions == Enum.uniq(positions)
    end
  end

  describe "delete_stage/1" do
    test "deletes an empty stage together with its sub-lane children" do
      board = seeded_board()
      code = stage_named(board, "Code")
      {:ok, child} = Boards.enable_lane(code, :review)

      assert {:ok, _deleted} = Boards.delete_stage(code)
      assert Boards.get_stage(board, code.id) == nil
      assert Boards.get_stage(board, child.id) == nil
    end

    test "refuses when the main lane holds cards" do
      board = seeded_board()
      code = stage_named(board, "Code")
      insert(:card, stage: code)

      assert {:error, :not_empty} = Boards.delete_stage(code)
      assert Boards.get_stage(board, code.id)
    end

    test "refuses when a sub-lane holds cards" do
      board = seeded_board()
      code = stage_named(board, "Code")
      {:ok, child} = Boards.enable_lane(code, :review)
      insert(:card, stage: child)

      assert {:error, :not_empty} = Boards.delete_stage(code)
      assert Boards.get_stage(board, code.id)
      assert Boards.get_stage(board, child.id)
    end

    test "refuses to delete the board's only main stage" do
      board = insert(:board)
      only = insert(:stage, board: board, position: 1)

      assert {:error, :last_stage} = Boards.delete_stage(only)
    end
  end

  describe "broadcasts" do
    test "each successful mutation broadcasts {:stages_changed, board_id}" do
      board = seeded_board()
      board_id = board.id
      :ok = Relay.Events.subscribe(board_id)
      backlog = stage_named(board, "Backlog")

      {:ok, _} = Boards.update_stage(backlog, %{name: "Inbox"})
      assert_receive {:stages_changed, ^board_id}

      {:ok, _} = Boards.reorder_stage(Boards.get_stage(board, backlog.id), :down)
      assert_receive {:stages_changed, ^board_id}

      {:ok, created} = Boards.create_stage(board, :complete)
      assert_receive {:stages_changed, ^board_id}

      {:ok, _} = Boards.delete_stage(created)
      assert_receive {:stages_changed, ^board_id}
    end

    test "guarded failures and edge no-ops stay silent" do
      board = seeded_board()
      :ok = Relay.Events.subscribe(board.id)
      backlog = stage_named(board, "Backlog")
      insert(:card, stage: backlog)

      {:error, :not_empty} = Boards.delete_stage(backlog)
      {:error, %Ecto.Changeset{}} = Boards.update_stage(backlog, %{name: ""})
      {:ok, _} = Boards.reorder_stage(backlog, :up)

      refute_receive {:stages_changed, _board_id}
    end
  end
end
