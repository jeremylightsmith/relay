defmodule Relay.Runs.ResumeTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Relay.Runs.Instance
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run

  setup do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Resume Board"})
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    # The scripted executor here runs no real skill, so the card arrives already carrying the
    # fields the shipped spec flow declares it writes (RE244) — otherwise every `succeeded` is
    # rewritten to `failed` by the missing-writes guard.
    {:ok, card} =
      Relay.Cards.create_card(stage, %{
        title: "Survive restarts",
        spec: "# Spec (pre-seeded — the spec flow's brainstorm declares it writes this, RE244)",
        acceptance_criteria: "1. It works."
      })

    :ok = Runs.subscribe(board.id)
    %{board: board, flow: flow, card: card}
  end

  test "an app restart mid-run revokes the orphaned job and re-dispatches the current node",
       %{flow: flow, card: card} do
    start_engine!()
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{id: orphan_id, node_key: "brainstorm"}}

    # "Restart the app": the whole engine tree goes down and comes back.
    restart_engine!()

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
    start_engine!()
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :needs_input, detail: "?", session_id: "s1"})

    restart_engine!()

    refute_receive {:dispatched, _job}, 100
    assert %Run{status: :parked, parked_reason: :needs_input} = Runs.get_run!(run.id)
    assert Registry.lookup(Instance.current().registry, run.id) == []
  end

  test "a second resume_run/2 on an already-resumed run is a detected no-op, not a silent re-write",
       %{flow: flow, card: card} do
    start_engine!()
    {:ok, _run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, job}
    {:ok, parked} = Runs.report_outcome(job, %{outcome: :needs_input, detail: "?", session_id: "s1"})
    assert_receive {:run_parked, _run}

    assert {:ok, %Run{status: :running}} = Runs.resume_run(parked)
    assert_receive {:run_resumed, %Run{status: :running}}
    assert_receive {:dispatched, _job}

    # `parked` is now a stale struct (still shows status: :parked in memory) — a second
    # caller racing on it must be refused, not silently re-write the run or start a
    # second RunServer entry.
    assert {:error, :not_parked} = Runs.resume_run(parked)
    refute_receive {:run_resumed, _}, 100
    refute_receive {:dispatched, _}, 100
  end
end
