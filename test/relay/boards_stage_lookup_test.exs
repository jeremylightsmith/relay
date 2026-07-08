defmodule Relay.BoardsStageLookupTest do
  use Relay.DataCase, async: true

  alias Relay.Boards

  describe "list_stages/1" do
    test "returns the board's stages in position order" do
      board = insert(:board)
      insert(:stage, board: board, name: "Two", position: 2)
      insert(:stage, board: board, name: "One", position: 1)
      _other = insert(:stage, name: "Foreign", position: 1)

      names = board |> Boards.list_stages() |> Enum.map(& &1.name)
      assert names == ["One", "Two"]
    end
  end

  describe "get_stage/2" do
    test "returns a stage on the board, nil for another board's stage" do
      board = insert(:board)
      stage = insert(:stage, board: board)
      foreign = insert(:stage)

      assert %Schemas.Stage{id: id} = Boards.get_stage(board, stage.id)
      assert id == stage.id
      assert Boards.get_stage(board, foreign.id) == nil
      assert Boards.get_stage(board, -1) == nil
    end
  end
end
