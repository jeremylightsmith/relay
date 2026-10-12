defmodule Relay.Runs.FanOutTest do
  @moduledoc """
  RE437 engine core: a `fan_out` → branches → `fan_in` region runs on the server — control nodes
  resolve with no job, branches run concurrently up to `max_parallel` on branch-scoped history,
  and the `fan_in` joins with a labelled result.
  """

  use Relay.DataCase, async: true

  import Relay.FanOutFixtures, only: [put_node: 3, drop_edges: 3, three_nodes: 0, three_edges: 0]

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.Activity
  alias Schemas.Card
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run
  alias Schemas.SubTask

  setup do
    start_engine!()
    FakeDispatcher.register(self())
    :ok
  end

  # ── the shared fixture: `three` (Relay.FanOutFixtures) ─────────────────────────────────

  # The flow starting at `fo` directly (scenarios 10 and 11): `prep` dropped.
  defp from_fo(nodes, edges) do
    nodes = Enum.reject(nodes, &(&1.key == "prep"))
    edges = edges |> drop_edges("start", "prep") |> drop_edges("prep", "fo")
    {nodes, [%{from: "start", to: "fo"} | edges]}
  end

  defp board_with_stages do
    board = insert(:board)
    pulls = insert(:stage, board: board, name: "Plan:Done", position: 1)
    works = insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 2)
    insert(:stage, board: board, name: "Review", category: :in_progress, type: :review, position: 3)
    %{board: board, pulls: pulls, works: works}
  end

  defp enabled_flow(board, works, attrs) do
    {:ok, flow} = Relay.Flows.create_flow(board, Map.put(attrs, :stage_id, works.id))
    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp setup_three(opts \\ []) do
    %{board: board, pulls: pulls, works: works} = board_with_stages()
    nodes = Keyword.get(opts, :nodes, three_nodes())
    edges = Keyword.get(opts, :edges, three_edges())
    isolation = Keyword.get(opts, :isolation, :shared_clean)

    flow = enabled_flow(board, works, %{key: "three", isolation: isolation, nodes: nodes, edges: edges})
    card = insert(:card, stage: pulls)
    %{board: board, flow: flow, card: card}
  end

  # Scenario 2's run: `prep` has succeeded with "prepped", so the region is open.
  defp start_three(opts \\ []) do
    %{card: card, flow: flow} = ctx = setup_three(opts)
    {:ok, run} = Runs.start_run(card, flow)
    :ok = report(run, "prep", :succeeded, "prepped")
    Map.put(ctx, :run, run)
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────

  defp job_for(run, node_key) do
    case Enum.filter(Runs.active_jobs(run), &(&1.node_key == node_key)) do
      [job] -> job
      other -> flunk("expected one active #{node_key} job, got #{length(other)}")
    end
  end

  defp report(run, node_key, outcome, detail) do
    assert {:ok, _run} = Runs.report_outcome(job_for(run, node_key), %{outcome: outcome, detail: detail})
    :ok
  end

  defp rows(run), do: Map.new(Runs.list_run_branches(run), &{&1.branch, &1})

  defp running_count(run), do: Enum.count(Runs.list_run_branches(run), &(&1.state == :running))

  defp executions(run, node_key) do
    Repo.all(from e in NodeExecution, where: e.run_id == ^run.id and e.node_key == ^node_key, order_by: e.id)
  end

  defp reload(run), do: Repo.get!(Run, run.id)

  defp failure_texts(card) do
    Repo.all(from a in Activity, where: a.card_id == ^card.id and a.type == :failure, select: a.text)
  end

  # ── scenario 2: the region opens ────────────────────────────────────────────────────────

  describe "opening a region" do
    test "prep → fo resolves the fan_out with no job and starts every branch" do
      %{run: run} = start_three()

      assert [fo] = executions(run, "fo")
      assert fo.outcome == :succeeded
      refute Repo.exists?(from j in NodeJob, where: j.node_execution_id == ^fo.id)
      assert reload(run).current_node == "fo"

      branches = Runs.list_run_branches(run)

      assert Enum.map(branches, &{&1.branch, &1.position, &1.state}) == [
               {"a", 0, :running},
               {"b1", 1, :running},
               {"c", 2, :running}
             ]

      assert Enum.all?(branches, &(&1.fan_out_execution_id == fo.id))

      jobs = Runs.active_jobs(run)
      assert Enum.map(jobs, & &1.node_key) == ["a", "b1", "c"]
      assert Enum.all?(jobs, &(&1.payload["vars"]["prior_detail"] == "prepped"))

      by_branch = rows(run)

      for key <- ["a", "b1", "c"] do
        assert [execution] = executions(run, key)
        assert execution.run_branch_id == by_branch[key].id
      end
    end

    test "each branch job is dispatched and broadcast as started, after the fan_out finished" do
      %{card: card, flow: flow} = setup_three()
      Runs.subscribe(card.board_id)
      {:ok, run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, %NodeJob{node_key: "prep"}}

      :ok = report(run, "prep", :succeeded, "prepped")

      assert_receive {:node_finished, _run, %NodeExecution{node_key: "fo"}}
      for key <- ["a", "b1", "c"], do: assert_receive({:node_started, _run, %NodeExecution{node_key: ^key}})
      for key <- ["a", "b1", "c"], do: assert_receive({:dispatched, %NodeJob{node_key: ^key}})
    end
  end

  # ── scenario 3: max_parallel ────────────────────────────────────────────────────────────

  describe "max_parallel" do
    test "caps running branches and starts the next queued one when a branch ends" do
      %{run: run} = start_three(nodes: put_node(three_nodes(), "fo", %{max_parallel: 2}))

      assert %{"a" => %{state: :running}, "b1" => %{state: :running}, "c" => %{state: :queued}} = rows(run)
      assert length(Runs.active_jobs(run)) == 2
      assert running_count(run) <= 2

      :ok = report(run, "a", :succeeded, "A ok")

      assert %{"a" => %{state: :ended}, "c" => %{state: :running}} = rows(run)
      assert length(Runs.active_jobs(run)) == 2
      assert running_count(run) <= 2
    end
  end

  # ── scenarios 4 and 5: the join ─────────────────────────────────────────────────────────

  describe "the join" do
    test "waits for every branch, then succeeds with every result labelled and finishes the run" do
      %{run: run} = start_three()

      :ok = report(run, "a", :succeeded, "A ok")
      :ok = report(run, "c", :succeeded, "C ok")
      assert executions(run, "fi") == []

      :ok = report(run, "b1", :succeeded, "B ok")

      assert [fi] = executions(run, "fi")
      assert fi.outcome == :succeeded
      assert fi.detail == "## a: succeeded\nA ok\n\n## b1: succeeded\nB ok\n\n## c: succeeded\nC ok"
      assert reload(run).status == :done
    end

    test "fails when any branch failed and hands the labelled result to the failed edge" do
      %{run: run} = start_three()

      :ok = report(run, "c", :failed, "C broke")
      :ok = report(run, "a", :succeeded, "A ok")
      :ok = report(run, "b1", :succeeded, "B ok")

      assert [fi] = executions(run, "fi")
      assert fi.outcome == :failed
      assert fi.detail =~ "## c: failed\nC broke"

      run = reload(run)
      assert run.status == :running
      assert run.current_node == "report"

      vars = job_for(run, "report").payload["vars"]
      assert vars["prior_detail"] == fi.detail
      assert vars["findings"] == fi.detail
    end
  end

  # ── scenarios 6–8: branch-scoped budgets ────────────────────────────────────────────────

  describe "inside a branch" do
    test "a failed-edge loop stays in its branch and carries the findings" do
      %{run: run} = start_three()
      b1_row = rows(run)["b1"]

      :ok = report(run, "b1", :failed, "needs fixing")

      b2 = job_for(run, "b2")
      assert Repo.get!(NodeExecution, b2.node_execution_id).run_branch_id == b1_row.id
      assert b2.payload["vars"]["findings"] == "needs fixing"
      assert rows(run)["b1"].current_node == "b2"
      assert reload(run).current_node == "fo"

      :ok = report(run, "b2", :succeeded, "fixed")

      second_b1 = Repo.get!(NodeExecution, job_for(run, "b1").node_execution_id)
      assert second_b1.visit == 2
      assert second_b1.run_branch_id == b1_row.id

      :ok = report(run, "b1", :succeeded, "B ok")
      :ok = report(run, "a", :succeeded, "A ok")
      :ok = report(run, "c", :succeeded, "C ok")

      assert [%NodeExecution{outcome: :succeeded}] = executions(run, "fi")
    end

    test "a spent loop budget ends only that branch, failed, and the join then fails" do
      %{run: run, card: card} = start_three()

      :ok = report(run, "b1", :failed, "needs fixing 1")
      :ok = report(run, "b2", :succeeded, "fixed 1")
      :ok = report(run, "b1", :failed, "needs fixing 2")
      :ok = report(run, "b2", :succeeded, "fixed 2")
      :ok = report(run, "b1", :failed, "needs fixing 3")

      b1_row = rows(run)["b1"]
      assert b1_row.state == :ended
      assert b1_row.outcome == :failed
      assert b1_row.detail =~ "(loop_budget_exhausted: b1 → b2 on failed (max_loops 2))"
      assert b1_row.detail =~ "needs fixing 3"

      run = reload(run)
      assert run.status == :running
      assert Enum.count(failure_texts(card), &(&1 == b1_row.detail)) == 1

      :ok = report(run, "a", :succeeded, "A ok")
      :ok = report(run, "c", :succeeded, "C ok")

      assert [%NodeExecution{outcome: :failed}] = executions(run, "fi")
    end

    test "retries and the circuit breaker count per branch" do
      nodes = three_nodes() |> put_node("a", %{max_retries: 2}) |> put_node("c", %{max_retries: 2})
      %{run: run} = start_three(nodes: nodes)

      :ok = report(run, "c", :failed, "same error")
      :ok = report(run, "c", :failed, "same error")
      assert Repo.get!(NodeExecution, job_for(run, "c").node_execution_id).attempt == 3

      :ok = report(run, "a", :failed, "same error")

      a_retry = Repo.get!(NodeExecution, job_for(run, "a").node_execution_id)
      assert a_retry.attempt == 2
      assert a_retry.run_branch_id == rows(run)["a"].id
      assert rows(run)["a"].state == :running

      :ok = report(run, "a", :failed, "same error")
      :ok = report(run, "a", :failed, "same error")

      a_row = rows(run)["a"]
      assert a_row.state == :ended
      assert a_row.outcome == :failed
      assert a_row.detail =~ "circuit_breaker:"
      assert reload(run).status == :running
    end
  end

  # ── scenario 9: cancel ──────────────────────────────────────────────────────────────────

  describe "cancelling" do
    test "revokes every branch job and ends every branch with no outcome" do
      %{run: run} = start_three()
      jobs = Runs.active_jobs(run)
      assert length(jobs) == 3

      assert {:ok, %Run{status: :cancelled}} = Runs.cancel_run(reload(run))

      for job <- jobs do
        job_id = job.id
        assert Repo.get!(NodeJob, job_id).state == :revoked
        assert_receive {:revoked, %NodeJob{id: ^job_id}}
        assert {:error, :job_not_active} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "late"})
      end

      assert Enum.all?(Runs.list_run_branches(run), &(&1.state == :ended and is_nil(&1.outcome)))
      assert reload(run).status == :cancelled
    end

    test "with max_parallel 2 the queued branch also ends and never gets a job" do
      %{run: run} = start_three(nodes: put_node(three_nodes(), "fo", %{max_parallel: 2}))
      assert rows(run)["c"].state == :queued

      {:ok, _cancelled} = Runs.cancel_run(reload(run))

      assert %{state: :ended, outcome: nil} = rows(run)["c"]
      assert executions(run, "c") == []
    end
  end

  # ── scenario 10: start_run ──────────────────────────────────────────────────────────────

  describe "start_run/3" do
    test "a start edge into a fan_out opens the region and dispatches every branch" do
      {nodes, edges} = from_fo(three_nodes(), three_edges())
      %{card: card, flow: flow} = setup_three(nodes: nodes, edges: edges)

      assert {:ok, run} = Runs.start_run(card, flow)

      for key <- ["a", "b1", "c"] do
        assert_receive {:dispatched, %NodeJob{node_key: ^key} = job}
        assert job.payload["vars"]["prior_detail"] == nil
      end

      assert reload(run).current_node == "fo"
      assert [%NodeExecution{outcome: :succeeded}] = executions(run, "fo")
    end

    test "a flow holding a :human node is refused" do
      nodes = three_nodes() ++ [%{key: "ask", type: :human}]
      edges = three_edges() ++ [%{from: "report", to: "ask", on: :failed}]
      %{card: card, flow: flow} = setup_three(nodes: nodes, edges: edges)

      assert {:error, :unsupported_node_type} = Runs.start_run(card, flow)
    end
  end

  # ── scenario 11: pinning ────────────────────────────────────────────────────────────────

  describe "an exclusive run" do
    test "pins every queued branch job to the runner that claims the first" do
      {nodes, edges} = from_fo(three_nodes(), three_edges())
      %{board: board, card: card, flow: flow} = setup_three(nodes: nodes, edges: edges, isolation: :exclusive)
      {:ok, run} = Runs.start_run(card, flow)

      {:ok, r1} = Runs.upsert_runner(board, %{"name" => "r1", "interval" => 30, "capacity" => %{"exclusive" => 1}})
      {:ok, r2} = Runs.upsert_runner(board, %{"name" => "r2", "interval" => 30, "capacity" => %{"exclusive" => 1}})

      assert {:ok, %NodeJob{} = first} = Runs.claim_next_job(r1, %{"exclusive" => 1}, [])
      assert reload(run).pinned_runner_name == "r1"

      siblings = Enum.reject(Runs.active_jobs(run), &(&1.id == first.id))
      assert length(siblings) == 2
      assert Enum.all?(siblings, &(&1.state == :queued and &1.runner_name == "r1"))

      assert {:ok, nil} = Runs.claim_next_job(r2, %{"exclusive" => 1}, [])

      assert {:ok, %NodeJob{} = second} = Runs.claim_next_job(r1, %{"exclusive" => 0}, [])
      assert {:ok, %NodeJob{} = third} = Runs.claim_next_job(r1, %{"exclusive" => 0}, [])
      assert Enum.sort([second.id, third.id]) == Enum.sort(Enum.map(siblings, & &1.id))
    end
  end

  # ── scenarios 12 and 13: foreach ────────────────────────────────────────────────────────

  defp foreach_attrs do
    %{
      key: "laps",
      isolation: :shared_clean,
      nodes: [
        %{key: "implement", type: :agent, run: "implement {task}", foreach: "card.tasks"},
        %{key: "fo", type: :fan_out},
        %{key: "r1", type: :shell, run: "echo {task_id}"},
        %{key: "r2", type: :shell, run: "echo {task_id}"},
        %{key: "fi", type: :fan_in}
      ],
      edges: [
        %{from: "start", to: "implement"},
        %{from: "implement", to: "fo", on: :succeeded},
        %{from: "fo", to: "r1"},
        %{from: "fo", to: "r2"},
        %{from: "r1", to: "fi", on: :succeeded},
        %{from: "r1", to: "fi", on: :failed},
        %{from: "r2", to: "fi", on: :succeeded},
        %{from: "r2", to: "fi", on: :failed},
        %{from: "fi", to: "implement", on: :succeeded, when: :foreach_remaining},
        %{from: "fi", to: "done", on: :succeeded, when: :foreach_exhausted},
        %{from: "fi", to: "implement", on: :failed}
      ]
    }
  end

  defp start_laps do
    %{board: board, pulls: pulls, works: works} = board_with_stages()
    flow = enabled_flow(board, works, foreach_attrs())
    card = insert(:card, stage: pulls)
    {:ok, _card} = Relay.Cards.set_sub_tasks(card, [%{title: "Alpha"}, %{title: "Beta"}])
    [alpha, beta] = Repo.all(from st in SubTask, where: st.card_id == ^card.id, order_by: :position)
    {:ok, run} = Runs.start_run(card, flow)
    %{run: run, card: card, alpha: alpha, beta: beta}
  end

  describe "a region inside a foreach lap" do
    test "binds the branches to the lap's task and makes the fan_in the loop tail" do
      %{run: run, card: card, alpha: alpha, beta: beta} = start_laps()
      Relay.Events.subscribe(card.board_id)

      :ok = report(run, "implement", :succeeded, "built alpha")
      assert job_for(run, "r1").payload["vars"]["task_id"] == alpha.id
      assert job_for(run, "r2").payload["vars"]["task_id"] == alpha.id

      :ok = report(run, "r1", :succeeded, "r1 ok")
      :ok = report(run, "r2", :succeeded, "r2 ok")

      assert Repo.get!(SubTask, alpha.id).done
      assert job_for(run, "implement").payload["vars"]["task_id"] == beta.id
      # The check-off is broadcast after commit, with the done task on the card a reload renders.
      card_id = card.id
      alpha_id = alpha.id
      assert_receive {:card_upserted, %Card{id: ^card_id, sub_tasks: [%SubTask{id: ^alpha_id, done: true} | _]}}

      :ok = report(run, "implement", :succeeded, "built beta")
      assert job_for(run, "r1").payload["vars"]["task_id"] == beta.id
      :ok = report(run, "r1", :succeeded, "r1 ok")
      :ok = report(run, "r2", :succeeded, "r2 ok")

      assert Repo.get!(SubTask, beta.id).done
      assert reload(run).status == :done
    end

    test "a failed branch fails the join and re-enters the head on the SAME task with the findings" do
      %{run: run, alpha: alpha} = start_laps()

      :ok = report(run, "implement", :succeeded, "built alpha")
      :ok = report(run, "r1", :succeeded, "r1 ok")
      :ok = report(run, "r2", :failed, "r2 broke")

      assert [%NodeExecution{outcome: :failed}] = executions(run, "fi")
      refute Repo.get!(SubTask, alpha.id).done

      vars = job_for(run, "implement").payload["vars"]
      assert vars["task_id"] == alpha.id
      assert vars["findings"] =~ "## r2: failed"
    end
  end

  # ── scenario 14: end to end ─────────────────────────────────────────────────────────────

  describe "end to end" do
    test "a capped region with a looping branch runs to done" do
      %{card: card, flow: flow} = setup_three(nodes: put_node(three_nodes(), "fo", %{max_parallel: 2}))
      {:ok, run} = Runs.start_run(card, flow)

      steps = [
        {"prep", :succeeded, "prepped"},
        {"b1", :failed, "needs fixing"},
        {"b2", :succeeded, "fixed"},
        {"b1", :succeeded, "B ok"},
        {"a", :succeeded, "A ok"},
        {"c", :succeeded, "C ok"}
      ]

      max_running =
        Enum.reduce(steps, running_count(run), fn {key, outcome, detail}, seen ->
          :ok = report(run, key, outcome, detail)
          max(seen, running_count(run))
        end)

      assert max_running <= 2
      assert reload(run).status == :done

      keys = Enum.map(Runs.list_executions(run), & &1.node_key)
      assert hd(keys) == "prep"
      assert Enum.at(keys, 1) == "fo"
      assert List.last(keys) == "fi"
      assert Enum.find_index(keys, &(&1 == "c")) > Enum.find_index(keys, &(&1 == "b2"))

      assert [fi] = executions(run, "fi")
      assert fi.outcome == :succeeded
      assert fi.detail == "## a: succeeded\nA ok\n\n## b1: succeeded\nB ok\n\n## c: succeeded\nC ok"
    end
  end

  # ── scenarios 16 and 17: open_region/1 and the no-region case ───────────────────────────

  describe "open_region/1" do
    test "a flow with no region behaves as before" do
      %{card: card, flow: flow} =
        setup_three(
          nodes: [%{key: "prep", type: :shell, run: "true"}],
          edges: [%{from: "start", to: "prep"}, %{from: "prep", to: "done", on: :succeeded}]
        )

      {:ok, run} = Runs.start_run(card, flow)
      assert Runs.open_region(run) == []
      :ok = report(run, "prep", :succeeded, "prepped")

      assert reload(run).status == :done
      assert Enum.all?(Runs.list_executions(run), &is_nil(&1.run_branch_id))
      assert Runs.open_region(run) == []
      assert Runs.list_run_branches(run) == []
    end

    test "returns the entry's rows while any branch is open, and nothing once the join is done" do
      %{run: run} = start_three()

      :ok = report(run, "a", :succeeded, "A ok")
      :ok = report(run, "c", :succeeded, "C ok")
      assert Enum.map(Runs.open_region(run), & &1.branch) == ["a", "b1", "c"]

      :ok = report(run, "b1", :succeeded, "B ok")
      assert Runs.open_region(run) == []
    end
  end

  describe "a branch removed from the flow mid-run" do
    test "ends its queued row failed instead of starting it" do
      %{run: run, flow: flow} = start_three(nodes: put_node(three_nodes(), "fo", %{max_parallel: 2}))

      edges = three_edges() |> drop_edges("fo", "c") |> drop_edges("c", "fi")
      nodes = Enum.reject(three_nodes(), &(&1.key == "c"))
      {:ok, _flow} = Relay.Flows.update_flow(flow, %{nodes: nodes, edges: edges})

      :ok = report(run, "a", :succeeded, "A ok")

      assert %{state: :ended, outcome: :failed, detail: "branch removed from the flow"} = rows(run)["c"]
      assert executions(run, "c") == []
    end

    test "fails the run when the whole region is gone, rather than crashing the scheduler" do
      %{run: run, flow: flow} = start_three()

      nodes = Enum.reject(three_nodes(), &(&1.key in ["fo", "fi"]))

      edges = [
        %{from: "start", to: "prep"},
        %{from: "prep", to: "a", on: :succeeded},
        %{from: "a", to: "done", on: :succeeded},
        %{from: "b1", to: "done", on: :succeeded},
        %{from: "b2", to: "done", on: :succeeded},
        %{from: "c", to: "done", on: :succeeded},
        %{from: "report", to: "done", on: :succeeded}
      ]

      {:ok, _flow} = Relay.Flows.update_flow(flow, %{nodes: nodes, edges: edges})

      :ok = report(run, "a", :succeeded, "A ok")

      assert %Run{status: :failed, failure_detail: "fan-out region removed from the flow"} = reload(run)
      assert Runs.open_region(run) == []
    end
  end
end
