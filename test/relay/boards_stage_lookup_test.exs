defmodule Relay.BoardsStageLookupTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Schemas.Stage

  describe "list_stages/1" do
    test "returns the board's stages in position order" do
      board = insert(:board)
      insert(:stage, board: board, name: "Two", position: 2)
      insert(:stage, board: board, name: "One", position: 1)
      _other = insert(:stage, name: "Foreign", position: 1)

      names = board |> Boards.list_stages() |> Enum.map(& &1.name)
      assert names == ["One", "Two"]
    end

    test "puts each substage directly under its parent, not at the end" do
      board = insert(:board)
      insert(:stage, board: board, name: "One", position: 1)
      two = insert(:stage, board: board, name: "Two", position: 2)
      insert(:stage, board: board, name: "Three", position: 3)
      {:ok, review} = Boards.enable_lane(two, :review)
      assert review.position == 4

      names = board |> Boards.list_stages() |> Enum.map(& &1.name)
      assert names == ["One", "Two", "Two:Review", "Three"]
    end
  end

  describe "order_stages/1" do
    defp stage(id, name, position, parent_id \\ nil, type \\ :work) do
      %Stage{id: id, name: name, position: position, parent_id: parent_id, type: type}
    end

    test "orders mains by position, each followed by its Review then Done substage" do
      stages = [
        stage(1, "A", 1),
        stage(2, "B", 2),
        stage(3, "C", 3),
        stage(4, "B:Done", 4, 2, :done),
        stage(5, "A:Review", 5, 1, :review),
        stage(6, "B:Review", 6, 2, :review)
      ]

      expected = ["A", "A:Review", "B", "B:Review", "B:Done", "C"]

      for permutation <- [stages, Enum.reverse(stages), Enum.shuffle(stages), Enum.shuffle(stages)] do
        assert permutation |> Boards.order_stages() |> Enum.map(& &1.name) == expected
      end
    end

    test "returns [] for []" do
      assert Boards.order_stages([]) == []
    end

    test "appends a child whose parent is not in the list, dropping nothing" do
      stages = [stage(10, "X:Review", 2, 999, :review), stage(1, "A", 1)]

      assert stages |> Boards.order_stages() |> Enum.map(& &1.name) == ["A", "X:Review"]
    end
  end

  describe "get_stage/2" do
    test "returns a stage on the board, nil for another board's stage" do
      board = insert(:board)
      stage = insert(:stage, board: board)
      foreign = insert(:stage)

      assert %Stage{id: id} = Boards.get_stage(board, stage.id)
      assert id == stage.id
      assert Boards.get_stage(board, foreign.id) == nil
      assert Boards.get_stage(board, -1) == nil
    end
  end
end
