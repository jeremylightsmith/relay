defmodule Relay.Runs.ReenterFindingsTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob

  setup do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Re-entry Board"})
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Carry the failure forward"})
    start_supervised!(Relay.Runs.Supervisor)
    %{board: board, flow: flow, card: card}
  end

  # RLY-189 acceptance 2: a re-entered node must know why it is running again.
  test "a same-visit re-entry carries the last failure's detail as findings", ctx do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{} = job}

    # brainstorm has max_retries: 1, so this failure re-enters the node rather than
    # ending the run — and the RE-DISPATCHED job is the one under test.
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :failed, detail: "the gate said no"})
    assert_receive {:dispatched, %NodeJob{node_execution_id: id, payload: payload}}
    assert payload["vars"]["findings"] == "the gate said no"

    execution = Repo.get!(NodeExecution, id)
    assert execution.run_id == run.id
    assert execution.visit == 1
    assert execution.attempt == 2
  end

  test "a fresh-visit re-entry enters at attempt 1 on a new visit and carries findings", ctx do
    {:ok, _run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :failed, detail: "boom"})
    assert_receive {:dispatched, %NodeJob{} = retried}
    {:ok, run} = Runs.report_outcome(retried, %{outcome: :failed, detail: "boom again"})

    # The run is terminal now; drive the new mode directly.
    run = run |> Ecto.Changeset.change(status: :running, current_node: "brainstorm") |> Repo.update!()

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Relay.Runs.RunSupervisor,
        {Relay.Runs.RunServer, run_id: run.id, mode: {:reenter_new_visit, nil}}
      )

    assert_receive {:dispatched, %NodeJob{node_execution_id: id, payload: payload}}
    execution = Repo.get!(NodeExecution, id)
    assert execution.visit == 2
    assert execution.attempt == 1
    assert payload["vars"]["findings"] == "boom again"
    assert payload["resume_session"] == nil
  end

  test "a re-entry after a SUCCEEDED execution carries no findings", ctx do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :needs_input, detail: "?", session_id: "s1"})

    run = Runs.get_run!(run.id)
    {:ok, _run} = Runs.resume_run(run, resume_session: "s1")

    assert_receive {:dispatched, %NodeJob{payload: payload}}
    assert payload["vars"]["findings"] == nil
    assert payload["resume_session"] == "s1"
  end
end
