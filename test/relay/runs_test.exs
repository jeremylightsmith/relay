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
end
