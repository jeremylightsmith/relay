defmodule Hamaca.Runs.SteerTest do
  @moduledoc """
  RE358 Part 2 — Steer now, server side. `Hamaca.Runs.steer/4` always saves a `:steer` comment
  first; when the card's run is `:running` on an agent node with an active job it stamps that
  attempt `:steered`, revokes it and re-enters the same node as the next attempt of the same visit
  (resuming the stopped attempt's session), otherwise it degrades to a note. The receipt
  (`comments.delivered_execution_id`) is stamped when the next agent job is claimed carrying the
  steer in its guidance; `steer_state/1` and `steer_receipts/1` are the drawer's reads.
  """
  use Hamaca.DataCase, async: true

  import Ecto.Query

  alias Hamaca.Runs
  alias Hamaca.Runs.FakeDispatcher
  alias Hamaca.Runs.Instance
  alias Schemas.Card
  alias Schemas.CardOwner
  alias Schemas.Comment
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run

  @steer "Fold the backfill into Task 3"

  # A known name for this file's engine Listener, so the baton test can drain its mailbox.
  @listener :steer_test_listener

  setup do
    start_engine!(listener: @listener)
    FakeDispatcher.register(self())

    user = insert(:user, name: "Ada Lovelace")
    {:ok, board} = Hamaca.Boards.create_board(user, %{name: "Steer Board"})
    {:ok, flow} = board |> Hamaca.Flows.get_flow!("plan") |> Hamaca.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))

    # The plan flow's write_plan declares it writes `plan` + `tasks` (RE244), so a card that goes
    # on to report `succeeded` must already carry both.
    {:ok, card} =
      Hamaca.Cards.create_card(stage, %{
        title: "Steer the planner",
        spec: "# Spec",
        acceptance_criteria: "1. It works.",
        plan: "# Plan"
      })

    # Inserted directly: `Cards.set_sub_tasks/2` broadcasts a `card_upserted` whose empty owner
    # list the engine's Listener would read, once the run has started, as a human taking the baton.
    insert(:sub_task, card: card, title: "Task 1")

    :ok = Runs.subscribe(board.id)
    :ok = Hamaca.Events.subscribe(board.id)

    {:ok, runner} =
      Runs.upsert_runner(board, %{
        "name" => "steer-runner",
        "capacity" => %{"shared_clean" => 2, "exclusive" => 1},
        "version" => Runs.min_runner_version()
      })

    %{user: user, board: board, flow: flow, card: card, runner: runner}
  end

  ## Helpers

  defp actor(user), do: {:user, user.id}

  defp reload_card(card), do: Repo.get!(Card, card.id)

  defp executions(run) do
    Repo.all(from e in NodeExecution, where: e.run_id == ^run.id, order_by: [asc: e.id])
  end

  defp jobs(run), do: Repo.all(from j in NodeJob, where: j.run_id == ^run.id, order_by: [asc: j.id])

  defp job_for(execution), do: Repo.one!(from j in NodeJob, where: j.node_execution_id == ^execution.id)

  defp claim!(runner) do
    {:ok, %NodeJob{} = job} = Runs.claim_next_job(runner)
    job
  end

  # Starts the plan flow and returns the run plus its dispatched attempt-1 job.
  defp start_plan_run(ctx) do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {run, job}
  end

  defp set_session(%NodeJob{} = job, session_id) do
    NodeExecution
    |> Repo.get!(job.node_execution_id)
    |> Ecto.Changeset.change(session_id: session_id)
    |> Repo.update!()
  end

  defp stop_server(run) do
    case Registry.lookup(Instance.current().registry, run.id) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}

      [] ->
        :ok
    end
  end

  defp force_reenter(run) do
    stop_server(run)
    instance = Instance.current()

    {:ok, pid} =
      DynamicSupervisor.start_child(
        instance.run_supervisor,
        {Hamaca.Runs.RunServer,
         run_id: run.id, mode: {:reenter, nil}, registry: instance.registry, callers: Instance.callers()}
      )

    pid
  end

  # A flow agent_a → precommit (shell) → agent_b on the Spec stage (a stage holds one flow, so
  # the seeded spec flow is cleared first).
  defp shell_flow(board) do
    spec_flow = Hamaca.Flows.get_flow!(board, "spec")
    {:ok, _deleted} = Hamaca.Flows.delete_flow(spec_flow)
    spec = Enum.find(board.stages, &(&1.name == "Spec"))

    {:ok, flow} =
      Hamaca.Flows.create_flow(board, %{
        key: "shelly",
        isolation: :shared_clean,
        stage_id: spec.id,
        nodes: [
          %{key: "agent_a", type: :agent, run: "/a {ref}"},
          %{key: "precommit", type: :shell, run: "mix precommit"},
          %{key: "agent_b", type: :agent, run: "/b {ref}"}
        ],
        edges: [
          %{from: "start", to: "agent_a"},
          %{from: "agent_a", to: "precommit", on: :succeeded},
          %{from: "precommit", to: "agent_b", on: :succeeded},
          %{from: "agent_b", to: "done", on: :succeeded}
        ]
      })

    {:ok, flow} = Hamaca.Flows.enable_flow(flow)
    flow
  end

  # A run of shell_flow/1 sitting on `precommit` with its job queued.
  defp run_on_shell_node(ctx) do
    flow = shell_flow(ctx.board)
    {:ok, run} = Runs.start_run(ctx.card, flow)
    assert_receive {:dispatched, %NodeJob{}}
    agent_a = claim!(ctx.runner)
    {:ok, _run} = Runs.report_outcome(agent_a, %{outcome: :succeeded, detail: "a done"})
    assert_receive {:dispatched, %NodeJob{node_key: "precommit"} = precommit}
    assert Repo.get!(Run, run.id).current_node == "precommit"
    {run, precommit}
  end

  ## steer/4 — restart

  describe "steer/4 on a running agent node" do
    # Scenario 4
    test "stops the claimed attempt and restarts the same node, resuming its session", ctx do
      {run, _job} = start_plan_run(ctx)
      claimed = claim!(ctx.runner)
      set_session(claimed, "sess-1")

      assert {:ok, %Comment{kind: :steer, body: @steer}, :restarted} =
               Runs.steer(ctx.card, actor(ctx.user), @steer, [])

      assert [attempt1, attempt2] = executions(run)
      assert attempt1.outcome == :steered
      assert attempt1.finished_at
      assert attempt1.detail == nil
      assert Repo.get!(NodeJob, claimed.id).state == :revoked

      assert attempt2.node_key == "write_plan"
      assert attempt2.visit == attempt1.visit
      assert attempt2.attempt == 2
      assert attempt2.outcome == nil

      new_job = job_for(attempt2)
      assert new_job.state == :queued
      assert new_job.payload["resume_session"] == "sess-1"

      run = Repo.get!(Run, run.id)
      assert run.status == :running
      assert run.current_node == "write_plan"
    end

    # Scenario 5
    test "an attempt with no known session restarts on a fresh session", ctx do
      {run, _job} = start_plan_run(ctx)
      _claimed = claim!(ctx.runner)

      assert {:ok, %Comment{kind: :steer}, :restarted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])

      assert [_steered, attempt2] = executions(run)
      assert job_for(attempt2).payload["resume_session"] == nil
    end

    # Task 3 · Scenario 5 (acceptance criterion 5, server half)
    test "a session the heartbeat recorded is the one the restart resumes", ctx do
      {run, _job} = start_plan_run(ctx)
      claimed = claim!(ctx.runner)

      :ok = Runs.record_job_sessions(ctx.board, %{"#{claimed.id}" => "sess-live"})

      assert {:ok, %Comment{kind: :steer}, :restarted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])

      assert [_steered, attempt2] = executions(run)
      assert job_for(attempt2).payload["resume_session"] == "sess-live"
      assert Repo.get!(Run, run.id).status == :running
    end

    # Scenario 6
    test "the restarted job carries the steer as guidance and claiming it stamps the receipt", ctx do
      {run, _job} = start_plan_run(ctx)
      claimed = claim!(ctx.runner)
      set_session(claimed, "sess-1")

      {:ok, comment, :restarted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])
      assert Repo.get!(Comment, comment.id).delivered_execution_id == nil

      restarted = claim!(ctx.runner)
      assert restarted.payload["vars"]["guidance"] =~ "· STEER\n#{@steer}"

      [_steered, attempt2] = executions(run)
      assert restarted.node_execution_id == attempt2.id
      assert Repo.get!(Comment, comment.id).delivered_execution_id == attempt2.id
    end

    # Scenario 7 (acceptance criterion 7)
    test "three steers in a row never trip the RE410 outcome-less cap", ctx do
      {run, _job} = start_plan_run(ctx)
      _claimed = claim!(ctx.runner)

      assert Runs.max_outcomeless_reentries() == 3

      for n <- 1..3 do
        assert {:ok, %Comment{}, :restarted} = Runs.steer(ctx.card, actor(ctx.user), "steer #{n}", [])
        _restarted = claim!(ctx.runner)
      end

      run = Repo.get!(Run, run.id)
      assert run.status == :running
      assert run.current_node == "write_plan"
      refute reload_card(ctx.card).status == :needs_input

      execs = executions(run)
      assert Enum.map(execs, & &1.attempt) == [1, 2, 3, 4]
      assert Enum.map(execs, & &1.outcome) == [:steered, :steered, :steered, nil]
      assert Enum.all?(execs, &(&1.node_key == "write_plan" and &1.visit == 1))
    end

    # Scenario 8 (RE410 interaction)
    test "a :steered row breaks the outcome-less streak, so a forced re-entry enters instead of parking", ctx do
      {run, _job} = start_plan_run(ctx)

      # attempts 1 and 2 abandoned outcome-nil by re-entries; attempt 3 is the live one.
      for _ <- 1..2 do
        force_reenter(run)
        assert_receive {:dispatched, %NodeJob{}}
      end

      assert {:ok, _comment, :restarted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])
      assert_receive {:dispatched, %NodeJob{}}

      assert Enum.map(executions(run), & &1.outcome) == [nil, nil, :steered, nil]

      force_reenter(run)
      assert_receive {:dispatched, %NodeJob{} = entered}
      refute_receive {:run_parked, _}, 100

      assert Repo.get!(Run, run.id).status == :running
      assert Repo.get!(NodeExecution, entered.node_execution_id).attempt == 5
      assert Enum.map(executions(run), & &1.outcome) == [nil, nil, :steered, nil, nil]
    end

    test "a re-entry after a steer still carries the last real failure as findings", ctx do
      {run, _job} = start_plan_run(ctx)

      # An earlier real failure in this run, then a re-entry that enters attempt 3 after it.
      Repo.insert!(%NodeExecution{
        run_id: run.id,
        node_key: "write_plan",
        visit: 1,
        attempt: 2,
        outcome: :failed,
        detail: "the real failure"
      })

      force_reenter(run)
      assert_receive {:dispatched, %NodeJob{}}

      # The steer stamps attempt 3 — now the run's newest outcome row is :steered, not :failed.
      assert {:ok, _comment, :restarted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])
      assert_receive {:dispatched, %NodeJob{}}

      force_reenter(run)
      assert_receive {:dispatched, %NodeJob{} = entered}
      assert entered.payload["vars"]["findings"] == "the real failure"
    end

    # Scenario 12
    test "the restarted job keeps the steered job's findings and prior_detail", ctx do
      {run, job} = start_plan_run(ctx)

      vars = Map.merge(job.payload["vars"], %{"findings" => "fix the CSV", "prior_detail" => "review said no"})

      job
      |> Ecto.Changeset.change(payload: Map.put(job.payload, "vars", vars))
      |> Repo.update!()

      assert {:ok, _comment, :restarted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])

      [_steered, attempt2] = executions(run)
      new_vars = job_for(attempt2).payload["vars"]
      assert new_vars["findings"] == "fix the CSV"
      assert new_vars["prior_detail"] == "review said no"
    end

    # Scenario 17
    test "broadcasts the comment, the steered finish and the restarted start, and dispatches the new job", ctx do
      card_id = ctx.card.id
      {_run, _job} = start_plan_run(ctx)
      _claimed = claim!(ctx.runner)

      assert {:ok, comment, :restarted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])

      assert_receive {:timeline_appended, ^card_id, %Comment{kind: :steer} = appended}
      assert appended.id == comment.id
      assert_receive {:node_finished, %Run{}, %NodeExecution{outcome: :steered}}
      assert_receive {:node_started, %Run{}, %NodeExecution{attempt: 2}}
      assert_receive {:revoked, %NodeJob{}}
      assert_receive {:dispatched, %NodeJob{} = dispatched}
      assert dispatched.state == :queued
      assert Repo.get!(NodeExecution, dispatched.node_execution_id).attempt == 2
    end

    # Scenario 20
    test "a steer on a still-queued job revokes it and queues a new attempt", ctx do
      {run, job} = start_plan_run(ctx)
      assert job.state == :queued

      assert {:ok, _comment, :restarted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])

      assert Repo.get!(NodeJob, job.id).state == :revoked
      assert [attempt1, attempt2] = executions(run)
      assert attempt1.outcome == :steered
      assert attempt2.attempt == 2
      assert job_for(attempt2).state == :queued
    end
  end

  ## steer/4 — degrade to a note

  describe "steer/4 degrades to a note" do
    # Scenario 9 (acceptance criterion 8)
    test "on a shell node it is noted, and the next agent job's claim delivers it", ctx do
      {run, precommit} = run_on_shell_node(ctx)
      jobs_before = jobs(run)

      assert {:ok, %Comment{kind: :steer} = comment, :noted} =
               Runs.steer(ctx.card, actor(ctx.user), "use approach B", [])

      assert jobs(run) == jobs_before
      refute_receive {:revoked, _}, 50
      assert Repo.get!(Comment, comment.id).delivered_execution_id == nil

      # The shell job's claim does not deliver it.
      claimed_precommit = claim!(ctx.runner)
      assert claimed_precommit.id == precommit.id
      assert Repo.get!(Comment, comment.id).delivered_execution_id == nil

      {:ok, _run} = Runs.report_outcome(claimed_precommit, %{outcome: :succeeded})
      assert_receive {:dispatched, %NodeJob{node_key: "agent_b"}}
      agent_b = claim!(ctx.runner)
      assert agent_b.node_key == "agent_b"

      assert Repo.get!(Comment, comment.id).delivered_execution_id == agent_b.node_execution_id
      assert Runs.steer_receipts(reload_card(ctx.card))[comment.id].node == "agent_b"
    end

    # Scenario 10
    test "on a parked run it is noted and nothing about the run changes", ctx do
      {run, job} = start_plan_run(ctx)
      {:ok, _} = Runs.report_outcome(claim!(ctx.runner), %{outcome: :needs_input, detail: "which one?"})
      assert Repo.get!(Run, run.id).status == :parked
      assert job.id

      execs_before = executions(run)
      jobs_before = jobs(run)

      assert {:ok, %Comment{kind: :steer}, :noted} = Runs.steer(reload_card(ctx.card), actor(ctx.user), @steer, [])

      assert executions(run) == execs_before
      assert jobs(run) == jobs_before
    end

    # Scenario 10
    test "with no run at all it is noted", ctx do
      assert Runs.active_run(ctx.card) == nil
      assert {:ok, %Comment{kind: :steer, body: @steer}, :noted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])
    end

    # Scenario 11
    test "a blank steer is a changeset error and stamps or revokes nothing", ctx do
      {run, _job} = start_plan_run(ctx)
      _claimed = claim!(ctx.runner)
      execs_before = executions(run)
      jobs_before = jobs(run)

      assert {:error, %Ecto.Changeset{}} = Runs.steer(ctx.card, actor(ctx.user), "", [])

      assert executions(run) == execs_before
      assert jobs(run) == jobs_before
      assert Repo.aggregate(from(c in Comment, where: c.card_id == ^ctx.card.id and c.kind == :steer), :count) == 0
    end
  end

  ## steer_state/1

  describe "steer_state/1" do
    # Scenario 13
    test "names the running agent node, and reads restarting? only until the new job is claimed", ctx do
      {_run, _job} = start_plan_run(ctx)
      _claimed = claim!(ctx.runner)

      assert Runs.steer_state(ctx.card) == %{node: "write_plan", restarting?: false}

      {:ok, _comment, :restarted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])
      assert Runs.steer_state(ctx.card) == %{node: "write_plan", restarting?: true}

      _restarted = claim!(ctx.runner)
      assert Runs.steer_state(ctx.card) == %{node: "write_plan", restarting?: false}
    end

    # Scenario 14
    test "is nil on a shell node", ctx do
      {_run, _precommit} = run_on_shell_node(ctx)
      assert Runs.steer_state(ctx.card) == nil
    end

    # Scenario 14
    test "is nil on a parked run", ctx do
      {run, _job} = start_plan_run(ctx)
      {:ok, _} = Runs.report_outcome(claim!(ctx.runner), %{outcome: :needs_input, detail: "which one?"})
      assert Repo.get!(Run, run.id).status == :parked

      assert Runs.steer_state(ctx.card) == nil
    end

    # Scenario 14
    test "is nil while a human holds the baton", ctx do
      {run, _job} = start_plan_run(ctx)

      # A human taking the baton parks the run once the Listener next reconciles the card. Drain
      # the Listener first, then swap the owner rows directly (no broadcast), so the run is still
      # :running on write_plan while only the baton has changed.
      _ = :sys.get_state(Process.whereis(@listener))
      Repo.delete_all(from o in CardOwner, where: o.card_id == ^ctx.card.id)
      Repo.insert!(%CardOwner{card_id: ctx.card.id, actor_type: :user, user_id: ctx.user.id})

      assert %Run{status: :running, current_node: "write_plan"} = Repo.get!(Run, run.id)
      assert Runs.steer_state(ctx.card) == nil
    end
  end

  ## steer_receipts/1

  describe "steer_receipts/1" do
    # Scenario 15
    test "names the node, whether the session was kept, and the attempt's reply once it reports", ctx do
      {run, _job} = start_plan_run(ctx)
      set_session(claim!(ctx.runner), "sess-1")

      {:ok, comment, :restarted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])
      attempt2_job = claim!(ctx.runner)
      assert attempt2_job.payload["resume_session"] == "sess-1"

      assert Runs.steer_receipts(ctx.card) == %{
               comment.id => %{node: "write_plan", session_kept?: true, reply: nil}
             }

      detail = "Dropped the migration task.\n\nMore detail."
      {:ok, _run} = Runs.report_outcome(attempt2_job, %{outcome: :succeeded, detail: detail})

      attempt2 = Repo.get!(NodeExecution, attempt2_job.node_execution_id)
      assert attempt2.outcome == :succeeded
      assert Enum.count(executions(run)) == 2

      assert Runs.steer_receipts(ctx.card)[comment.id] == %{
               node: "write_plan",
               session_kept?: true,
               reply: %{detail: detail, at: attempt2.finished_at}
             }
    end

    test "an undelivered steer has no receipt", ctx do
      {_run, _job} = start_plan_run(ctx)
      {:ok, _comment, :restarted} = Runs.steer(ctx.card, actor(ctx.user), @steer, [])

      assert Runs.steer_receipts(ctx.card) == %{}
    end
  end

  ## The claim's :run_changed signal

  describe "claim_next_job/3 broadcasts :run_changed" do
    # Scenario 16
    test "when it claims a flow job", ctx do
      card_id = ctx.card.id
      {_run, _job} = start_plan_run(ctx)
      _claimed = claim!(ctx.runner)

      assert_receive {:run_changed, ^card_id}
    end

    # Scenario 16
    test "but not when it claims a talk job", ctx do
      talk = Runs.insert_talk_job!(ctx.card, %{"vars" => %{}}, nil)
      claimed = claim!(ctx.runner)
      assert claimed.id == talk.id

      refute_receive {:run_changed, _}, 100
    end
  end
end
