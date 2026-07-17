defmodule Relay.Runs.ResumeTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run

  setup do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Resume Board"})
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Survive restarts"})
    :ok = Runs.subscribe(board.id)
    %{board: board, flow: flow, card: card}
  end

  test "an app restart mid-run revokes the orphaned job and re-dispatches the current node",
       %{flow: flow, card: card} do
    start_supervised!(Relay.Runs.Supervisor)
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{id: orphan_id, node_key: "brainstorm"}}

    # "Restart the app": the whole engine tree goes down and comes back.
    stop_supervised!(Relay.Runs.Supervisor)
    start_supervised!(Relay.Runs.Supervisor)

    # The boot resume task revoked the orphan and dispatched a fresh attempt.
    assert_receive {:revoked, %NodeJob{id: ^orphan_id, state: :revoked}}
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm", state: :queued} = fresh}
    assert_receive {:node_started, _run, %NodeExecution{node_key: "brainstorm", visit: 1, attempt: 2}}
    refute fresh.id == orphan_id

    assert %Run{status: :running, current_node: "brainstorm"} = Runs.get_run!(run.id)

    # The revived run still finishes normally.
    assert {:ok, %Run{status: :done}} = Runs.report_outcome(fresh, %{outcome: :succeeded, detail: "ok"})
  end

  test "parked runs stay dormant across restarts — parking never holds a process",
       %{flow: flow, card: card} do
    start_supervised!(Relay.Runs.Supervisor)
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :needs_input, detail: "?", session_id: "s1"})

    stop_supervised!(Relay.Runs.Supervisor)
    start_supervised!(Relay.Runs.Supervisor)

    refute_receive {:dispatched, _job}, 100
    assert %Run{status: :parked, parked_reason: :needs_input} = Runs.get_run!(run.id)
    assert Registry.lookup(Relay.Runs.Registry, run.id) == []
  end
end
