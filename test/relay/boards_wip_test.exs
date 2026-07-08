defmodule Relay.BoardsWipTest do
  use Relay.DataCase, async: true

  alias Relay.Boards

  defp seeded_board, do: Boards.get_or_create_default_board(insert(:user))

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

  describe "wip_limit through update_stage/2" do
    test "persists a positive limit" do
      board = seeded_board()
      code = stage_named(board, "Code")

      assert {:ok, %{wip_limit: 3}} = Boards.update_stage(code, %{wip_limit: 3})
      assert Boards.get_stage(board, code.id).wip_limit == 3
    end

    test "nil clears an existing limit" do
      board = seeded_board()
      code = stage_named(board, "Code")
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})

      assert {:ok, %{wip_limit: nil}} =
               Boards.update_stage(Boards.get_stage(board, code.id), %{wip_limit: nil})

      assert Boards.get_stage(board, code.id).wip_limit == nil
    end

    test "rejects zero and negative limits, persisting nothing" do
      board = seeded_board()
      code = stage_named(board, "Code")

      assert {:error, changeset} = Boards.update_stage(code, %{wip_limit: 0})
      assert %{wip_limit: ["must be greater than 0"]} = errors_on(changeset)
      assert {:error, %Ecto.Changeset{}} = Boards.update_stage(code, %{wip_limit: -2})
      assert Boards.get_stage(board, code.id).wip_limit == nil
    end

    test "a successful limit change broadcasts {:stages_changed, board_id}" do
      board = seeded_board()
      board_id = board.id
      :ok = Relay.Events.subscribe(board_id)

      {:ok, _stage} = Boards.update_stage(stage_named(board, "Code"), %{wip_limit: 3})
      assert_receive {:stages_changed, ^board_id}
    end
  end
end
