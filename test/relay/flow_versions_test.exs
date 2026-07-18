defmodule Relay.FlowVersionsTest do
  use Relay.DataCase, async: true

  alias Relay.Flows

  # Mirrors flows_test.exs helpers.
  defp board_with_stages do
    board = insert(:board)
    for name <- ["Next up", "Spec", "Spec:Review"], do: insert(:stage, board: board, name: name)
    %{board: board}
  end

  defp triggers(board) do
    [pulls, works, lands] = board |> Relay.Boards.list_stages() |> Enum.take(3)
    %{pulls_from_stage_id: pulls.id, works_in_stage_id: works.id, lands_on_stage_id: lands.id}
  end

  defp valid_attrs(board, extra \\ %{}) do
    Map.merge(
      %{
        key: "custom",
        isolation: :shared_clean,
        nodes: [%{key: "work", type: :agent, run: "go"}],
        edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
      },
      Map.merge(triggers(board), extra)
    )
  end

  describe "snapshots on create" do
    test "create_flow writes a v1 snapshot equal to the flow definition" do
      %{board: board} = board_with_stages()
      {:ok, flow} = Flows.create_flow(board, valid_attrs(board))

      assert flow.version == 1
      assert %Schemas.FlowVersion{version: 1} = snap = Flows.get_version(flow, 1)
      assert snap.isolation == flow.isolation
      assert Enum.map(snap.nodes, & &1.key) == Enum.map(flow.nodes, & &1.key)
      assert Enum.map(snap.edges, &{&1.from, &1.to}) == Enum.map(flow.edges, &{&1.from, &1.to})
    end
  end

  describe "save_definition/2" do
    test "a definition change bumps version and writes a new snapshot" do
      %{board: board} = board_with_stages()
      {:ok, flow} = Flows.create_flow(board, valid_attrs(board))

      {:ok, saved} =
        Flows.save_definition(flow, %{
          nodes: [%{key: "work", type: :agent, run: "changed"}],
          edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
        })

      assert saved.version == 2
      assert %Schemas.FlowVersion{} = Flows.get_version(saved, 1)
      assert %Schemas.FlowVersion{} = v2 = Flows.get_version(saved, 2)
      assert [%{run: "changed"}] = v2.nodes
    end

    test "a trigger-only change saves without a version bump or new snapshot" do
      %{board: board} = board_with_stages()
      {:ok, flow} = Flows.create_flow(board, valid_attrs(board))
      [_, _, _ | _] = stages = Relay.Boards.list_stages(board)
      other = List.last(stages)

      {:ok, saved} = Flows.save_definition(flow, %{lands_on_stage_id: other.id})

      assert saved.version == 1
      assert saved.lands_on_stage_id == other.id
      assert Flows.get_version(saved, 2) == nil
    end

    test "an invalid definition is rejected with no bump and no snapshot (never errors after)" do
      %{board: board} = board_with_stages()
      {:ok, flow} = Flows.create_flow(board, valid_attrs(board))

      assert {:error, changeset} =
               Flows.save_definition(flow, %{edges: [%{from: "start", to: "ghost"}]})

      assert ~s(edge to "ghost" does not name a node) in errors_on(changeset).edges
      assert Repo.reload(flow).version == 1
      assert Flows.get_version(flow, 2) == nil
    end

    test "an enabled flow saved to pull from another enabled flow's stage errors gracefully" do
      %{board: board} = board_with_stages()
      [pulls, other_pulls, _lands] = Relay.Boards.list_stages(board)

      {:ok, rival} = Flows.create_flow(board, valid_attrs(board, %{key: "rival"}))
      {:ok, _rival} = Flows.enable_flow(rival)

      {:ok, flow} =
        Flows.create_flow(board, valid_attrs(board, %{key: "custom", pulls_from_stage_id: other_pulls.id}))

      {:ok, flow} = Flows.enable_flow(flow)

      assert {:error, changeset} = Flows.save_definition(flow, %{pulls_from_stage_id: pulls.id})

      assert %{pulls_from_stage_id: ["another enabled flow already pulls from this stage"]} =
               errors_on(changeset)

      assert Repo.reload(flow).pulls_from_stage_id == other_pulls.id
    end
  end

  describe "mid_run_count/1" do
    test "returns 0 until the Runs schema exists" do
      %{board: board} = board_with_stages()
      {:ok, flow} = Flows.create_flow(board, valid_attrs(board))
      assert Flows.mid_run_count(flow) == 0
    end
  end
end
