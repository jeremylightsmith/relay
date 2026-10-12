defmodule Relay.RunDetailTest do
  use ExUnit.Case, async: true

  alias Ecto.Association.NotLoaded
  alias Relay.FanOutFixtures
  alias Relay.Runs
  alias Relay.Runs.RunDetail
  alias Schemas.Flow

  # id + started_at are needed by Runs.last_node/2 for terminal runs (current_node nil).
  defp ne(node_key, attempt, outcome, attrs \\ %{}) do
    {duration_s, attrs} = Map.pop(attrs, :duration_s, 42)
    started = Map.get(attrs, :started_at, ~U[2026-07-20 00:00:00Z])
    finished = duration_s && DateTime.add(started, duration_s, :second)

    Map.merge(
      %{
        id: System.unique_integer([:positive]),
        node_key: node_key,
        attempt: attempt,
        outcome: outcome,
        detail: nil,
        cost: nil,
        started_at: started,
        finished_at: finished
      },
      attrs
    )
  end

  defp run(attrs),
    do:
      Map.merge(
        %{
          status: :running,
          flow_key: "code",
          flow_version: nil,
          current_node: "implement",
          started_at: ~U[2026-07-20 00:00:00Z],
          finished_at: nil,
          failure_detail: nil
        },
        attrs
      )

  defp code_flow do
    %Flow{
      nodes: [%{key: "implement", type: :agent}, %{key: "quality_review", type: :gate}],
      edges: [
        %{from: "start", on: nil, to: "implement", max_loops: nil},
        %{from: "implement", on: :succeeded, to: "quality_review", max_loops: nil},
        %{from: "quality_review", on: :failed, to: "implement", max_loops: 3},
        %{from: "quality_review", on: :succeeded, to: "done", max_loops: nil}
      ]
    }
  end

  # Relay.FanOutFixtures' region flow (prep → fo ⇉ {a, b1 ⇄ b2} → fi → after → done), every edge
  # carrying `on` and `max_loops` so a variant can update them in place.
  defp region_flow do
    %Flow{
      nodes: FanOutFixtures.region_nodes(),
      edges: Enum.map(FanOutFixtures.region_edges(), &Map.merge(%{on: nil, max_loops: nil}, &1))
    }
  end

  # region_flow/0 with each node / edge passed through `node_fun` / `edge_fun` and `extra` appended.
  defp region_flow_variant(node_fun, edge_fun, extra_nodes \\ [], extra_edges \\ []) do
    flow = region_flow()
    %{flow | nodes: Enum.map(flow.nodes, node_fun) ++ extra_nodes, edges: Enum.map(flow.edges, edge_fun) ++ extra_edges}
  end

  defp branch(id, fan_out_id, key, position, state, outcome \\ nil),
    do: %{id: id, fan_out_execution_id: fan_out_id, branch: key, position: position, state: state, outcome: outcome}

  # A run with an open region: `fo` (id 100) fanned out to `a` (branch 1) and `b1` (branch 2),
  # both in flight.
  defp region_run(attrs \\ %{}) do
    run(
      Map.merge(
        %{
          status: :running,
          flow_key: "region",
          current_node: "fo",
          run_branches: [branch(1, 100, "a", 0, :running), branch(2, 100, "b1", 1, :running)],
          node_executions: [
            ne("prep", 1, :succeeded, %{id: 10}),
            ne("fo", 1, :succeeded, %{id: 100}),
            ne("a", 1, nil, %{id: 101, run_branch_id: 1, duration_s: nil}),
            ne("b1", 1, nil, %{id: 102, run_branch_id: 2, duration_s: nil})
          ]
        },
        attrs
      )
    )
  end

  # A run whose region joined with a failure (scenario 6): `a` ✓, `b1` ✕, `fi` failed, `after` in flight.
  defp joined_run do
    region_run(%{
      current_node: "after",
      run_branches: [branch(1, 100, "a", 0, :ended, :succeeded), branch(2, 100, "b1", 1, :ended, :failed)],
      node_executions: [
        ne("prep", 1, :succeeded, %{id: 10}),
        ne("fo", 1, :succeeded, %{id: 100, started_at: ~U[2026-07-20 00:00:00Z], duration_s: 0}),
        ne("a", 1, :succeeded, %{id: 101, run_branch_id: 1, cost: Decimal.new("0.31")}),
        ne("b1", 1, :failed, %{
          id: 102,
          run_branch_id: 2,
          detail: "Loop budget spent",
          cost: Decimal.new("0.44"),
          started_at: ~U[2026-07-20 00:01:00Z],
          duration_s: 360
        }),
        ne("fi", 1, :failed, %{id: 103, started_at: ~U[2026-07-20 00:07:00Z], duration_s: 41}),
        ne("after", 1, nil, %{id: 104, duration_s: nil})
      ]
    })
  end

  defp node_rows(detail), do: Enum.filter(detail.timeline, &(&1.kind == :node))

  defp node_row(detail, key), do: Enum.find(node_rows(detail), &(&1.node_key == key))

  defp regions(detail), do: Enum.filter(detail.timeline, &(&1.kind == :region))

  defp region(detail), do: detail |> regions() |> hd()

  defp lane(region, branch), do: Enum.find(region.lanes, &(&1.branch == branch))

  # Every :node row, top-level and inside every lane.
  defp all_node_rows(detail) do
    Enum.flat_map(detail.timeline, fn
      %{kind: :node} = row ->
        [row]

      %{kind: :region} = region ->
        [region.header | Enum.flat_map(region.lanes, &Enum.filter(&1.rows, fn r -> r.kind == :node end))]

      _other ->
        []
    end)
  end

  describe "run_detail/2 with an open fan-out region (RE437, grouped by RE440)" do
    test "the region groups under its fan_out header, its waiting fan_in and the pending tail follow (scenario 1)" do
      detail = Runs.run_detail(region_run(), region_flow())

      assert Enum.map(detail.timeline, & &1.kind) == [:node, :region, :node, :pending]
      assert Enum.map(node_rows(detail), & &1.node_key) == ["prep", "fi"]

      region = region(detail)
      assert region.header.node_key == "fo"
      assert region.header.type == :fan_out
      assert region.open? == true
      assert region.fan_out_execution_id == 100
      assert region.tally == %{total: 2, running: 2, queued: 0, parked: 0, ended: 0, succeeded: 0, failed: 0}
      assert region.max_parallel == 2

      assert [%{branch: "a", position: 0} = lane_a, %{branch: "b1", position: 1} = lane_b1] = region.lanes
      assert [%{kind: :node, node_key: "a", state: :active}] = lane_a.rows
      assert [%{kind: :node, node_key: "b1", state: :active}] = lane_b1.rows
    end

    test "lanes follow branch position, not start time (scenario 2)" do
      r =
        region_run(%{
          node_executions: [
            ne("prep", 1, :succeeded, %{id: 10}),
            ne("fo", 1, :succeeded, %{id: 100}),
            ne("b1", 1, nil, %{id: 101, run_branch_id: 2, duration_s: nil}),
            ne("a", 1, nil, %{id: 102, run_branch_id: 1, duration_s: nil})
          ]
        })

      detail = Runs.run_detail(r, region_flow())

      assert Enum.map(region(detail).lanes, & &1.branch) == ["a", "b1"]
    end

    test "an open region is followed by a waiting fan_in, which the pending tail does not repeat (scenario 3)" do
      detail = Runs.run_detail(region_run(), region_flow())

      [_prep, _region, waiting, pending] = detail.timeline
      assert %{kind: :node, node_key: "fi", state: :waiting, type: :fan_in, join: %{total: 2, failed: 0}} = waiting
      assert %{attempt: 1, duration_s: nil, cost: nil, joined_from: nil} = waiting
      assert pending == %{kind: :pending, nodes: ["after"]}
    end

    test "loop rows are computed within a lane, not over interleaved executions (scenario 4)" do
      flow =
        region_flow_variant(& &1, fn
          %{from: "b1", on: :failed} = edge -> %{edge | max_loops: 2}
          edge -> edge
        end)

      r =
        region_run(%{
          run_branches: [branch(1, 100, "a", 0, :ended, :succeeded), branch(2, 100, "b1", 1, :running)],
          node_executions: [
            ne("prep", 1, :succeeded, %{id: 10}),
            ne("fo", 1, :succeeded, %{id: 100}),
            ne("b1", 1, :failed, %{id: 101, run_branch_id: 2}),
            ne("a", 1, :succeeded, %{id: 102, run_branch_id: 1}),
            ne("b2", 2, nil, %{id: 103, run_branch_id: 2, duration_s: nil})
          ]
        })

      detail = Runs.run_detail(r, flow)
      region = region(detail)

      assert [
               %{kind: :node, node_key: "b1", state: :failed},
               %{kind: :loop, from_node: "b1", to_node: "b2", attempt: 2, max_loops: 2},
               %{kind: :node, node_key: "b2", attempt: 2, state: :active}
             ] = lane(region, "b1").rows

      assert [%{kind: :node, node_key: "a", state: :done}] = lane(region, "a").rows
      refute Enum.any?(detail.timeline, &(&1.kind == :loop))
    end

    test "a branch held back by max_parallel is a queued placeholder lane (scenario 5)" do
      flow =
        region_flow_variant(
          fn
            %{key: "fo"} = node -> Map.put(node, :max_parallel, 2)
            node -> node
          end,
          & &1,
          [%{key: "c", type: :shell}],
          [%{from: "fo", on: nil, to: "c", max_loops: nil}, %{from: "c", on: :succeeded, to: "fi", max_loops: nil}]
        )

      r =
        region_run(%{
          run_branches: [
            branch(1, 100, "a", 0, :running),
            branch(2, 100, "b1", 1, :running),
            branch(3, 100, "c", 2, :queued)
          ]
        })

      region = region(Runs.run_detail(r, flow))

      assert region.tally == %{total: 3, running: 2, queued: 1, parked: 0, ended: 0, succeeded: 0, failed: 0}
      assert region.max_parallel == 2

      assert [%{kind: :node, node_key: "c", state: :queued, attempt: 1, join: nil, joined_from: nil} = placeholder] =
               lane(region, "c").rows

      assert %{type: :shell, detail: nil, cost: nil, duration_s: nil} = placeholder
    end

    test "a region that joined with a failure annotates its fan_in and the row after it (scenario 6)" do
      detail = Runs.run_detail(joined_run(), region_flow())
      region = region(detail)

      assert region.open? == false
      assert region.tally.failed == 1
      assert region.tally.succeeded == 1
      assert region.duration_s == 461
      assert Decimal.equal?(region.cost, Decimal.new("0.75"))

      assert [_prep, ^region, fi, after_row] = detail.timeline
      assert %{kind: :node, node_key: "fi", state: :failed, join: %{total: 2, failed: 1}} = fi
      assert %{kind: :node, node_key: "after", joined_from: 2} = after_row
      refute Enum.any?(all_node_rows(detail), &(&1.state == :waiting))
    end

    test "a region entered twice renders one group per entry (scenario 7)" do
      r =
        region_run(%{
          current_node: "after",
          run_branches: [
            branch(1, 100, "a", 0, :ended, :succeeded),
            branch(2, 100, "b1", 1, :ended, :succeeded),
            branch(3, 200, "a", 0, :ended, :succeeded),
            branch(4, 200, "b1", 1, :ended, :succeeded)
          ],
          node_executions: [
            ne("prep", 1, :succeeded, %{id: 10}),
            ne("fo", 1, :succeeded, %{id: 100, visit: 1}),
            ne("a", 1, :succeeded, %{id: 101, run_branch_id: 1}),
            ne("b1", 1, :succeeded, %{id: 102, run_branch_id: 2}),
            ne("fi", 1, :succeeded, %{id: 103, visit: 1}),
            ne("fo", 1, :succeeded, %{id: 200, visit: 2}),
            ne("a", 1, :succeeded, %{id: 201, run_branch_id: 3}),
            ne("b1", 1, :succeeded, %{id: 202, run_branch_id: 4}),
            ne("fi", 1, :succeeded, %{id: 203, visit: 2})
          ]
        })

      detail = Runs.run_detail(r, region_flow())

      assert [first, second] = regions(detail)
      assert first.fan_out_execution_id == 100
      assert second.fan_out_execution_id == 200
      assert Enum.map(first.lanes, &(hd(&1.rows).node_key <> "@" <> Integer.to_string(&1.position))) == ["a@0", "b1@1"]
      assert Enum.map(first.lanes, &length(&1.rows)) == [1, 1]
      assert Enum.map(second.lanes, &length(&1.rows)) == [1, 1]
      assert Enum.map(second.lanes, & &1.branch) == ["a", "b1"]
    end

    test "with no run_branches loaded the timeline stays flat (scenario 8)" do
      for branches <- [:absent, nil, %NotLoaded{}] do
        base = region_run()
        r = if branches == :absent, do: Map.delete(base, :run_branches), else: %{base | run_branches: branches}

        detail = Runs.run_detail(r, region_flow())

        assert regions(detail) == []
        assert Enum.map(node_rows(detail), & &1.node_key) == ["prep", "fo", "a", "b1"]
      end
    end

    test "a parked run with no run_branches loaded keeps today's paused rows" do
      for branches <- [:absent, nil, %NotLoaded{}] do
        base = region_run(%{status: :parked})
        r = if branches == :absent, do: Map.delete(base, :run_branches), else: %{base | run_branches: branches}

        detail = Runs.run_detail(r, region_flow())

        assert node_row(detail, "a").state == :paused
        assert node_row(detail, "b1").state == :paused
      end
    end

    test "a branch waiting on a human is paused while its running sibling's lane stays active (scenario 9)" do
      r =
        region_run(%{
          status: :parked,
          run_branches: [branch(1, 100, "a", 0, :parked), branch(2, 100, "b1", 1, :running)],
          node_executions: [
            ne("prep", 1, :succeeded, %{id: 10}),
            ne("fo", 1, :succeeded, %{id: 100}),
            ne("a", 1, :needs_input, %{id: 101, run_branch_id: 1}),
            ne("b1", 1, nil, %{id: 102, run_branch_id: 2, duration_s: nil})
          ]
        })

      region = region(Runs.run_detail(r, region_flow()))

      assert [%{node_key: "a", state: :paused}] = lane(region, "a").rows
      assert [%{node_key: "b1", state: :active}] = lane(region, "b1").rows
    end

    test "with no flow the region still groups and joins, without max_parallel or a waiting row (scenario 10)" do
      detail = Runs.run_detail(joined_run(), nil)
      region = region(detail)

      assert region.max_parallel == nil
      assert %{kind: :node, node_key: "fi", join: %{total: 2, failed: 1}} = Enum.at(detail.timeline, 2)
      refute Enum.any?(all_node_rows(detail), &(&1.state == :waiting))

      open = Runs.run_detail(region_run(), nil)
      assert length(regions(open)) == 1
      refute Enum.any?(all_node_rows(open), &(&1.state == :waiting))
    end

    test "no synthetic active row is added for the fan_out the run's current_node names" do
      detail = Runs.run_detail(region_run(), region_flow())

      refute Enum.any?(node_rows(detail), &(&1.node_key == "fo"))
      assert Enum.count(all_node_rows(detail), &(&1.node_key == "fo")) == 1
    end

    test "no synthetic active row for a control-node current_node even when every execution has settled" do
      settled = [branch(1, 100, "a", 0, :ended, :succeeded), branch(2, 100, "b1", 1, :ended, :succeeded)]

      for {current, branches, nes} <- [
            {"fo", [branch(1, 100, "a", 0, :queued), branch(2, 100, "b1", 1, :queued)],
             [ne("prep", 1, :succeeded, %{id: 10}), ne("fo", 1, :succeeded, %{id: 100})]},
            {"fi", settled,
             [
               ne("prep", 1, :succeeded, %{id: 10}),
               ne("fo", 1, :succeeded, %{id: 100}),
               ne("a", 1, :succeeded, %{id: 101, run_branch_id: 1}),
               ne("b1", 1, :succeeded, %{id: 102, run_branch_id: 2})
             ]}
          ] do
        r = region_run(%{current_node: current, run_branches: branches, node_executions: nes})
        detail = Runs.run_detail(r, region_flow())

        refute Enum.any?(all_node_rows(detail), &(&1.node_key == current and &1.state == :active))
      end
    end
  end

  describe "fan-out region groups (RE440)" do
    test "branch_bars holds the latest entry's bars per fan_out key (scenario 11)" do
      r =
        region_run(%{
          run_branches: [
            branch(1, 100, "a", 0, :ended, :succeeded),
            branch(2, 100, "b1", 1, :ended, :succeeded),
            branch(3, 200, "a", 0, :running),
            branch(4, 200, "b1", 1, :queued)
          ],
          node_executions: [
            ne("prep", 1, :succeeded, %{id: 10}),
            ne("fo", 1, :succeeded, %{id: 100, visit: 1}),
            ne("a", 1, :succeeded, %{id: 101, run_branch_id: 1}),
            ne("b1", 1, :succeeded, %{id: 102, run_branch_id: 2}),
            ne("fi", 1, :succeeded, %{id: 103, visit: 1}),
            ne("fo", 1, :succeeded, %{id: 200, visit: 2}),
            ne("a", 1, nil, %{id: 201, run_branch_id: 3, duration_s: nil})
          ]
        })

      assert Runs.run_detail(r, region_flow()).branch_bars == %{"fo" => [:running, :queued]}
    end

    test "branch_bars is empty for a run with no branches (scenario 11)" do
      for branches <- [:absent, nil, %NotLoaded{}, []] do
        base = region_run()
        r = if branches == :absent, do: Map.delete(base, :run_branches), else: %{base | run_branches: branches}

        assert Runs.run_detail(r, region_flow()).branch_bars == %{}
      end
    end

    test "branch_bar/1 maps every branch state × outcome onto the closed bar set (scenario 12)" do
      cases = [
        {%{state: :queued, outcome: nil}, :queued},
        {%{state: :running, outcome: nil}, :running},
        {%{state: :parked, outcome: nil}, :parked},
        {%{state: :ended, outcome: :succeeded}, :succeeded},
        {%{state: :ended, outcome: :failed}, :failed},
        {%{state: :ended, outcome: nil}, :cancelled}
      ]

      for {row, bar} <- cases do
        assert RunDetail.branch_bar(row) == bar
        assert bar in RunDetail.bar_states()
      end

      assert RunDetail.bar_states() == [:succeeded, :failed, :running, :parked, :queued, :cancelled]
    end

    test "branch_tally/1 counts states and ended outcomes" do
      rows = [
        %{state: :ended, outcome: :succeeded},
        %{state: :ended, outcome: :failed},
        %{state: :ended, outcome: nil},
        %{state: :running, outcome: nil},
        %{state: :queued, outcome: nil},
        %{state: :parked, outcome: nil}
      ]

      assert RunDetail.branch_tally(rows) ==
               %{total: 6, running: 1, queued: 1, parked: 1, ended: 3, succeeded: 1, failed: 1}

      assert RunDetail.branch_tally([]) ==
               %{total: 0, running: 0, queued: 0, parked: 0, ended: 0, succeeded: 0, failed: 0}
    end

    test "a non-region run keeps its rows and gains nil join annotations (scenario 13)" do
      r =
        run(%{
          node_executions: [
            ne("implement", 1, :succeeded),
            ne("quality_review", 1, :failed, %{detail: "no"}),
            ne("implement", 2, nil, %{duration_s: nil})
          ]
        })

      detail = Runs.run_detail(r, code_flow())

      assert Enum.map(detail.timeline, &{&1.kind, &1[:node_key]}) == [
               {:node, "implement"},
               {:node, "quality_review"},
               {:loop, nil},
               {:node, "implement"}
             ]

      assert Enum.all?(node_rows(detail), &(&1.join == nil and &1.joined_from == nil))
      assert detail.branch_bars == %{}
    end
  end

  describe "breaker_tripped?/1" do
    test "true only on the engine's circuit_breaker token" do
      assert Runs.breaker_tripped?(run(%{status: :failed, failure_detail: "circuit_breaker: repeated 3 times"}))

      assert Runs.breaker_tripped?(
               run(%{status: :failed, failure_detail: "The same failure repeated. (circuit_breaker: ...)"})
             )

      refute Runs.breaker_tripped?(run(%{status: :failed, failure_detail: "(no_route_for_outcome: fixit → failed)"}))
      refute Runs.breaker_tripped?(run(%{status: :failed, failure_detail: nil}))
      refute Runs.breaker_tripped?(run(%{status: :running}))
      refute Runs.breaker_tripped?(Map.delete(run(%{status: :failed}), :failure_detail))
    end

    test "attempts >= 3 does NOT fabricate a breaker" do
      r =
        run(%{
          status: :failed,
          current_node: nil,
          failure_detail: "(no_route_for_outcome: fixit → failed)",
          node_executions: [ne("q", 1, :failed), ne("q", 2, :failed), ne("q", 3, :failed)]
        })

      detail = Runs.run_detail(r, nil)
      refute detail.breaker_tripped?
    end
  end

  describe "run_detail/2 timeline" do
    test "review-failed loop emits a structured :loop row with max_loops, never resumed?" do
      r =
        run(%{
          node_executions: [
            ne("implement", 1, :succeeded),
            ne("quality_review", 1, :failed, %{detail: "no"}),
            ne("implement", 2, nil, %{duration_s: nil})
          ]
        })

      detail = Runs.run_detail(r, code_flow())

      loop = Enum.find(detail.timeline, &(&1.kind == :loop))
      assert loop == %{kind: :loop, from_node: "quality_review", to_node: "implement", attempt: 2, max_loops: 3}
      refute Enum.any?(detail.timeline, &(&1[:kind] == :node and &1[:resumed?]))
    end

    test "needs-input re-entry is the only state that sets resumed?" do
      r =
        run(%{
          flow_key: "spec",
          current_node: "brainstorm",
          node_executions: [ne("brainstorm", 1, :needs_input), ne("brainstorm", 2, nil, %{duration_s: nil})]
        })

      detail = Runs.run_detail(r, nil)

      assert Enum.any?(
               detail.timeline,
               &(&1.kind == :node and &1.node_key == "brainstorm" and &1.attempt == 2 and &1.resumed?)
             )
    end

    test "row_state maps outcome × run-status; partial? is flagged separately" do
      r =
        run(%{
          status: :failed,
          current_node: nil,
          node_executions: [ne("a", 1, :succeeded), ne("b", 1, :partial), ne("c", 1, :failed), ne("d", 1, nil)]
        })

      states =
        for row <- r.node_executions do
          Enum.find(Runs.run_detail(r, nil).timeline, &(&1[:node_key] == row.node_key))
        end

      assert Enum.map(states, & &1.state) == [:done, :done, :failed, :stopped]
      assert Enum.at(states, 1).partial?
    end

    test "synthetic active row appears when the run is between nodes" do
      r = run(%{status: :running, current_node: "quality_review", node_executions: [ne("implement", 1, :succeeded)]})
      detail = Runs.run_detail(r, code_flow())
      assert Enum.any?(detail.timeline, &(&1.kind == :node and &1.node_key == "quality_review" and &1.state == :active))
    end

    test "pending tail lists the unrun happy-path nodes" do
      r = run(%{status: :running, current_node: "implement", node_executions: []})
      detail = Runs.run_detail(r, code_flow())
      assert %{kind: :pending, nodes: ["quality_review"]} in detail.timeline
    end

    test "pending tail is empty for a terminal status, even with unrun happy-path nodes" do
      r = run(%{status: :done, current_node: "implement", node_executions: []})
      detail = Runs.run_detail(r, code_flow())
      refute Enum.any?(detail.timeline, &(&1.kind == :pending))
    end
  end

  describe "run_detail/2 scalars" do
    test "tripped node/repeats, last failure detail, totals, parked attempt" do
      r =
        run(%{
          status: :failed,
          current_node: nil,
          node_executions: [
            ne("implement", 1, :succeeded, %{duration_s: 100, cost: Decimal.new("0.90")}),
            ne("quality_review", 1, :failed, %{duration_s: 40, cost: Decimal.new("0.30"), detail: "same"}),
            ne("quality_review", 2, :failed, %{duration_s: 40, cost: Decimal.new("0.30"), detail: "same again"})
          ]
        })

      detail = Runs.run_detail(r, nil)

      assert detail.tripped_node == "quality_review"
      assert detail.tripped_repeats == 2
      assert detail.last_failure_detail == "same again"
      assert detail.totals == %{duration_s: 180, cost: Decimal.new("1.50"), nodes: 2, attempts: 3}
    end

    test "last_failure_detail names the parking :partial, not an earlier :failed (RE253/A9)" do
      # A :partial degrades onto the node's :failed edge and parks (Engine.degrade_to_failed).
      # The run parked on attempt 2, so the drawer's failure text must be attempt 2's detail —
      # matching the question, which also comes from the parking execution. Keeping only :failed
      # here surfaced attempt 1 instead, so the escalation panel disagreed with its own question.
      r =
        run(%{
          status: :parked,
          current_node: "implement",
          node_executions: [
            ne("implement", 1, :failed, %{detail: "3 credo warnings"}),
            ne("implement", 2, :partial, %{detail: "2 of 5 plan tasks left unimplemented"})
          ]
        })

      detail = Runs.run_detail(r, nil)

      assert detail.last_failure_detail == "2 of 5 plan tasks left unimplemented"
    end

    test "parked attempt reflects the paused node's highest attempt" do
      r =
        run(%{
          status: :parked,
          current_node: "brainstorm",
          node_executions: [ne("brainstorm", 1, :failed), ne("brainstorm", 2, :failed), ne("brainstorm", 3, :needs_input)]
        })

      assert Runs.run_detail(r, nil).parked_attempt == 3
    end

    test "failure_reason is the engine sentence, else a neutral fallback" do
      assert Runs.run_detail(run(%{status: :failed, failure_detail: "boom"}), nil).failure_reason == "boom"

      assert Runs.run_detail(run(%{status: :failed, failure_detail: nil}), nil).failure_reason ==
               "The run stopped before reaching the end of the flow."
    end
  end

  describe "steered attempts (RE358)" do
    test "a steered row reads :steered and is not a spent attempt; its restart reads resumed" do
      r =
        run(%{
          flow_key: "plan",
          current_node: "write_plan",
          node_executions: [
            ne("write_plan", 1, :steered, %{visit: 1, session_id: "s"}),
            ne("write_plan", 2, nil, %{visit: 1, session_id: nil, duration_s: nil})
          ]
        })

      assert [row1, row2] = Enum.filter(Runs.run_detail(r, nil).timeline, &(&1.kind == :node))

      assert %{state: :steered, steered?: true, attempt: 1} = row1
      assert %{state: :active, steered?: false, resumed?: true, attempt: 1} = row2
    end

    test "a restart after a steer with no known session is not resumed" do
      r =
        run(%{
          current_node: "write_plan",
          node_executions: [
            ne("write_plan", 1, :steered, %{visit: 1, session_id: nil}),
            ne("write_plan", 2, nil, %{visit: 1, session_id: nil, duration_s: nil})
          ]
        })

      assert [_row1, row2] = Enum.filter(Runs.run_detail(r, nil).timeline, &(&1.kind == :node))
      assert row2.resumed? == false
    end
  end

  describe "attempt numbers skip :blocked attempts (RE267)" do
    test "a node that waited out a usage limit twice reads as its first attempt" do
      r =
        run(%{
          current_node: "implement",
          node_executions: [
            ne("implement", 1, :blocked, %{visit: 1, resume_at: ~U[2100-01-01 00:00:00Z]}),
            ne("implement", 2, :blocked, %{visit: 1, resume_at: ~U[2100-01-01 00:00:00Z]}),
            ne("implement", 3, nil, %{visit: 1, duration_s: nil})
          ]
        })

      rows = Enum.filter(Runs.run_detail(r, code_flow()).timeline, &(&1.kind == :node and &1.node_key == "implement"))
      assert rows |> Enum.map(& &1.attempt) |> Enum.take(3) == [1, 1, 1]
    end

    test "the escalation's attempt count counts only attempts that actually ran" do
      r =
        run(%{
          status: :parked,
          current_node: "implement",
          node_executions: [
            ne("implement", 1, :failed, %{visit: 1}),
            ne("implement", 2, :blocked, %{visit: 1, resume_at: ~U[2100-01-01 00:00:00Z]}),
            ne("implement", 3, :failed, %{visit: 1})
          ]
        })

      assert Runs.run_detail(r, code_flow()).parked_attempt == 2
    end
  end
end
