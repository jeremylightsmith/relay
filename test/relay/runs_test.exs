defmodule Relay.RunsTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.Card
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run
  alias Schemas.SubTask

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

  # RLY-194 gave every default-library agent node a :failed route (to a fix, or the
  # needs_input park sentinel), so the seeded "spec" flow can no longer produce a genuine
  # no_route_for_outcome / run-ends-:failed scenario — it now parks instead. These two
  # tests are about that engine-level dead-end behavior itself, so they need a custom flow
  # that (like the old "spec") has a node with no :failed edge at all.
  defp dead_end_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Enum.find(board.stages, &(&1.name == "Spec:Review")) || spec

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "dead-end",
        isolation: :shared_clean,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: review.id,
        nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}", max_retries: 1}],
        edges: [%{from: "start", to: "brainstorm"}, %{from: "brainstorm", to: "done", on: :succeeded}]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp exclusive_flow(board, key) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    plan = Enum.find(board.stages, &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: key,
        isolation: :exclusive,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: plan.id,
        nodes: [%{key: "work", type: :agent, run: "work {ref}"}],
        edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
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

    test "an unrouted outcome fails the run and flags the card :failed with the failure on its timeline",
         %{board: board} do
      flow = dead_end_flow(board)
      card = card_in(board, "Next up")
      {:ok, _run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, job}

      # dead_end_flow's brainstorm has no :failed edge and max_retries 1:
      # two distinct failures exhaust retries, then fail the run.
      assert {:ok, %Run{status: :running}} = Runs.report_outcome(job, %{outcome: :failed, detail: "err-1"})
      assert_receive {:dispatched, retry_job}
      assert {:ok, %Run{status: :failed} = run} = Runs.report_outcome(retry_job, %{outcome: :failed, detail: "err-2"})

      assert run.failure_detail =~ "no_route_for_outcome"
      assert_receive {:run_finished, %Run{status: :failed}}

      card = Relay.Cards.get_card(board, card.id)
      # RLY-179: a dead run leaves the card :failed — a distinct state from :needs_input,
      # because answering cannot resume it. It still enters the needs-you rollup.
      assert card.status == :failed
      assert Relay.Cards.needs_you?(card, Relay.Boards.list_stages(board))
      assert Enum.any?(Relay.Activity.list_timeline(card), &match?(%Schemas.Activity{type: :failure}, &1))
      refute Enum.any?(Relay.Activity.list_timeline(card), &match?(%Schemas.Comment{kind: :question}, &1))
      # exactly one :failure entry — mark_failed's, not a duplicate from log_failure_if_final
      assert Enum.count(Relay.Activity.list_timeline(card), &match?(%Schemas.Activity{type: :failure}, &1)) == 1
    end

    test "a blank detail on the final failure still flags the card (falls back, doesn't crash)",
         %{board: board} do
      flow = dead_end_flow(board)
      card = card_in(board, "Next up")
      {:ok, _run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, job}

      # A real executor can report an empty-string detail (bin/relay: `detail = "" if ok
      # else ...`). "" is truthy in Elixir, so a naive `|| ` fallback chain never reaches
      # the default message, request_input's Comment changeset rejects the blank body,
      # and the hard `{:ok, _card} = ...` match in card_fail_effects/2 must not raise.
      assert {:ok, %Run{status: :running}} = Runs.report_outcome(job, %{outcome: :failed, detail: ""})
      assert_receive {:dispatched, retry_job}
      assert {:ok, %Run{status: :failed}} = Runs.report_outcome(retry_job, %{outcome: :failed, detail: ""})

      assert_receive {:run_finished, %Run{status: :failed}}

      card = Relay.Cards.get_card(board, card.id)
      assert card.status == :failed
      assert Relay.Cards.needs_you?(card, Relay.Boards.list_stages(board))
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

    test "an outcome outside the closed set is rejected without touching the job or run", %{board: board} do
      flow = enabled_spec_flow(board)
      card = card_in(board, "Next up")
      {:ok, _run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, job}

      assert Runs.report_outcome(job, %{outcome: :bogus, detail: "nope"}) == {:error, :invalid_outcome}

      # A subsequent valid outcome still routes normally — the bad report left nothing behind.
      assert {:ok, %Run{status: :parked}} =
               Runs.report_outcome(job, %{outcome: :needs_input, detail: "ok?", session_id: "s_1"})
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
      # RLY-201: missing classes are stored explicitly as 0 — the row now holds the
      # canonical closed-set map, same as the ETS store.
      assert e2.capacity == %{"shared_clean" => 1, "exclusive" => 0}
      assert Relay.Repo.aggregate(Schemas.Executor, :count) == 1
    end

    test "upsert_executor/2 drops an unknown capacity class instead of storing it", %{board: board} do
      {:ok, executor} =
        Runs.upsert_executor(board, %{
          "name" => "junk-cap",
          "capacity" => %{"gpu" => 2, "shared_clean" => "lots", "exclusive" => 2}
        })

      assert executor.capacity == %{"shared_clean" => 0, "exclusive" => 2}
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

    test "never claims another board's job, even with the globally-older id and a colliding executor name",
         %{board: board_a, user: user} do
      flow_a = enabled_spec_flow(board_a)
      {:ok, run_a} = Runs.start_run(card_in(board_a, "Next up"), flow_a)
      queued_a = Runs.active_job(run_a)

      {:ok, board_b} = Relay.Boards.create_board(user, %{name: "Other Board"})
      flow_b = enabled_spec_flow(board_b)
      {:ok, run_b} = Runs.start_run(card_in(board_b, "Next up"), flow_b)
      queued_b = Runs.active_job(run_b)

      # board_a's job was created first (lower id) and both executors share a
      # name, so an unscoped claim would find board_a's job first.
      {:ok, executor_b} =
        Runs.upsert_executor(board_b, %{"name" => "shared-hostname", "capacity" => %{"shared_clean" => 1}})

      assert {:ok, claimed} = Runs.claim_next_job(executor_b)
      assert claimed.id == queued_b.id
      refute claimed.id == queued_a.id

      # board_a's job is untouched.
      still_queued = Runs.active_job(run_a)
      assert still_queued.id == queued_a.id
      assert still_queued.state == :queued
    end

    test "claims a job pinned to this executor even when it advertises no free capacity for the class",
         %{board: board} do
      # The exclusive-affinity deadlock (ADR 0006 §5): an executor holding a
      # parked exclusive run advertises exclusive: 0 (its one slot is bound to
      # that run), so a capacity-only filter would never hand it the run's own
      # resume/next job — pinned to it — and the run could never resume. A job
      # pinned to this executor must claim regardless of advertised capacity.
      flow = exclusive_flow(board, "excl-pin")
      {:ok, run} = Runs.start_run(card_in(board, "Next up"), flow)
      job = Runs.active_job(run)

      Relay.Repo.update_all(from(j in NodeJob, where: j.id == ^job.id), set: [executor_name: "holder"])

      {:ok, holder} = Runs.upsert_executor(board, %{"name" => "holder", "capacity" => %{"exclusive" => 0}})

      assert {:ok, claimed} = Runs.claim_next_job(holder)
      assert claimed.id == job.id
      assert claimed.executor_name == "holder"
    end

    test "a job pinned to another executor is never claimed, even with spare capacity", %{board: board} do
      flow = exclusive_flow(board, "excl-pin2")
      {:ok, run} = Runs.start_run(card_in(board, "Next up"), flow)
      job = Runs.active_job(run)

      Relay.Repo.update_all(from(j in NodeJob, where: j.id == ^job.id), set: [executor_name: "holder"])

      {:ok, other} = Runs.upsert_executor(board, %{"name" => "other", "capacity" => %{"exclusive" => 3}})

      assert {:ok, nil} = Runs.claim_next_job(other)
    end
  end

  describe "exclusive executor affinity (insert_job!)" do
    test "pins an exclusive run's subsequent job to the executor holding the run", %{board: board} do
      flow = exclusive_flow(board, "excl-affinity")
      {:ok, run} = Runs.start_run(card_in(board, "Next up"), flow)

      {:ok, e} = Runs.upsert_executor(board, %{"name" => "e", "capacity" => %{"exclusive" => 1}})
      {:ok, _claimed} = Runs.claim_next_job(e)

      execution = Runs.insert_execution!(run, "work", 1, 2)
      next_job = Runs.insert_job!(run, execution, Runs.build_payload(run, flow, "work", []))

      assert next_job.executor_name == "e"
    end

    test "leaves a shared_clean run's job unpinned", %{board: board} do
      flow = enabled_spec_flow(board)
      {:ok, run} = Runs.start_run(card_in(board, "Next up"), flow)

      {:ok, e} = Runs.upsert_executor(board, %{"name" => "e", "capacity" => %{"shared_clean" => 1}})
      {:ok, _claimed} = Runs.claim_next_job(e)

      execution = Runs.insert_execution!(run, "brainstorm", 1, 2)
      next_job = Runs.insert_job!(run, execution, Runs.build_payload(run, flow, "brainstorm", []))

      assert next_job.executor_name == nil
    end

    test "does not pin a resume job after the run's active job was revoked (worktree reset)",
         %{board: board} do
      # A revoke — human baton (park_claimed) or executor_gone reclaim — resets the
      # run's worktree and unbinds the slot on the executor. Affinity is void: a
      # resume pinned to the old holder would be handed to it by the capacity
      # bypass and, if that executor is now busy on another run, rejected-as-failed
      # (terminally failing a resumable run). So a revoked most-recent job must
      # leave the next job unpinned — the resume re-offers to any free executor
      # with a fresh worktree.
      flow = exclusive_flow(board, "excl-revoke")
      {:ok, run} = Runs.start_run(card_in(board, "Next up"), flow)
      {:ok, e} = Runs.upsert_executor(board, %{"name" => "e", "capacity" => %{"exclusive" => 1}})
      {:ok, _claimed} = Runs.claim_next_job(e)

      Runs.revoke_active_jobs(run)

      execution = Runs.insert_execution!(run, "work", 1, 2)
      next_job = Runs.insert_job!(run, execution, Runs.build_payload(run, flow, "work", []))

      assert next_job.executor_name == nil
    end

    test "a revoke voids affinity even when an earlier node still holds the executor name (multi-node)",
         %{board: board} do
      # Guards the multi-node case: reading the SINGLE most-recent job (not the
      # newest non-nil executor_name) is what prevents an earlier :done node's
      # retained name from resurrecting affinity a later revoke just voided.
      flow = exclusive_flow(board, "excl-revoke-multi")
      {:ok, run} = Runs.start_run(card_in(board, "Next up"), flow)
      {:ok, e} = Runs.upsert_executor(board, %{"name" => "e", "capacity" => %{"exclusive" => 1}})

      # node1 runs and completes on e (job stays :done with executor_name retained).
      {:ok, job1} = Runs.claim_next_job(e)
      Relay.Repo.update_all(from(j in NodeJob, where: j.id == ^job1.id), set: [state: :done])

      # node2 is enqueued (pinned to e), then revoked (human baton / reclaim).
      exec2 = Runs.insert_execution!(run, "work", 1, 2)
      job2 = Runs.insert_job!(run, exec2, Runs.build_payload(run, flow, "work", []))
      assert job2.executor_name == "e"
      Runs.revoke_active_jobs(run)

      # The resume must NOT pin to e via node1's lingering name.
      exec3 = Runs.insert_execution!(run, "work", 1, 3)
      job3 = Runs.insert_job!(run, exec3, Runs.build_payload(run, flow, "work", []))
      assert job3.executor_name == nil
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

    test "park_for_reclaim/1 revokes a lingering active job even when the run isn't :running", %{board: board} do
      next_up = Enum.find(board.stages, &(&1.name == "Next up"))
      spec = Enum.find(board.stages, &(&1.name == "Spec"))
      plan = Enum.find(board.stages, &(&1.name == "Plan"))

      {:ok, flow} =
        Relay.Flows.create_flow(board, %{
          key: "excl3",
          isolation: :exclusive,
          pulls_from_stage_id: next_up.id,
          works_in_stage_id: spec.id,
          lands_on_stage_id: plan.id,
          nodes: [%{key: "work", type: :agent, run: "work {ref}"}],
          edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
        })

      {:ok, flow} = Relay.Flows.enable_flow(flow)
      {:ok, run} = Runs.start_run(card_in(board, "Next up"), flow)

      {:ok, gone} = Runs.upsert_executor(board, %{"name" => "gone3", "capacity" => %{"exclusive" => 1}})
      {:ok, claimed} = Runs.claim_next_job(gone)

      # Simulate the run having moved on (e.g. cancelled via a concurrent
      # path) WITHOUT its job having been revoked first — the exact race the
      # fix guards against, so the job doesn't stay stuck :claimed forever.
      Relay.Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [status: :cancelled])
      run = Runs.get_run!(run.id)

      :ok = Runs.park_for_reclaim(run)

      assert Relay.Repo.get!(NodeJob, claimed.id).state == :revoked
      # A non-running run's own status is left alone — reclaim doesn't clobber it.
      assert Runs.get_run!(run.id).status == :cancelled
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

  # A minimal foreach flow: the head loops on itself while items remain.
  # `head_max_retries` lets a test give the loop head a retry budget (nil, the
  # default, keeps it unset — a single failed outcome then has no route and
  # fails the run, as the existing tests below rely on).
  defp foreach_flow_attrs(head_max_retries) do
    %{
      key: "loopy",
      isolation: :exclusive,
      nodes: [
        %{key: "head", type: :agent, run: "work {sub_task}", foreach: "card.sub_tasks", max_retries: head_max_retries},
        %{key: "after", type: :gate, run: "true"}
      ],
      edges: [
        %{from: "start", to: "head"},
        %{from: "head", to: "head", on: :succeeded, when: :foreach_remaining},
        %{from: "head", to: "after", on: :succeeded, when: :foreach_exhausted},
        %{from: "after", to: "done", on: :succeeded}
      ]
    }
  end

  # A board + enabled foreach flow + a card sitting in the flow's pulls-from stage,
  # carrying `plan`. Mirrors this file's existing flow fixtures. The card factory
  # derives board_id from the stage, so pass only `stage:`.
  defp setup_foreach(opts) do
    board = insert(:board)
    pulls = insert(:stage, board: board, name: "Plan:Done", position: 1)
    works = insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 2)
    lands = insert(:stage, board: board, name: "Review", category: :in_progress, type: :review, position: 3)

    attrs =
      Map.merge(foreach_flow_attrs(Keyword.get(opts, :head_max_retries)), %{
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id
      })

    {:ok, flow} = Relay.Flows.create_flow(board, attrs)
    {:ok, flow} = Relay.Flows.enable_flow(flow)
    card = insert(:card, stage: pulls, plan: Keyword.fetch!(opts, :plan))

    %{board: board, flow: flow, card: card}
  end

  describe "foreach: the engine owns the task list (W13)" do
    test "start_run parses the card's plan into sub_tasks" do
      %{flow: flow, card: card} = setup_foreach(plan: "### Task 1: Alpha\n\n### Task 2: Beta\n")

      assert {:ok, _run} = Runs.start_run(card, flow)

      assert ["Alpha", "Beta"] =
               Repo.all(from st in SubTask, where: st.card_id == ^card.id, order_by: :position, select: st.title)
    end

    test "refuses to start a foreach run when the plan yields no tasks, and flags the card" do
      # RLY-165: an unparseable plan used to seed zero sub_tasks and start anyway. The first
      # foreach guard then read `remaining == 0` as :foreach_exhausted and routed straight
      # PAST every implement lap to precommit — which passes trivially on an empty diff —
      # then reviews, smoke and `merge`. An unreadable plan would have merged an empty branch.
      # Zero tasks is a defect, not a finished loop: no run, and the card blocks on a human so
      # the scheduler stops re-pulling it.
      %{flow: flow, card: card} = setup_foreach(plan: "# Just prose\n\nNo tasks in here.")

      assert {:error, :no_plan_tasks} = Runs.start_run(card, flow)

      refute Repo.exists?(from r in Run, where: r.card_id == ^card.id)
      assert Repo.get!(Card, card.id).status == :needs_input
    end

    test "a non-foreach flow with an unparseable plan is unaffected", %{board: board} do
      # The guard is specific to flows that iterate the plan; spec/plan have no foreach node
      # and must still start on a card whose plan has no task headings.
      flow = enabled_spec_flow(board)
      card = card_in(board, "Next up")

      assert {:ok, _run} = Runs.start_run(card, flow)
    end

    test "start_run leaves existing sub_tasks alone" do
      %{flow: flow, card: card} = setup_foreach(plan: "### Task 1: Alpha\n")
      {:ok, _card} = Relay.Cards.set_sub_tasks(card, [%{title: "Written by the Plan stage"}])

      assert {:ok, _run} = Runs.start_run(card, flow)

      assert ["Written by the Plan stage"] =
               Repo.all(from st in SubTask, where: st.card_id == ^card.id, select: st.title)
    end

    test "entering the foreach node stamps the first undone sub_task, and the payload names it" do
      %{flow: flow, card: card} = setup_foreach(plan: "### Task 1: Alpha\n\n### Task 2: Beta\n")
      {:ok, run} = Runs.start_run(card, flow)

      execution = Repo.one!(from e in NodeExecution, where: e.run_id == ^run.id)
      [alpha, _beta] = Repo.all(from st in SubTask, where: st.card_id == ^card.id, order_by: :position)

      assert execution.node_key == "head"
      assert execution.sub_task_id == alpha.id

      job = Runs.active_job(run)
      assert job.payload["vars"]["sub_task"] == "Alpha"
    end

    test "the loop tail checks the sub_task off, then routes on the recomputed remaining count" do
      %{flow: flow, card: card} = setup_foreach(plan: "### Task 1: Alpha\n\n### Task 2: Beta\n")
      {:ok, run} = Runs.start_run(card, flow)
      [alpha, beta] = Repo.all(from st in SubTask, where: st.card_id == ^card.id, order_by: :position)

      # Iteration 1 succeeds at the tail (here head IS the tail — it carries the guards).
      {:ok, _run} = Runs.report_outcome(Runs.active_job(run), %{outcome: :succeeded, detail: "done alpha"})

      assert Repo.get!(SubTask, alpha.id).done
      refute Repo.get!(SubTask, beta.id).done

      # ...and the guard sent us back into the loop head, now bound to Beta.
      second = Repo.one!(from e in NodeExecution, where: e.run_id == ^run.id and is_nil(e.outcome))
      assert second.node_key == "head"
      assert second.sub_task_id == beta.id
      assert Runs.active_job(run).payload["vars"]["sub_task"] == "Beta"

      # Iteration 2 exhausts the list: the exhausted guard leaves the loop, unbound.
      {:ok, _run} = Runs.report_outcome(Runs.active_job(run), %{outcome: :succeeded, detail: "done beta"})
      assert Repo.get!(SubTask, beta.id).done

      third = Repo.one!(from e in NodeExecution, where: e.run_id == ^run.id and is_nil(e.outcome))
      assert third.node_key == "after"
      assert third.sub_task_id == nil
    end

    test "the check-off broadcasts {:card_upserted, card} after commit, with the done sub_task preloaded" do
      %{flow: flow, card: card} = setup_foreach(plan: "### Task 1: Alpha\n")
      {:ok, run} = Runs.start_run(card, flow)
      [alpha] = Repo.all(from st in SubTask, where: st.card_id == ^card.id)
      Relay.Events.subscribe(card.board_id)

      {:ok, _run} = Runs.report_outcome(Runs.active_job(run), %{outcome: :succeeded, detail: "done alpha"})

      assert_receive {:card_upserted, %Card{id: id} = broadcast_card}
      assert id == card.id
      assert [%SubTask{id: sub_task_id, done: true}] = broadcast_card.sub_tasks
      assert sub_task_id == alpha.id
    end

    test "a failed iteration does NOT check its sub_task off" do
      %{flow: flow, card: card} = setup_foreach(plan: "### Task 1: Alpha\n")
      {:ok, run} = Runs.start_run(card, flow)
      [alpha] = Repo.all(from st in SubTask, where: st.card_id == ^card.id)

      {:ok, _run} = Runs.report_outcome(Runs.active_job(run), %{outcome: :failed, detail: "reviewer refused"})

      refute Repo.get!(SubTask, alpha.id).done
    end

    test "resuming a parked foreach node re-enters bound to its own iteration, not an earlier one at this node" do
      %{board: board, flow: flow, card: card} = setup_foreach(plan: "### Task 1: Alpha\n\n### Task 2: Beta\n")
      # setup_foreach mints its own board (distinct from this file's `setup` block's), so
      # subscribe to ITS topic — the outer subscription is watching the wrong board.
      :ok = Runs.subscribe(board.id)
      {:ok, run} = Runs.start_run(card, flow)
      assert_receive {:node_started, _run, %NodeExecution{node_key: "head"}}
      [alpha, beta] = Repo.all(from st in SubTask, where: st.card_id == ^card.id, order_by: :position)

      # Iteration 1 (Alpha) succeeds at the tail, routing back into the loop head bound to Beta —
      # the "head" node now has TWO executions, under two different sub_tasks.
      {:ok, _run} = Runs.report_outcome(Runs.active_job(run), %{outcome: :succeeded, detail: "done alpha"})
      assert Repo.get!(SubTask, alpha.id).done
      assert_receive {:node_started, _run, %NodeExecution{node_key: "head", sub_task_id: beta_id}}
      assert beta_id == beta.id

      # Iteration 2 (Beta) needs input: parks the run mid-loop, still bound to Beta.
      assert {:ok, %Run{status: :parked}} =
               Runs.report_outcome(Runs.active_job(run), %{
                 outcome: :needs_input,
                 detail: "which?",
                 session_id: "s1"
               })

      assert_receive {:run_parked, %Run{}}
      run = Runs.get_run!(run.id)

      # Resume (boot resume / needs-input resume / hand-back all share this {:reenter, _}
      # path): the fresh attempt must stay bound to Beta — the node's LATEST execution —
      # not fall back to Alpha, the same node's first-ever binding.
      assert {:ok, %Run{status: :running}} = Runs.resume_run(run, resume_session: "s1")

      assert_receive {:node_started, %Run{}, %NodeExecution{node_key: "head"} = execution}
      assert execution.sub_task_id == beta.id
      assert Runs.active_job(run).payload["vars"]["sub_task"] == "Beta"
    end

    test "a failed iteration that retries (the :retry inherit path) stays bound to the same sub_task" do
      %{flow: flow, card: card} = setup_foreach(plan: "### Task 1: Alpha\n", head_max_retries: 1)
      {:ok, run} = Runs.start_run(card, flow)
      [alpha] = Repo.all(from st in SubTask, where: st.card_id == ^card.id)

      assert {:ok, %Run{status: :running}} =
               Runs.report_outcome(Runs.active_job(run), %{outcome: :failed, detail: "boom"})

      retry_execution = Repo.one!(from e in NodeExecution, where: e.run_id == ^run.id and is_nil(e.outcome))
      assert retry_execution.node_key == "head"
      assert retry_execution.visit == 1
      assert retry_execution.attempt == 2
      assert retry_execution.sub_task_id == alpha.id
      assert Runs.active_job(run).payload["vars"]["findings"] == "boom"
    end

    test "an unparseable plan never routes past the loop — no node ever runs (RLY-165)" do
      # This test previously asserted the OPPOSITE ("runs straight past the loop"), which is
      # the defect the first live Code dogfood hit: past the loop means past every implement
      # lap, into precommit (green on an empty diff), reviews, smoke and `merge`. The
      # legitimate exhausted-after-completing-all-tasks routing is covered above, where
      # `third.node_key == "after"` follows real work.
      %{flow: flow, card: card} = setup_foreach(plan: "# Prose only")

      assert {:error, :no_plan_tasks} = Runs.start_run(card, flow)

      refute Repo.exists?(from e in NodeExecution, join: r in Run, on: r.id == e.run_id, where: r.card_id == ^card.id)
    end
  end

  describe "requeue_orphaned_jobs/3 (RLY-170)" do
    # An executor that restarts loses its in-flight job state (it lives in-process). The job
    # stays :claimed server-side, and NEITHER recovery path can see it: claim_next_job only
    # offers :queued jobs, and reclaim_stale_executors only touches STALE executors — this one
    # is alive and beating. The drill left a job stranded for an hour; it would have sat there
    # forever. The heartbeat already reports which jobs the executor IS running, so the absence
    # of a job from that list is the signal.
    defp orphan_setup(board, flow_kind) do
      flow = if flow_kind == :exclusive, do: exclusive_flow(board, "orph"), else: enabled_spec_flow(board)
      {:ok, run} = Runs.start_run(card_in(board, "Next up"), flow)
      cap = if flow_kind == :exclusive, do: %{"exclusive" => 1}, else: %{"shared_clean" => 1}
      {:ok, executor} = Runs.upsert_executor(board, %{"name" => "e1", "capacity" => cap})
      {:ok, claimed} = Runs.claim_next_job(executor)
      %{run: run, executor: executor, job: claimed}
    end

    defp backdate_claim(job, seconds) do
      at = DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)
      Relay.Repo.update_all(from(j in NodeJob, where: j.id == ^job.id), set: [claimed_at: at])
    end

    test "requeues a job the executor no longer reports running", %{board: board} do
      %{executor: executor, job: job} = orphan_setup(board, :shared_clean)
      backdate_claim(job, 600)

      :ok = Runs.requeue_orphaned_jobs(board, executor, [])

      requeued = Relay.Repo.get!(NodeJob, job.id)
      assert requeued.state == :queued
      assert requeued.claimed_at == nil
    end

    test "leaves a job the executor still reports running", %{board: board} do
      %{executor: executor, job: job} = orphan_setup(board, :shared_clean)
      backdate_claim(job, 600)

      :ok = Runs.requeue_orphaned_jobs(board, executor, [job.id])

      assert Relay.Repo.get!(NodeJob, job.id).state == :claimed
    end

    test "leaves a job claimed inside the grace window — the just-claimed race", %{board: board} do
      # A job claimed microseconds before a beat is legitimately not in `running` yet.
      # Requeuing it would double-dispatch LIVE work, which is worse than the bug being fixed.
      %{executor: executor, job: job} = orphan_setup(board, :shared_clean)

      :ok = Runs.requeue_orphaned_jobs(board, executor, [])

      assert Relay.Repo.get!(NodeJob, job.id).state == :claimed
    end

    test "never touches another executor's job", %{board: board} do
      %{job: job} = orphan_setup(board, :shared_clean)
      backdate_claim(job, 600)
      {:ok, other} = Runs.upsert_executor(board, %{"name" => "e2", "capacity" => %{"shared_clean" => 1}})

      :ok = Runs.requeue_orphaned_jobs(board, other, [])

      assert Relay.Repo.get!(NodeJob, job.id).state == :claimed
    end

    test "an exclusive orphan stays PINNED to its executor; a shared_clean one is unpinned",
         %{board: board} do
      # Exclusive affinity is what makes recovery correct rather than destructive: the run's
      # commits live in THAT machine's worktree, so the job must go back to the same executor.
      # RLY-135's pinned-claim path (which bypasses the capacity filter) is what re-delivers it.
      %{executor: executor, job: excl} = orphan_setup(board, :exclusive)
      backdate_claim(excl, 600)
      :ok = Runs.requeue_orphaned_jobs(board, executor, [])
      assert %{state: :queued, executor_name: "e1"} = Relay.Repo.get!(NodeJob, excl.id)
    end
  end

  describe "terminal_among/2" do
    test "returns on-board terminal run-ids, excluding active runs and other boards", %{board: board} do
      flow = retry_flow(board)
      {:ok, active} = Runs.start_run(card_in(board, "Next up", "active"), flow)

      {:ok, cancelled} = Runs.start_run(card_in(board, "Next up", "cancelled"), flow)
      {:ok, cancelled} = Runs.cancel_run(cancelled)

      {:ok, done} = Runs.start_run(card_in(board, "Next up", "done"), flow)
      {1, _} = Relay.Repo.update_all(from(r in Run, where: r.id == ^done.id), set: [status: :done])

      # A terminal run on a DIFFERENT board must never come back (cross-board leak).
      {:ok, other_board} = Relay.Boards.create_board(insert(:user), %{name: "Other"})
      other_flow = retry_flow(other_board)
      {:ok, elsewhere} = Runs.start_run(card_in(other_board, "Next up", "elsewhere"), other_flow)
      {:ok, elsewhere} = Runs.cancel_run(elsewhere)

      result = Runs.terminal_among(board, [active.id, cancelled.id, done.id, elsewhere.id])

      assert cancelled.id in result
      assert done.id in result
      refute active.id in result
      refute elsewhere.id in result
    end

    test "an empty list in returns an empty list", %{board: board} do
      assert Runs.terminal_among(board, []) == []
    end

    test "a run-id this board does not own is not returned", %{board: board} do
      assert Runs.terminal_among(board, [999_999]) == []
    end
  end
end
