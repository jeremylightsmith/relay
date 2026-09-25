defmodule Relay.ValueStreamFlowTest do
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Relay.ValueStream

  defp t0_ago(ago_s), do: DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -ago_s, :second)

  # A Code-flow-shaped graph. fix_findings and final_fix have no authored role, so their Fix role
  # is derived from their failed-only inbound edges; resync is AUTHORED :do, so merge → resync is a
  # send-back into a do node (Decision 4).
  defp code_flow(board) do
    node = fn key, opts -> struct(Schemas.Flow.Node, [key: key, type: :agent] ++ opts) end
    edge = fn from, to, on -> %Schemas.Flow.Edge{from: from, to: to, on: on} end

    insert(:flow,
      board: board,
      key: "code",
      nodes: [
        node.("implement", foreach: "sub_tasks", role: :do),
        node.("spec_review", role: :check),
        node.("fix_findings", []),
        node.("precommit", role: :check),
        node.("final_fix", []),
        node.("merge", role: :do),
        node.("resync", role: :do)
      ],
      edges: [
        edge.("implement", "spec_review", :succeeded),
        edge.("spec_review", "fix_findings", :failed),
        edge.("fix_findings", "spec_review", :succeeded),
        edge.("spec_review", "precommit", :succeeded),
        edge.("precommit", "final_fix", :failed),
        edge.("final_fix", "precommit", :succeeded),
        edge.("precommit", "merge", :succeeded),
        edge.("merge", "resync", :failed),
        edge.("resync", "merge", :succeeded)
      ]
    )
  end

  defp new_run(board, ago_s) do
    card = insert(:card, board: board, stage: insert(:stage, board: board))
    started = t0_ago(ago_s)

    insert(:run,
      card: card,
      flow_key: "code",
      status: :done,
      started_at: started,
      finished_at: DateTime.add(started, 600, :second)
    )
  end

  defp exec_at(run, node, t0, start_s, finish_s, opts \\ []) do
    insert(:node_execution,
      run: run,
      node: node,
      visit: Keyword.get(opts, :visit, 1),
      attempt: Keyword.get(opts, :attempt, 1),
      outcome: Keyword.get(opts, :outcome, :succeeded),
      sub_task_id: Keyword.get(opts, :sub_task_id),
      started_at: DateTime.add(t0, start_s, :second),
      finished_at: DateTime.add(t0, finish_s, :second)
    )
  end

  # One Code-flow run, `ago_s` seconds ago, with every shape the map draws:
  #   task 1: implement → spec_review FAILS → fix_findings → spec_review (visit 2)
  #   task 2: implement (visit 2) → spec_review (visit 3)         — new work, closes the charge
  #   precommit FAILS → final_fix → precommit (visit 2)            — rewind charged to final_fix
  #   merge FAILS → resync (a :do node) → merge (visit 2)          — unattributed rework
  defp code_run(board, ago_s) do
    run = new_run(board, ago_s)
    t0 = t0_ago(ago_s)
    [s1, s2] = for _ <- 1..2, do: insert(:sub_task, card: %Schemas.Card{id: run.card_id})

    exec_at(run, "implement", t0, 0, 100, sub_task_id: s1.id)
    exec_at(run, "spec_review", t0, 100, 120, sub_task_id: s1.id, outcome: :failed)
    exec_at(run, "fix_findings", t0, 120, 150, sub_task_id: s1.id)
    exec_at(run, "spec_review", t0, 150, 160, sub_task_id: s1.id, visit: 2)
    exec_at(run, "implement", t0, 160, 260, sub_task_id: s2.id, visit: 2)
    exec_at(run, "spec_review", t0, 260, 280, sub_task_id: s2.id, visit: 3)
    exec_at(run, "precommit", t0, 280, 340, outcome: :failed)
    exec_at(run, "final_fix", t0, 340, 400)
    exec_at(run, "precommit", t0, 400, 460, visit: 2)
    exec_at(run, "merge", t0, 460, 470, outcome: :failed)
    exec_at(run, "resync", t0, 470, 520)
    exec_at(run, "merge", t0, 520, 530, visit: 2)
    run
  end

  describe "flow_stream/2 — sends" do
    test "final_fix → precommit rewind is its send; merge → resync is a send into a do node" do
      board = insert(:board)
      flow = code_flow(board)
      code_run(board, 3600)

      assert %{runs: 1, sends: sends} = ValueStream.flow_stream(flow, window: "all")

      assert sends == [
               %{
                 from: "precommit",
                 to: "final_fix",
                 returns_to: "precommit",
                 laps: 1,
                 to_secs: 60,
                 rewind_secs: 60,
                 secs: 120
               },
               %{from: "merge", to: "resync", returns_to: "merge", laps: 1, to_secs: 50, rewind_secs: 10, secs: 60},
               %{
                 from: "spec_review",
                 to: "fix_findings",
                 returns_to: "spec_review",
                 laps: 1,
                 to_secs: 30,
                 rewind_secs: 10,
                 secs: 40
               }
             ]

      for send <- sends, do: assert(send.secs == send.to_secs + send.rewind_secs)
    end

    test "the charge closes at the next work execution — final_fix is not charged for merge" do
      board = insert(:board)
      flow = code_flow(board)
      code_run(board, 3600)

      rows = flow |> ValueStream.flow_stream(window: "all") |> Map.fetch!(:nodes) |> Map.new(&{&1.node_key, &1})

      assert %{rewind_total: 60, rewind_count: 1} = rows["final_fix"]
      assert %{rewind_total: 10, rewind_count: 1} = rows["fix_findings"]
    end

    test "a second run's hop adds a lap to the same send" do
      board = insert(:board)
      flow = code_flow(board)
      code_run(board, 3600)
      code_run(board, 1800)

      %{sends: [top | _]} = ValueStream.flow_stream(flow, window: "all")

      assert top == %{
               from: "precommit",
               to: "final_fix",
               returns_to: "precommit",
               laps: 2,
               to_secs: 120,
               rewind_secs: 120,
               secs: 240
             }
    end

    test "sends reconcile with the node rows" do
      board = insert(:board)
      flow = code_flow(board)
      code_run(board, 3600)

      stream = ValueStream.flow_stream(flow, window: "all")
      assert stream.nodes == Runs.node_metrics_for_flow(flow, window: "all")
      rows = Map.new(stream.nodes, &{&1.node_key, &1})

      assert %{work_total: 200, rework_total: 0} = rows["implement"]
      assert %{work_total: 40, rework_total: 10} = rows["spec_review"]
      assert %{work_total: 0, rework_total: 30} = rows["fix_findings"]
      assert %{work_total: 60, rework_total: 60} = rows["precommit"]
      assert %{work_total: 0, rework_total: 60} = rows["final_fix"]
      assert %{work_total: 10, rework_total: 10} = rows["merge"]
      assert %{work_total: 50, rework_total: 0, rewind_total: nil, rewind_count: 0} = rows["resync"]

      # every entry to a fix is a send-back hop, so its sends cost exactly its rework + rewind
      for fix <- ["fix_findings", "final_fix"] do
        sent = stream.sends |> Enum.filter(&(&1.to == fix)) |> Enum.map(& &1.secs) |> Enum.sum()
        assert sent == rows[fix].rework_total + rows[fix].rewind_total
      end

      # the merge re-run after resync (a :do node) is the only unattributed rework
      rewound = rows |> Map.values() |> Enum.map(&(&1.rewind_total || 0)) |> Enum.sum()

      non_fix_rework =
        rows |> Map.drop(["fix_findings", "final_fix"]) |> Map.values() |> Enum.map(& &1.rework_total) |> Enum.sum()

      assert non_fix_rework - rewound == 10
    end
  end

  describe "flow_stream/2 — foreach" do
    test "N per run and the per-copy spread, reviews and fixes included in a copy" do
      board = insert(:board)
      flow = code_flow(board)
      code_run(board, 3600)
      run = new_run(board, 1800)
      t0 = t0_ago(1800)
      subs = for _ <- 1..3, do: insert(:sub_task, card: %Schemas.Card{id: run.card_id})

      subs
      |> Enum.with_index(1)
      |> Enum.each(fn {st, i} -> exec_at(run, "implement", t0, i * 30, i * 30 + 30, visit: i, sub_task_id: st.id) end)

      assert %{runs: 2, foreach: foreach} = ValueStream.flow_stream(flow, window: "all")

      # copies: run 1 task 1 = 100+20+30+10, task 2 = 100+20; run 2 = three 30s copies
      assert foreach == %{
               node_key: "implement",
               runs: 2,
               n_mean: 2.5,
               n_min: 2,
               n_max: 3,
               copies: 5,
               copy_p50: 30,
               copy_max: 160,
               copy_total: 370
             }
    end

    test "a flow with no executions is empty; a flow with no foreach node has foreach: nil" do
      board = insert(:board)

      assert ValueStream.flow_stream(code_flow(board), window: "all") == %{
               runs: 0,
               nodes: [],
               sends: [],
               foreach: %{
                 node_key: "implement",
                 runs: 0,
                 n_mean: nil,
                 n_min: nil,
                 n_max: nil,
                 copies: 0,
                 copy_p50: nil,
                 copy_max: nil,
                 copy_total: 0
               }
             }

      plain =
        insert(:flow, board: insert(:board), key: "plan", nodes: [%Schemas.Flow.Node{key: "write_plan", type: :agent}])

      assert %{foreach: nil} = ValueStream.flow_stream(plain, window: "all")
    end
  end

  describe "flow_stream/2 — options" do
    test "window and card_id scope exactly as node_metrics_for_flow/2" do
      board = insert(:board)
      flow = code_flow(board)
      code_run(board, 3600)
      old = code_run(board, 40 * 86_400)

      for opts <- [[window: "7d"], [window: "all"], [card_id: old.card_id]] do
        assert ValueStream.flow_stream(flow, opts).nodes == Runs.node_metrics_for_flow(flow, opts)
      end

      assert %{runs: 1, sends: [%{laps: 1} | _]} = ValueStream.flow_stream(flow, window: "7d")
      assert %{runs: 2, sends: [%{laps: 2} | _]} = ValueStream.flow_stream(flow, window: "all")
      assert %{runs: 1, sends: [%{laps: 1} | _]} = ValueStream.flow_stream(flow, card_id: old.card_id)
    end
  end
end
