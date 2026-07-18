defmodule Relay.FlowsManagementTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Flows
  alias Schemas.Flow

  # A board whose stages resolve every default trigger, with the three
  # default flows seeded (mirrors Boards.create_board/2's shape — same
  # helper shape as Relay.FlowsSeedTest).
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

  describe "customized?/1" do
    test "a freshly seeded default flow is not customized" do
      board = seeded_board()
      refute Flows.customized?(Flows.get_flow!(board, "spec"))
    end

    test "changing a node marks the flow customized" do
      board = seeded_board()

      {:ok, flow} =
        Flows.update_flow(Flows.get_flow!(board, "spec"), %{
          nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref} --deep", max_retries: 1}],
          edges: [%{from: "start", to: "brainstorm"}, %{from: "brainstorm", to: "done", on: :succeeded}]
        })

      assert Flows.customized?(flow)
    end

    test "changing isolation marks the flow customized" do
      board = seeded_board()
      {:ok, flow} = Flows.update_flow(Flows.get_flow!(board, "spec"), %{isolation: :exclusive})
      assert Flows.customized?(flow)
    end

    test "trigger wiring never counts as customization" do
      board = seeded_board()
      other = insert(:stage, board: board, name: "Elsewhere", position: 20)
      {:ok, flow} = Flows.update_flow(Flows.get_flow!(board, "spec"), %{pulls_from_stage_id: other.id})
      refute Flows.customized?(flow)
    end

    test "a non-library key is always customized" do
      board = seeded_board()
      {:ok, copy} = Flows.duplicate_flow(Flows.get_flow!(board, "spec"))
      assert Flows.customized?(copy)
    end
  end

  describe "default_key?/1" do
    test "true for the shipped library keys, false otherwise" do
      assert Flows.default_key?("spec")
      assert Flows.default_key?("plan")
      assert Flows.default_key?("code")
      refute Flows.default_key?("spec-copy")
      refute Flows.default_key?("deploy")
    end
  end

  describe "duplicate_flow/1" do
    test "copies definition and triggers, disabled, under <key>-copy" do
      board = seeded_board()
      {:ok, original} = Flows.enable_flow(Flows.get_flow!(board, "spec"))

      assert {:ok, %Flow{} = copy} = Flows.duplicate_flow(original)
      assert copy.key == "spec-copy"
      refute copy.enabled
      assert copy.isolation == original.isolation
      assert copy.pulls_from_stage_id == original.pulls_from_stage_id
      assert copy.works_in_stage_id == original.works_in_stage_id
      assert copy.lands_on_stage_id == original.lands_on_stage_id

      assert Enum.map(copy.nodes, &{&1.key, &1.type, &1.run, &1.max_retries}) ==
               Enum.map(original.nodes, &{&1.key, &1.type, &1.run, &1.max_retries})

      assert Enum.map(copy.edges, &{&1.from, &1.to, &1.on, &1.max_loops}) ==
               Enum.map(original.edges, &{&1.from, &1.to, &1.on, &1.max_loops})
    end

    test "suffixes -2, -3, … when the copy key is taken" do
      board = seeded_board()
      original = Flows.get_flow!(board, "spec")
      {:ok, first} = Flows.duplicate_flow(original)
      assert first.key == "spec-copy"
      {:ok, second} = Flows.duplicate_flow(original)
      assert second.key == "spec-copy-2"
      {:ok, third} = Flows.duplicate_flow(original)
      assert third.key == "spec-copy-3"
    end
  end

  describe "reset_to_default/1" do
    test "restores nodes, edges, and isolation; triggers and enabled are untouched" do
      board = seeded_board()
      {:ok, flow} = Flows.enable_flow(Flows.get_flow!(board, "plan"))

      {:ok, flow} =
        Flows.update_flow(flow, %{
          isolation: :exclusive,
          nodes: [%{key: "write_plan", type: :agent, run: "custom", max_retries: 3}],
          edges: [%{from: "start", to: "write_plan"}, %{from: "write_plan", to: "done", on: :succeeded}]
        })

      assert Flows.customized?(flow)

      assert {:ok, %Flow{} = reset} = Flows.reset_to_default(flow)
      refute Flows.customized?(reset)
      assert reset.isolation == :shared_clean
      assert [%{key: "write_plan", run: "/write-plan {ref}", max_retries: 1}] = reset.nodes
      assert reset.enabled
      assert reset.pulls_from_stage_id == flow.pulls_from_stage_id
    end

    test "reset bumps the version and writes a new snapshot" do
      board = seeded_board()

      {:ok, flow} =
        Flows.update_flow(Flows.get_flow!(board, "plan"), %{
          nodes: [%{key: "write_plan", type: :agent, run: "custom", max_retries: 1}],
          edges: [%{from: "start", to: "write_plan"}, %{from: "write_plan", to: "done", on: :succeeded}]
        })

      before = flow.version
      {:ok, reset} = Flows.reset_to_default(flow)

      assert reset.version == before + 1
      assert %Schemas.FlowVersion{} = Flows.get_version(reset, reset.version)
    end

    test "returns {:error, :not_a_default} for a non-library key" do
      board = seeded_board()
      {:ok, copy} = Flows.duplicate_flow(Flows.get_flow!(board, "spec"))
      assert {:error, :not_a_default} = Flows.reset_to_default(copy)
    end
  end
end
