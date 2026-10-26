defmodule Hamaca.Runs.FanOutParkTest do
  @moduledoc """
  RE437 task 3: an open fan-out region survives everything that interrupts a run — a branch that
  parks while its siblings keep running, the answer that re-enters only the parked branches, a
  server restart, a hand-back, a lost runner, the per-branch outcome-less cap, and a retry aimed
  inside the region.
  """

  use Hamaca.DataCase, async: true

  import Hamaca.FanOutFixtures, only: [put_node: 3, drop_edges: 3, three_nodes: 0, three_edges: 0]

  alias Hamaca.Agents
  alias Hamaca.Runs
  alias Hamaca.Runs.FakeDispatcher
  alias Hamaca.Runs.Instance
  alias Schemas.Card
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run

  # A known name for this file's Listener, so a test can drain its mailbox (:sys.get_state/1)
  # before a step the Listener would otherwise race — module-scoped so no other async file shares it.
  @listener :fan_out_park_test_listener

  setup do
    # Engine FIRST, before any run exists: its boot-time resume_all/0 must only ever see zero rows.
    start_engine!(listener: @listener)
    FakeDispatcher.register(self())
    :ok
  end

  # ── fixture: `three`, plus `a → needs_input` on partial ─────────────────────────────────

  defp park_edges, do: three_edges() ++ [%{from: "a", to: "needs_input", on: :partial}]

  defp setup_three(opts \\ []) do
    board = Keyword.get_lazy(opts, :board, fn -> insert(:board) end)
    pulls = insert(:stage, board: board, name: "Plan:Done", position: 1)
    works = insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 2)
    insert(:stage, board: board, name: "Review", category: :in_progress, type: :review, position: 3)

    attrs = %{
      key: "three",
      isolation: Keyword.get(opts, :isolation, :shared_clean),
      nodes: Keyword.get(opts, :nodes, three_nodes()),
      edges: Keyword.get(opts, :edges, park_edges()),
      stage_id: works.id
    }

    {:ok, flow} = Hamaca.Flows.create_flow(board, attrs)
    {:ok, flow} = Hamaca.Flows.enable_flow(flow)
    card = insert(:card, stage: pulls)
    :ok = Runs.subscribe(board.id)
    %{board: board, flow: flow, card: card}
  end

  # The region is open: `prep` succeeded, every branch the cap allows is running.
  defp start_three(opts \\ []) do
    %{card: card, flow: flow} = ctx = setup_three(opts)
    {:ok, run} = Runs.start_run(card, flow)
    :ok = report(run, "prep", :succeeded, "prepped")
    Map.put(ctx, :run, run)
  end

  # Scenario 1's state: `a` asked "Which DB?" and parked the run; `b1` and `c` still run.
  defp park_a(opts \\ []) do
    %{run: run} = ctx = start_three(opts)
    :ok = report(run, "a", :needs_input, "Which DB?", Keyword.get(opts, :a_attrs, %{}))
    assert_receive {:run_parked, %Run{status: :parked}}
    ctx
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────

  defp job_for(run, node_key) do
    case Enum.filter(Runs.active_jobs(run), &(&1.node_key == node_key)) do
      [job] -> job
      other -> flunk("expected one active #{node_key} job, got #{length(other)}")
    end
  end

  defp report(run, node_key, outcome, detail, extra \\ %{}) do
    attrs = Map.merge(%{outcome: outcome, detail: detail}, extra)
    assert {:ok, _run} = Runs.report_outcome(job_for(run, node_key), attrs)
    :ok
  end

  defp rows(run), do: Map.new(Runs.list_run_branches(run), &{&1.branch, &1})

  defp executions(run, node_key) do
    Repo.all(from e in NodeExecution, where: e.run_id == ^run.id and e.node_key == ^node_key, order_by: e.id)
  end

  defp jobs(run), do: Repo.all(from j in NodeJob, where: j.run_id == ^run.id, order_by: j.id)

  defp revoked_jobs(run), do: Enum.filter(jobs(run), &(&1.state == :revoked))

  defp reload(run), do: Repo.get!(Run, run.id)

  defp question_bodies(card) do
    for %Schemas.Comment{kind: :question, body: body} <- Hamaca.Activity.list_timeline(Repo.get!(Card, card.id)),
        do: body
  end

  defp server(run) do
    case Registry.lookup(Instance.current().registry, run.id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  # Asserts no RunServer outlives the call: either none is registered, or the registered one is
  # already on its way down.
  defp assert_no_server(run) do
    case server(run) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  defp stop_server(run) do
    case server(run) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  # Drops every dispatch/revoke message received so far, so the next assert_receive sees only
  # what the step under test sends.
  defp flush_dispatches do
    receive do
      {:dispatched, _job} -> flush_dispatches()
      {:revoked, _job} -> flush_dispatches()
    after
      0 -> :ok
    end
  end

  # Waits until the run's server has finished its start mode (re-entry runs in handle_continue,
  # after the call that started it returned). A server that already stopped is done too.
  defp await_server(run) do
    case server(run) do
      nil ->
        :ok

      pid ->
        try do
          _ = :sys.get_state(pid)
          :ok
        catch
          :exit, _gone -> :ok
        end
    end
  end

  # A restart: the server goes away, then boot resume runs.
  defp restart(run) do
    stop_server(run)
    flush_dispatches()
    :ok = Runs.resume_all()
    await_server(run)
  end

  # The answer, the way a human gives it: the card leaves :needs_input and the Listener resumes.
  defp answer(%{board: board, card: card}) do
    user = insert(:user)
    flush_dispatches()
    {:ok, _card} = Hamaca.Cards.answer_input(Hamaca.Cards.get_card(board, card.id), "Postgres", {:user, user.id})
    assert_receive {:run_resumed, %Run{status: :running}}
    :ok
  end

  defp revoke_directly(job) do
    job |> Ecto.Changeset.change(state: :revoked) |> Repo.update!()
  end

  # ── scenarios 1–5: a branch parks, its siblings keep going ──────────────────────────────

  describe "a branch that parks" do
    test "parks the run and the card but revokes no sibling job (scenario 1)" do
      %{run: run, card: card} = start_three()
      siblings = Enum.filter(Runs.active_jobs(run), &(&1.node_key in ["b1", "c"]))

      :ok = report(run, "a", :needs_input, "Which DB?")

      assert %{state: :parked, current_node: "a"} = rows(run)["a"]
      assert %Run{status: :parked, parked_reason: :needs_input} = reload(run)
      assert Repo.get!(Card, card.id).status == :needs_input

      for sibling <- siblings do
        assert Repo.get!(NodeJob, sibling.id).state in NodeJob.active_states()
      end

      assert revoked_jobs(run) == []
    end

    test "via the needs_input sentinel edge keeps the reporting node as the row's current node" do
      %{run: run} = start_three()

      :ok = report(run, "a", :partial, "half done, which way?")

      assert %{state: :parked, current_node: "a"} = rows(run)["a"]
      assert %Run{status: :parked, parked_reason: :needs_input} = reload(run)
    end

    test "a sibling's success is recorded while the run stays parked, with no join (scenario 2)" do
      %{run: run} = park_a()

      assert {:ok, _run} = Runs.report_outcome(job_for(run, "c"), %{outcome: :succeeded, detail: "C ok"})

      assert %{state: :ended, outcome: :succeeded} = rows(run)["c"]
      assert reload(run).status == :parked
      assert executions(run, "fi") == []
      assert_no_server(run)
    end

    test "a sibling ending does not start a queued branch while parked (scenario 3)" do
      %{run: run} = park_a(nodes: put_node(three_nodes(), "fo", %{max_parallel: 2}))
      assert rows(run)["c"].state == :queued

      :ok = report(run, "b1", :succeeded, "B ok")

      assert rows(run)["b1"].state == :ended
      assert rows(run)["c"].state == :queued
      assert executions(run, "c") == []
    end

    test "a sibling's failure routes inside its branch while parked (scenario 4)" do
      %{run: run} = park_a()
      b1_row = rows(run)["b1"]

      :ok = report(run, "b1", :failed, "needs fixing")

      b2 = job_for(run, "b2")
      assert Repo.get!(NodeExecution, b2.node_execution_id).run_branch_id == b1_row.id
      b2_id = b2.id
      assert_receive {:dispatched, %NodeJob{id: ^b2_id}}
      assert reload(run).status == :parked
    end

    test "a sibling routed to a node whose agent is refused records the refusal before the server stops" do
      board = insert(:board)
      Agents.ensure_seeded!(board)
      gemini = Enum.find(Agents.list_harnesses(board), &(&1.key == "gemini-cli"))

      {:ok, _agent} =
        Agents.create_agent(board, %{"name" => "Gemini Pro", "harness_id" => gemini.id, "model" => "gemini-2.5-pro"})

      %{run: run} = park_a(board: board, nodes: put_node(three_nodes(), "b2", %{llm: "Gemini Pro"}))
      # The agent turns red after the run started: b2's job is refused when it is enqueued.
      {:ok, _harness} = Agents.update_harness(gemini, %{"models" => ["gemini-2.5-flash"]})

      :ok = report(run, "b1", :failed, "needs fixing")

      assert [%NodeExecution{outcome: :blocked} = b2] = executions(run, "b2")
      assert b2.detail =~ "Gemini Pro"
      assert rows(run)["b1"].state == :parked
      assert reload(run).status == :parked
      assert Enum.filter(Runs.active_jobs(run), &(&1.node_key == "b2")) == []
    end

    test "a second branch asking parks its row too, without a second question (scenario 5)" do
      %{run: run, card: card} = park_a()

      :ok = report(run, "c", :needs_input, "Which port?")

      assert rows(run)["c"].state == :parked
      assert %Run{status: :parked, parked_reason: :needs_input} = reload(run)
      assert Repo.get!(Card, card.id).status == :needs_input
      assert question_bodies(card) == ["Which DB?"]
    end
  end

  # ── scenarios 6–9: the answer re-enters only the parked branches ────────────────────────

  describe "answering" do
    test "re-enters only the parked branch and leaves the sibling's job alone (scenario 6)" do
      %{run: run} = ctx = park_a()
      :ok = report(run, "c", :succeeded, "C ok")
      b1_job = job_for(run, "b1")
      a_row = rows(run)["a"]

      :ok = answer(ctx)
      assert_receive {:dispatched, %NodeJob{node_key: "a"}}

      assert reload(run).status == :running
      assert %{state: :running} = rows(run)["a"]
      assert [first, second] = executions(run, "a")
      assert {second.visit, second.attempt, second.run_branch_id} == {first.visit, 2, a_row.id}
      assert job_for(run, "b1").id == b1_job.id
      assert revoked_jobs(run) == []
    end

    test "after the answer, the branches finish and the join completes the run (scenario 7)" do
      %{run: run} = ctx = park_a()
      :ok = report(run, "c", :succeeded, "C ok")
      :ok = answer(ctx)
      assert_receive {:dispatched, %NodeJob{node_key: "a"}}

      :ok = report(run, "a", :succeeded, "A ok")
      :ok = report(run, "b1", :succeeded, "B ok")

      assert [%NodeExecution{outcome: :succeeded}] = executions(run, "fi")
      assert reload(run).status == :done
    end

    test "one answer re-enters every parked branch (scenario 8)" do
      %{run: run} = ctx = park_a()
      :ok = report(run, "c", :needs_input, "Which port?")
      b1_job = job_for(run, "b1")

      :ok = answer(ctx)
      assert_receive {:dispatched, %NodeJob{node_key: "a"}}
      assert_receive {:dispatched, %NodeJob{node_key: "c"}}

      assert length(executions(run, "a")) == 2
      assert length(executions(run, "c")) == 2
      assert %{"a" => %{state: :running}, "c" => %{state: :running}} = rows(run)
      assert job_for(run, "b1").id == b1_job.id
      assert revoked_jobs(run) == []
    end

    test "a parked branch resumes its own session, not the run-level one (scenario 9)" do
      %{run: run} = park_a(a_attrs: %{session_id: "sess-a"})
      flush_dispatches()

      assert {:ok, _run} = Runs.resume_run(reload(run), resume_session: "sess-other")

      assert_receive {:dispatched, %NodeJob{node_key: "a"} = job}
      assert job.payload["resume_session"] == "sess-a"
    end
  end

  # ── scenarios 10 and 11: restart ────────────────────────────────────────────────────────

  describe "a server restart mid-region" do
    test "re-dispatches the running branch that lost its job and keeps the others (scenario 10)" do
      %{run: run} = start_three()
      a_job = job_for(run, "a")
      b1_job = job_for(run, "b1")
      revoke_directly(job_for(run, "c"))

      :ok = restart(run)

      assert Repo.get!(NodeJob, a_job.id).state == a_job.state
      assert Repo.get!(NodeJob, b1_job.id).state == b1_job.state
      assert job_for(run, "a").id == a_job.id
      assert job_for(run, "b1").id == b1_job.id

      assert [first, second] = executions(run, "c")
      assert {second.visit, second.attempt} == {first.visit, 2}
      assert job_for(run, "c").node_execution_id == second.id
      assert executions(run, "fi") == []
    end

    test "with every running branch holding a job creates and revokes nothing (scenario 11)" do
      %{run: run} = start_three()
      before_executions = Runs.list_executions(run)
      before_jobs = jobs(run)

      :ok = restart(run)

      assert Runs.list_executions(run) == before_executions
      assert Enum.map(jobs(run), &{&1.id, &1.state}) == Enum.map(before_jobs, &{&1.id, &1.state})
    end
  end

  # ── scenarios 12 and 13: hand-back and runner-gone ──────────────────────────────────────

  describe "a resume after every job was revoked" do
    test "a hand-back re-dispatches every running branch as a fresh attempt (scenario 12)" do
      %{run: run} = start_three()
      old = Runs.active_jobs(run)

      # No card event may still be queued for the Listener: one landing after the park would
      # hand the (AI-owned) card back before the test does.
      _ = :sys.get_state(@listener)
      :ok = Runs.park_claimed(reload(run))
      assert %Run{status: :parked, parked_reason: :claimed} = reload(run)
      flush_dispatches()

      assert {:ok, _run} = Runs.resume_run(reload(run))
      await_server(run)
      for key <- ["a", "b1", "c"], do: assert_receive({:dispatched, %NodeJob{node_key: ^key}})

      assert Enum.all?(old, &(Repo.get!(NodeJob, &1.id).state == :revoked))

      for key <- ["a", "b1", "c"] do
        assert [_first, second] = executions(run, key)
        assert second.attempt == 2
        assert job_for(run, key).node_execution_id == second.id
      end

      assert Enum.all?(Runs.list_run_branches(run), &(&1.state == :running))
      assert reload(run).status == :running
    end

    test "a runner-gone resume re-dispatches every branch pinned to the same runner (scenario 13)" do
      {nodes, edges} = {Enum.reject(three_nodes(), &(&1.key == "prep")), park_edges()}
      edges = edges |> drop_edges("start", "prep") |> drop_edges("prep", "fo")
      edges = [%{from: "start", to: "fo"} | edges]
      %{board: board, card: card, flow: flow} = setup_three(nodes: nodes, edges: edges, isolation: :exclusive)
      {:ok, run} = Runs.start_run(card, flow)

      {:ok, r1} = Runs.upsert_runner(board, %{"name" => "r1", "interval" => 30, "capacity" => %{"exclusive" => 1}})
      assert {:ok, %NodeJob{}} = Runs.claim_next_job(r1, %{"exclusive" => 1}, [])
      old = Runs.active_jobs(run)

      :ok = Runs.park_for_reclaim(reload(run))
      assert %Run{status: :parked, parked_reason: :runner_gone} = reload(run)
      flush_dispatches()
      assert {:ok, _run} = Runs.resume_run(reload(run))
      await_server(run)
      for key <- ["a", "b1", "c"], do: assert_receive({:dispatched, %NodeJob{node_key: ^key}})

      fresh = Runs.active_jobs(run)
      assert length(fresh) == 3
      assert MapSet.disjoint?(MapSet.new(fresh, & &1.id), MapSet.new(old, & &1.id))
      assert Enum.all?(fresh, &(&1.runner_name == "r1"))

      for key <- ["a", "b1", "c"] do
        assert [_first, %NodeExecution{attempt: 2}] = executions(run, key)
      end
    end
  end

  # ── scenario 14: the per-branch outcome-less cap ────────────────────────────────────────

  describe "the per-branch outcome-less cap" do
    test "parks the branch and the run instead of looping, leaving the siblings alone (scenario 14)" do
      %{run: run} = start_three()
      a_job = job_for(run, "a")
      b1_job = job_for(run, "b1")
      c_job = revoke_directly(job_for(run, "c"))
      c_first = Repo.get!(NodeExecution, c_job.node_execution_id)

      for attempt <- 2..Runs.max_outcomeless_reentries()//1 do
        Runs.insert_execution!(run, "c", c_first.visit, attempt, nil, c_first.run_branch_id)
      end

      :ok = restart(run)
      assert_receive {:run_parked, %Run{status: :parked}}

      streak = executions(run, "c")
      assert length(streak) == Runs.max_outcomeless_reentries()
      newest = List.last(streak)
      assert newest.outcome == :needs_input

      assert newest.detail ==
               "`c` was re-entered #{Runs.max_outcomeless_reentries()} times in a row without any attempt " <>
                 "reporting an outcome — usually a server restart killing the job it was running (RE410). " <>
                 "Parked so it can't loop. Check whether the node's side effects (a deploy, a push) already " <>
                 "happened, then answer to resume it."

      assert rows(run)["c"].state == :parked
      assert %Run{status: :parked, parked_reason: :needs_input} = reload(run)
      assert Repo.get!(NodeJob, a_job.id).state == :queued
      assert Repo.get!(NodeJob, b1_job.id).state == :queued
    end
  end

  # ── scenarios 15 and 16: retry inside a region ──────────────────────────────────────────

  defp assert_fresh_region(run, old_fo) do
    run = reload(run)
    assert run.status == :running
    assert run.current_node == "fo"

    assert [^old_fo, new_fo] = executions(run, "fo")
    assert new_fo.visit == old_fo.visit + 1

    fresh_rows = Enum.filter(Runs.list_run_branches(run), &(&1.fan_out_execution_id == new_fo.id))
    assert Enum.map(fresh_rows, & &1.branch) == ["a", "b1", "c"]

    for key <- ["a", "b1", "c"] do
      assert_receive {:dispatched, %NodeJob{node_key: ^key} = job}
      assert Repo.get!(NodeExecution, job.node_execution_id).run_branch_id in Enum.map(fresh_rows, & &1.id)
    end
  end

  describe "a retry inside a region" do
    test "at a branch node re-opens the whole region (scenario 15)" do
      %{run: run} = start_three()
      [old_fo] = executions(run, "fo")
      old_rows = Runs.list_run_branches(run)

      stop_server(run)
      Runs.fail_run(reload(run), "boom")
      assert Enum.all?(Runs.list_run_branches(run), &(&1.state == :ended and is_nil(&1.outcome)))

      flush_dispatches()
      assert {:ok, _run} = Runs.retry_run(reload(run), at: "b2")
      await_server(run)

      assert_fresh_region(run, old_fo)
      assert length(Runs.list_run_branches(run)) == length(old_rows) + 3
    end

    test "at the fan_in re-opens the whole region (scenario 16)" do
      nodes = Enum.reject(three_nodes(), &(&1.key == "report"))
      edges = park_edges() |> drop_edges("fi", "report") |> drop_edges("report", "done")
      %{run: run} = start_three(nodes: nodes, edges: edges)
      [old_fo] = executions(run, "fo")

      :ok = report(run, "a", :succeeded, "A ok")
      :ok = report(run, "b1", :succeeded, "B ok")
      :ok = report(run, "c", :failed, "C broke")

      assert reload(run).status == :failed
      assert List.last(Runs.list_executions(run)).node_key == "fi"

      flush_dispatches()
      assert {:ok, _run} = Runs.retry_run(reload(run))
      await_server(run)

      assert_fresh_region(run, old_fo)
    end
  end

  # ── scenario 17: a whole-run park outside any region ────────────────────────────────────

  describe "a run parked outside any region" do
    test "refuses every late report, revoked or not (scenario 17)" do
      %{card: card, flow: flow} = setup_three()
      {:ok, run} = Runs.start_run(card, flow)
      prep_job = job_for(run, "prep")

      :ok = report(run, "prep", :needs_input, "Which env?")
      assert %Run{status: :parked, parked_reason: :needs_input} = reload(run)

      run = reload(run)
      [prep] = executions(run, "prep")
      live = Runs.insert_job!(run, Runs.insert_execution!(run, "prep", prep.visit, 2), %{})
      revoked = revoke_directly(Runs.insert_job!(run, Runs.insert_execution!(run, "prep", prep.visit, 3), %{}))

      for job <- [prep_job, live, revoked] do
        assert {:error, :job_not_active} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "late"})
      end

      assert reload(run).status == :parked
    end
  end
end
