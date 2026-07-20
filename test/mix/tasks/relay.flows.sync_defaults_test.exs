defmodule Mix.Tasks.Relay.Flows.SyncDefaultsTest do
  use Relay.DataCase, async: false

  import ExUnit.CaptureIO

  alias Relay.Boards
  alias Relay.Flows

  defp seeded_board do
    board = insert(:board)
    insert(:stage, board: board, name: "Next up", position: 1)
    spec = insert(:stage, board: board, name: "Spec", category: :planning, type: :planning, position: 2)
    plan = insert(:stage, board: board, name: "Plan", category: :planning, type: :planning, position: 3)
    insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 4)
    insert(:stage, board: board, name: "Review", category: :in_progress, type: :review, position: 5)
    {:ok, _} = Boards.enable_lane(spec, :review)
    {:ok, _} = Boards.enable_lane(spec, :done)
    {:ok, _} = Boards.enable_lane(plan, :done)
    :ok = Flows.seed_default_flows!(board)
    board
  end

  test "the task upgrades a drifted v1 flow and prints a summary" do
    board = seeded_board()

    {:ok, _} =
      Flows.update_flow(Flows.get_flow!(board, "code"), %{
        nodes: [%{key: "branch", type: :shell, run: "true"}],
        edges: [%{from: "start", to: "branch"}, %{from: "branch", to: "done", on: :succeeded}]
      })

    out = capture_io(fn -> Mix.Tasks.Relay.Flows.SyncDefaults.run([]) end)

    assert out =~ "upgraded="
    refute Flows.customized?(Flows.get_flow!(board, "code"))
  end
end
