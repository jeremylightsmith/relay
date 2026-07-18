defmodule Relay.RunsTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run

  setup do
    FakeDispatcher.register(self())
    start_supervised!(Relay.Runs.Supervisor)

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Runs Board"})
    :ok = Runs.subscribe(board.id)
    %{user: user, board: board}
  end

  defp enabled_spec_flow(board) do
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    flow
  end

  defp card_in(board, stage_name, title \\ "Try the engine") do
    stage = Enum.find(board.stages, &(&1.name == stage_name))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: title})
    card
  end

  defp retry_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    plan = Enum.find(board.stages, &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "retry",
        isolation: :shared_clean,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: plan.id,
        nodes: [
          %{key: "work", type: :agent, run: "work {ref}", max_retries: 1},
          %{key: "fallback", type: :agent, run: "fallback {ref}"}
        ],
        edges: [
          %{from: "start", to: "work"},
          %{from: "work", to: "done", on: :succeeded},
          %{from: "work", to: "fallback", on: :failed},
          %{from: "fallback", to: "done", on: :succeeded}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  describe "start_run/3" do
    test "runs a spec-shaped flow start → done, moving the card and broadcasting each transition",
         %{board: board} do
      flow = enabled_spec_flow(board)
      card = card_in(board, "Next up")

      assert {:ok, %Run{status: :running, current_node: "brainstorm"} = run} = Runs.start_run(card, flow)
      assert_receive {:run_started, %Run{id: run_id}}
      assert run.id == run_id
      assert_receive {:node_started, _run, %NodeExecution{node_key: "brainstorm", visit: 1, attempt: 1}}
      assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"} = job}

      # The move claimed the card for Relay AI and snapped it :working in Spec.
      card = Relay.Cards.get_card(board, card.id)
      assert card.stage_id == flow.works_in_stage_id
      assert card.status == :working
      assert Relay.Cards.active_owner_type(card) == :ai

      # The queued job carries the executor contract.
      assert %NodeJob{state: :queued} = found = Runs.active_job(run)
      assert found.id == job.id
      assert found.payload["run"] == "/brainstorm {ref}"
      assert found.payload["node_type"] == "agent"
      assert found.payload["isolation"] == "shared_clean"
      assert found.payload["vars"]["ref"] == Relay.Cards.ref(board, card)

      # create_board derives the key from the name, so compute the expected branch.
      assert found.payload["vars"]["branch"] ==
               "#{String.downcase(board.key)}-#{card.ref_number}-try-the-engine"

      assert {:ok, %Run{status: :done}} =
               Runs.report_outcome(found, %{outcome: :succeeded, detail: "spec written", git_sha: "abc1234"})

      assert_receive {:node_finished, _run, %NodeExecution{outcome: :succeeded, git_sha: "abc1234"}}
      assert_receive {:run_finished, %Run{status: :done, current_node: nil}}

      card = Relay.Cards.get_card(board, card.id)
      assert card.stage_id == flow.lands_on_stage_id
      assert card.status == :in_review

      assert [%NodeExecution{node_key: "brainstorm", outcome: :succeeded, detail: "spec written"}] =
               Runs.list_executions(run)
    end

    test "guards: disabled flow, unsupported node type, empty flow, one active run per card",
         %{board: board} do
      flow = Relay.Flows.get_flow!(board, "spec")
      card = card_in(board, "Next up")
      assert Runs.start_run(card, flow) == {:error, :flow_disabled}

      flow = enabled_spec_flow(board)
      assert {:ok, _run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, _job}
      card = Relay.Cards.get_card(board, card.id)
      assert Runs.start_run(card, flow) == {:error, :active_run_exists}

      next_up = Enum.find(board.stages, &(&1.name == "Next up"))
      spec = Enum.find(board.stages, &(&1.name == "Spec"))

      {:ok, human_flow} =
        Relay.Flows.create_flow(board, %{
          key: "human",
          isolation: :shared_clean,
          pulls_from_stage_id: spec.id,
          works_in_stage_id: spec.id,
          lands_on_stage_id: next_up.id,
          nodes: [%{key: "review", type: :human}],
          edges: [%{from: "start", to: "review"}, %{from: "review", to: "done", on: :succeeded}]
        })

      {:ok, human_flow} = Relay.Flows.enable_flow(human_flow)
      other = card_in(board, "Next up", "Human flow")
      assert Runs.start_run(other, human_flow) == {:error, :unsupported_node_type}
    end
  end

  describe "report_outcome/2 routing" do
    test "a failing node retries, then follows its failed edge with findings; the failure lands on the card",
         %{board: board} do
      flow = retry_flow(board)
      card = card_in(board, "Next up")
      {:ok, _run} = Runs.start_run(card, flow)

      assert_receive {:dispatched, %NodeJob{node_key: "work"} = job1}
      assert {:ok, %Run{status: :running}} = Runs.report_outcome(job1, %{outcome: :failed, detail: "boom-1"})

      # Retry: same visit, attempt 2, findings carry the failure.
      assert_receive {:dispatched, %NodeJob{node_key: "work"} = job2}
      execution2 = Repo.get!(NodeExecution, job2.node_execution_id)
      assert %{visit: 1, attempt: 2} = execution2
      assert job2.payload["vars"]["findings"] == "boom-1"

      assert {:ok, _run} = Runs.report_outcome(job2, %{outcome: :failed, detail: "boom-2"})

      # Retries exhausted → the failed edge reroutes to fallback.
      assert_receive {:dispatched, %NodeJob{node_key: "fallback"} = job3}
      assert job3.payload["vars"]["findings"] == "boom-2"
      assert job3.payload["vars"]["prior_detail"] == "boom-2"

      # The final failure landed on the card timeline as a :failure entry.
      card = Relay.Cards.get_card(board, card.id)
      timeline = Relay.Activity.list_timeline(card)
      assert Enum.any?(timeline, &match?(%Schemas.Activity{type: :failure, text: "boom-2"}, &1))

      assert {:ok, %Run{status: :done}} = Runs.report_outcome(job3, %{outcome: :succeeded, detail: "recovered"})
      assert_receive {:run_finished, %Run{status: :done}}
    end

    test "an unrouted outcome fails the run and parks the card :ready with the failure on its timeline",
         %{board: board} do
      flow = enabled_spec_flow(board)
      card = card_in(board, "Next up")
      {:ok, _run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, job}

      # The seeded spec flow has no :failed edge and brainstorm max_retries 1:
      # two distinct failures exhaust retries, then fail the run.
      assert {:ok, %Run{status: :running}} = Runs.report_outcome(job, %{outcome: :failed, detail: "err-1"})
      assert_receive {:dispatched, retry_job}
      assert {:ok, %Run{status: :failed} = run} = Runs.report_outcome(retry_job, %{outcome: :failed, detail: "err-2"})

      assert run.failure_detail =~ "no_route_for_outcome"
      assert_receive {:run_finished, %Run{status: :failed}}

      card = Relay.Cards.get_card(board, card.id)
      assert card.status == :ready
      assert Enum.any?(Relay.Activity.list_timeline(card), &match?(%Schemas.Activity{type: :failure}, &1))
    end

    test "needs_input parks the run, stores the session, and blocks the card idempotently",
         %{board: board} do
      flow = enabled_spec_flow(board)
      card = card_in(board, "Next up")
      {:ok, run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, job}

      assert {:ok, %Run{status: :parked, parked_reason: :needs_input, current_node: "brainstorm"}} =
               Runs.report_outcome(job, %{outcome: :needs_input, detail: "Which auth model?", session_id: "s_test1"})

      assert_receive {:run_parked, %Run{}}
      assert Runs.active_job(Runs.get_run!(run.id)) == nil
      assert [%NodeExecution{outcome: :needs_input, session_id: "s_test1"}] = Runs.list_executions(run)

      card = Relay.Cards.get_card(board, card.id)
      assert card.status == :needs_input
    end

    test "a deleted flow fails the next transition loudly with no_flow", %{board: board} do
      flow = enabled_spec_flow(board)
      card = card_in(board, "Next up")
      {:ok, _run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, job}

      Repo.delete!(Relay.Flows.get_flow!(board, "spec"))

      assert {:ok, %Run{status: :failed, failure_detail: "no_flow"}} =
               Runs.report_outcome(job, %{outcome: :succeeded, detail: "done"})

      assert_receive {:run_finished, %Run{status: :failed}}
    end

    test "a revoked job's late report is dropped", %{board: board} do
      flow = enabled_spec_flow(board)
      card = card_in(board, "Next up")
      {:ok, run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, job}

      assert {:ok, %Run{status: :cancelled}} = Runs.cancel_run(run)
      assert_receive {:revoked, %NodeJob{state: :revoked}}
      assert Runs.report_outcome(job, %{outcome: :succeeded, detail: "late"}) == {:error, :job_not_active}
    end
  end

  describe "claim_job/2 and start_job/1" do
    test "queued → claimed → running; wrong-state transitions are rejected", %{board: board} do
      flow = enabled_spec_flow(board)
      card = card_in(board, "Next up")
      {:ok, _run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, job}

      assert {:ok, %NodeJob{state: :claimed, executor_name: "mac-1"} = claimed} = Runs.claim_job(job, "mac-1")
      assert claimed.claimed_at
      assert Runs.claim_job(job, "mac-2") == {:error, :job_not_active}
      assert {:ok, %NodeJob{state: :running} = running} = Runs.start_job(claimed)
      assert Runs.start_job(running) == {:error, :job_not_active}
    end
  end

  describe "cancel_run/1" do
    test "revokes the in-flight job, closes the run, and logs to the card timeline", %{board: board} do
      flow = enabled_spec_flow(board)
      card = card_in(board, "Next up")
      {:ok, run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, _job}

      assert {:ok, %Run{status: :cancelled, finished_at: %DateTime{}}} = Runs.cancel_run(run)
      assert_receive {:revoked, _job}
      assert_receive {:run_finished, %Run{status: :cancelled}}
      assert Runs.cancel_run(Runs.get_run!(run.id)) == {:error, :not_active}

      card = Relay.Cards.get_card(board, card.id)

      assert Enum.any?(
               Relay.Activity.list_timeline(card),
               &match?(%Schemas.Activity{type: :action, text: "run cancelled"}, &1)
             )
    end
  end

  describe "upsert_executor/2" do
    setup %{board: board}, do: %{board: board}

    test "inserts then updates the durable row keyed {board_id, name}", %{board: board} do
      {:ok, e1} =
        Runs.upsert_executor(board, %{
          "name" => "jeremy-mbp",
          "host" => "jeremy-mbp.local",
          "interval" => 30,
          "capacity" => %{"shared_clean" => 3, "exclusive" => 1}
        })

      assert e1.board_id == board.id
      assert e1.name == "jeremy-mbp"
      assert e1.capacity == %{"shared_clean" => 3, "exclusive" => 1}
      assert %DateTime{} = e1.last_heartbeat

      {:ok, e2} =
        Runs.upsert_executor(board, %{"name" => "jeremy-mbp", "capacity" => %{"shared_clean" => 1}})

      assert e2.id == e1.id
      assert e2.capacity == %{"shared_clean" => 1}
      assert Relay.Repo.aggregate(Schemas.Executor, :count) == 1
    end
  end

  describe "claim_next_job/1" do
    test "atomically claims the oldest queued job the executor has capacity for", %{board: board} do
      flow = enabled_spec_flow(board)
      card = card_in(board, "Next up")
      {:ok, run} = Runs.start_run(card, flow)
      queued = Runs.active_job(run)

      {:ok, executor} =
        Runs.upsert_executor(board, %{"name" => "e1", "capacity" => %{"shared_clean" => 1, "exclusive" => 1}})

      assert {:ok, claimed} = Runs.claim_next_job(executor)
      assert claimed.id == queued.id
      assert claimed.state == :claimed
      assert claimed.executor_name == "e1"
      assert %DateTime{} = claimed.claimed_at

      # Nothing left to claim → {:ok, nil}
      assert {:ok, nil} = Runs.claim_next_job(executor)
    end

    test "skips a class the executor has no capacity for", %{board: board} do
      flow = enabled_spec_flow(board)
      {:ok, _run} = Runs.start_run(card_in(board, "Next up"), flow)

      {:ok, executor} = Runs.upsert_executor(board, %{"name" => "e2", "capacity" => %{"exclusive" => 1}})

      # The spec flow is shared_clean; an exclusive-only executor claims nothing.
      assert {:ok, nil} = Runs.claim_next_job(executor)
    end
  end

  describe "get_claimed_job/2" do
    test "returns held jobs, 404s unknown ids, conflicts on unheld state", %{board: board} do
      flow = enabled_spec_flow(board)
      {:ok, run} = Runs.start_run(card_in(board, "Next up"), flow)
      job = Runs.active_job(run)

      # queued (not held) → conflict
      assert {:error, :conflict} = Runs.get_claimed_job(board, job.id)

      {:ok, executor} = Runs.upsert_executor(board, %{"name" => "e", "capacity" => %{"shared_clean" => 1}})
      {:ok, claimed} = Runs.claim_next_job(executor)

      assert {:ok, held} = Runs.get_claimed_job(board, claimed.id)
      assert held.id == claimed.id
      assert {:error, :not_found} = Runs.get_claimed_job(board, 999_999)

      other = insert(:board)
      assert {:error, :not_found} = Runs.get_claimed_job(other, claimed.id)
    end
  end

  describe "reclaim_stale_executors/0" do
    test "requeues a stale executor's shared_clean job for another executor", %{board: board} do
      flow = enabled_spec_flow(board)
      {:ok, _run} = Runs.start_run(card_in(board, "Next up"), flow)

      {:ok, gone} =
        Runs.upsert_executor(board, %{"name" => "gone", "interval" => 30, "capacity" => %{"shared_clean" => 1}})

      {:ok, claimed} = Runs.claim_next_job(gone)
      assert claimed.state == :claimed

      # Backdate past 2 × interval so the executor reads stale.
      stale_at = DateTime.add(DateTime.utc_now(), -1000, :second)

      Relay.Repo.update_all(from(e in Schemas.Executor, where: e.id == ^gone.id),
        set: [last_heartbeat: DateTime.truncate(stale_at, :second)]
      )

      :ok = Runs.reclaim_stale_executors()

      requeued = Relay.Repo.get!(NodeJob, claimed.id)
      assert requeued.state == :queued
      assert requeued.executor_name == nil

      {:ok, other} = Runs.upsert_executor(board, %{"name" => "other", "capacity" => %{"shared_clean" => 1}})
      assert {:ok, reclaimed} = Runs.claim_next_job(other)
      assert reclaimed.id == claimed.id
      assert reclaimed.executor_name == "other"
    end

    test "parks an exclusive run instead of requeuing", %{board: board} do
      # A one-node exclusive flow so the queued job is exclusive.
      next_up = Enum.find(board.stages, &(&1.name == "Next up"))
      spec = Enum.find(board.stages, &(&1.name == "Spec"))
      plan = Enum.find(board.stages, &(&1.name == "Plan"))

      {:ok, flow} =
        Relay.Flows.create_flow(board, %{
          key: "excl",
          isolation: :exclusive,
          pulls_from_stage_id: next_up.id,
          works_in_stage_id: spec.id,
          lands_on_stage_id: plan.id,
          nodes: [%{key: "work", type: :agent, run: "work {ref}"}],
          edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
        })

      {:ok, flow} = Relay.Flows.enable_flow(flow)
      {:ok, run} = Runs.start_run(card_in(board, "Next up"), flow)

      {:ok, gone} =
        Runs.upsert_executor(board, %{"name" => "gone2", "interval" => 30, "capacity" => %{"exclusive" => 1}})

      {:ok, claimed} = Runs.claim_next_job(gone)

      Relay.Repo.update_all(from(e in Schemas.Executor, where: e.id == ^gone.id),
        set: [last_heartbeat: DateTime.truncate(DateTime.add(DateTime.utc_now(), -1000, :second), :second)]
      )

      :ok = Runs.reclaim_stale_executors()

      assert Runs.get_run!(run.id).status == :parked
      assert Runs.get_run!(run.id).parked_reason == :executor_gone
      assert Relay.Repo.get!(NodeJob, claimed.id).state == :revoked
    end

    test "executor_stale?/2 is the pure threshold — max(60s, 2 × interval)" do
      now = ~U[2026-07-17 12:00:00Z]
      fresh = %Schemas.Executor{interval: 30, last_heartbeat: DateTime.add(now, -59, :second)}
      stale = %Schemas.Executor{interval: 30, last_heartbeat: DateTime.add(now, -61, :second)}
      # floor: a tiny interval still gets a 60s grace.
      tiny_fresh = %Schemas.Executor{interval: 1, last_heartbeat: DateTime.add(now, -59, :second)}

      refute Runs.executor_stale?(fresh, now)
      assert Runs.executor_stale?(stale, now)
      refute Runs.executor_stale?(tiny_fresh, now)
    end
  end

  describe "ExecutorReaper" do
    test "sweeps on its interval" do
      # This file's setup already starts a `Relay.Runs.Supervisor` (with its
      # own default-named reaper), so give this one a distinct name to avoid
      # clobbering that global registration.
      pid = start_supervised!({Relay.Runs.ExecutorReaper, interval_ms: 20, name: :test_executor_reaper})
      # It's alive and clocked; the reclaim behaviour itself is covered above.
      assert Process.alive?(pid)
      _ = :sys.get_state(pid)
    end
  end
end
