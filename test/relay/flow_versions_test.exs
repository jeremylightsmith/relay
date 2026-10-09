defmodule Relay.FlowVersionsTest do
  use Relay.DataCase, async: true

  alias Relay.Flows

  # Two work stages ("Spec", "Code") a flow may sit on, between queue stages.
  defp board_with_stages do
    board = insert(:board)
    insert(:stage, board: board, name: "Next up")
    for name <- ["Spec", "Code"], do: insert(:stage, board: board, name: name, type: :work, category: :in_progress)
    insert(:stage, board: board, name: "Review")
    %{board: board}
  end

  defp stage_named(board, name), do: Enum.find(Relay.Boards.list_stages(board), &(&1.name == name))

  defp triggers(board), do: %{stage_id: stage_named(board, "Spec").id}

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

    test "a stage-only change saves without a version bump or new snapshot" do
      %{board: board} = board_with_stages()
      {:ok, flow} = Flows.create_flow(board, valid_attrs(board))
      other = stage_named(board, "Code")

      {:ok, saved} = Flows.save_definition(flow, %{stage_id: other.id})

      assert saved.version == 1
      assert saved.stage_id == other.id
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

    test "an enabled flow saved onto another flow's stage errors gracefully" do
      %{board: board} = board_with_stages()
      spec = stage_named(board, "Spec")
      code = stage_named(board, "Code")

      {:ok, rival} = Flows.create_flow(board, valid_attrs(board, %{key: "rival"}))
      {:ok, _rival} = Flows.enable_flow(rival)

      {:ok, flow} = Flows.create_flow(board, valid_attrs(board, %{key: "custom", stage_id: code.id}))
      {:ok, flow} = Flows.enable_flow(flow)

      assert {:error, changeset} = Flows.save_definition(flow, %{stage_id: spec.id})
      assert %{stage_id: ["stage already has flow `rival`"]} = errors_on(changeset)
      assert Repo.reload(flow).stage_id == code.id
    end
  end

  describe "mid_run_count/1" do
    test "counts only active runs on this flow, ignoring terminal and other-flow runs" do
      %{board: board} = board_with_stages()
      {:ok, flow} = Flows.create_flow(board, valid_attrs(board))

      {:ok, other} =
        Flows.create_flow(board, valid_attrs(board, %{key: "other", stage_id: stage_named(board, "Code").id}))

      insert(:run, flow_id: flow.id, status: :running)
      insert(:run, flow_id: flow.id, status: :parked)
      insert(:run, flow_id: flow.id, status: :done)
      insert(:run, flow_id: other.id, status: :running)

      assert Flows.mid_run_count(flow) == 2
    end

    test "returns 0 for a flow with no runs" do
      %{board: board} = board_with_stages()
      {:ok, flow} = Flows.create_flow(board, valid_attrs(board))
      assert Flows.mid_run_count(flow) == 0
    end
  end
end
