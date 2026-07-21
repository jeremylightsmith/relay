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

  describe "diff_from_default/1" do
    test "nil for a non-library key" do
      board = seeded_board()
      {:ok, copy} = Flows.duplicate_flow(Flows.get_flow!(board, "spec"))
      assert Flows.diff_from_default(copy) == nil
    end

    test "empty diff for a freshly seeded default flow" do
      board = seeded_board()
      flow = Flows.get_flow!(board, "spec")

      assert Flows.diff_from_default(flow) == %{
               nodes: %{added: [], removed: [], changed: []},
               edges: %{added: [], removed: []}
             }
    end

    test "a changed node field is reported under changed, keyed by node key" do
      board = seeded_board()

      {:ok, flow} =
        Flows.update_flow(Flows.get_flow!(board, "spec"), %{
          nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref} --deep", max_retries: 2}],
          edges: [
            %{from: "start", to: "brainstorm"},
            %{from: "brainstorm", to: "done", on: :succeeded},
            %{from: "brainstorm", to: "needs_input", on: :failed}
          ]
        })

      assert Flows.diff_from_default(flow) == %{
               nodes: %{added: [], removed: [], changed: [%{key: "brainstorm", fields: [:run, :max_retries]}]},
               edges: %{added: [], removed: []}
             }
    end

    test "added/removed nodes and edges when the graph is restructured" do
      board = seeded_board()

      {:ok, flow} =
        Flows.update_flow(Flows.get_flow!(board, "plan"), %{
          nodes: [
            %{key: "gather", type: :agent, run: "gather context", max_retries: 1},
            %{key: "draft", type: :agent, run: "/write-plan {ref}", max_retries: 1}
          ],
          edges: [
            %{from: "start", to: "gather"},
            %{from: "gather", to: "draft", on: :succeeded},
            %{from: "draft", to: "done", on: :succeeded}
          ]
        })

      assert Flows.diff_from_default(flow) == %{
               nodes: %{added: ["draft", "gather"], removed: ["write_plan"], changed: []},
               edges: %{
                 added: [
                   {"draft", "done", :succeeded},
                   {"gather", "draft", :succeeded},
                   {"start", "gather", nil}
                 ],
                 removed: [
                   {"start", "write_plan", nil},
                   {"write_plan", "done", :succeeded},
                   {"write_plan", "needs_input", :failed}
                 ]
               }
             }
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

  describe "create-from-scratch (RLY-158)" do
    setup do
      %{board: seeded_board()}
    end

    test "a skeleton flow with all three triggers is created disabled at v1", %{board: board} do
      spec = Flows.get_flow!(board, "spec")

      assert {:ok, flow} =
               Flows.create_flow(board, %{
                 key: "deploy-gate",
                 isolation: :shared_clean,
                 pulls_from_stage_id: spec.pulls_from_stage_id,
                 works_in_stage_id: spec.works_in_stage_id,
                 lands_on_stage_id: spec.lands_on_stage_id,
                 nodes: [],
                 edges: [%{from: "start", to: "done"}]
               })

      assert flow.key == "deploy-gate"
      refute flow.enabled
      assert flow.version == 1
      assert flow.nodes == []
      assert [%{from: "start", to: "done", on: nil}] = flow.edges
    end

    test "a malformed key is rejected with the format message", %{board: board} do
      assert {:error, changeset} =
               Flows.create_flow(board, %{
                 key: "Deploy Gate!",
                 isolation: :shared_clean,
                 nodes: [],
                 edges: [%{from: "start", to: "done"}]
               })

      assert "must be lowercase letters, numbers and dashes" in errors_on(changeset).key
    end

    test "the shipped and generated key shapes all pass the format validation", %{board: board} do
      for key <- ~w(spec plan code spec-copy spec-copy-2 new-flow new-flow-2 deploy-gate a1) do
        assert {:ok, _} =
                 Flows.create_flow(board, %{
                   key: key <> "-x",
                   isolation: :shared_clean,
                   nodes: [],
                   edges: [%{from: "start", to: "done"}]
                 })
      end
    end

    test "a duplicate key on the same board is rejected", %{board: board} do
      assert {:error, changeset} =
               Flows.create_flow(board, %{
                 key: "spec",
                 isolation: :shared_clean,
                 nodes: [],
                 edges: [%{from: "start", to: "done"}]
               })

      assert errors_on(changeset).key != []
    end

    test "unique_key/2 walks past taken keys", %{board: board} do
      assert Flows.unique_key(board, "new-flow") == "new-flow"
      assert Flows.unique_key(board, "spec") == "spec-2"

      {:ok, _} =
        Flows.create_flow(board, %{
          key: "spec-2",
          isolation: :shared_clean,
          nodes: [],
          edges: [%{from: "start", to: "done"}]
        })

      assert Flows.unique_key(board, "spec") == "spec-3"
    end

    test "duplicate_flow/1 still suffixes -copy then -copy-2", %{board: board} do
      spec = Flows.get_flow!(board, "spec")

      assert {:ok, first} = Flows.duplicate_flow(spec)
      assert first.key == "spec-copy"

      assert {:ok, second} = Flows.duplicate_flow(spec)
      assert second.key == "spec-copy-2"
    end

    test "creating on an already-enabled stage succeeds but enabling is refused", %{board: board} do
      spec = Flows.get_flow!(board, "spec")
      {:ok, spec} = Flows.enable_flow(spec)
      assert spec.enabled

      assert {:ok, rival} =
               Flows.create_flow(board, %{
                 key: "spec-rival",
                 isolation: :shared_clean,
                 pulls_from_stage_id: spec.pulls_from_stage_id,
                 works_in_stage_id: spec.works_in_stage_id,
                 lands_on_stage_id: spec.lands_on_stage_id,
                 nodes: [%{key: "n", type: :agent, run: "x"}],
                 edges: [%{from: "start", to: "n"}, %{from: "n", to: "done", on: :succeeded}]
               })

      refute rival.enabled

      assert {:error, changeset} = Flows.enable_flow(rival)

      assert "another enabled flow already pulls from this stage" in errors_on(changeset).pulls_from_stage_id

      refute Flows.get_flow!(board, "spec-rival").enabled
      assert Enum.map(Flows.list_enabled_flows(board), & &1.key) == ["spec"]
    end
  end

  describe "sync_defaults!/0" do
    # A minimal valid graph for the "code" key that LACKS the sync nodes — stands in for an old
    # pre-RLY-192 default. update_flow/2 does not bump version, so this stays at v1.
    defp stale_code_attrs do
      %{
        nodes: [%{key: "branch", type: :shell, run: "true"}],
        edges: [%{from: "start", to: "branch"}, %{from: "branch", to: "done", on: :succeeded}]
      }
    end

    test "upgrades a v1 flow that drifted from the library, reaching the existing board" do
      board = seeded_board()
      {:ok, stale} = Flows.update_flow(Flows.get_flow!(board, "code"), stale_code_attrs())
      assert stale.version == 1
      assert Flows.customized?(stale)

      summary = Flows.sync_defaults!()

      upgraded = Flows.get_flow!(board, "code")
      keys = MapSet.new(upgraded.nodes, & &1.key)
      assert MapSet.subset?(MapSet.new(~w(sync sync_fix resync resync_fix reverify)), keys)
      refute Flows.customized?(upgraded)
      assert {board.id, "code"} in summary.upgraded
    end

    test "upgrade keeps the flow at version 1 so a repeat sync still upgrades it" do
      board = seeded_board()
      {:ok, _} = Flows.update_flow(Flows.get_flow!(board, "code"), stale_code_attrs())

      Flows.sync_defaults!()
      once = Flows.get_flow!(board, "code")
      assert once.version == 1

      # Drift again (still v1) and re-sync: the version==1 gate must still fire.
      {:ok, _} = Flows.update_flow(once, stale_code_attrs())
      summary = Flows.sync_defaults!()
      twice = Flows.get_flow!(board, "code")
      assert twice.version == 1
      refute Flows.customized?(twice)
      assert {board.id, "code"} in summary.upgraded
    end

    test "preserves a hand-customized (version > 1) flow" do
      board = seeded_board()
      {:ok, edited} = Flows.save_definition(Flows.get_flow!(board, "code"), stale_code_attrs())
      assert edited.version == 2

      summary = Flows.sync_defaults!()

      after_sync = Flows.get_flow!(board, "code")
      assert after_sync.version == 2
      assert [%{key: "branch"}] = after_sync.nodes
      assert {board.id, "code"} in summary.skipped
      refute {board.id, "code"} in summary.upgraded
    end

    test "leaves an already-current v1 flow untouched and reports it unchanged" do
      board = seeded_board()
      flow = Flows.get_flow!(board, "code")
      refute Flows.customized?(flow)

      summary = Flows.sync_defaults!()

      after_sync = Flows.get_flow!(board, "code")
      assert after_sync.version == 1
      assert {board.id, "code"} in summary.unchanged
      refute {board.id, "code"} in summary.upgraded
    end

    test "refreshes the v1 snapshot to match the upgraded definition" do
      board = seeded_board()
      {:ok, _} = Flows.update_flow(Flows.get_flow!(board, "code"), stale_code_attrs())

      Flows.sync_defaults!()

      upgraded = Flows.get_flow!(board, "code")
      snap = Flows.get_version(upgraded, 1)
      assert MapSet.new(snap.nodes, & &1.key) == MapSet.new(upgraded.nodes, & &1.key)
    end
  end
end
