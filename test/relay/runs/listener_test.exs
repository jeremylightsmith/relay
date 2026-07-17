defmodule Relay.Runs.ListenerTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeJob
  alias Schemas.Run

  setup do
    FakeDispatcher.register(self())
    start_supervised!(Relay.Runs.Supervisor)

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Listener Board"})
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Pass the baton"})
    :ok = Runs.subscribe(board.id)
    %{user: user, board: board, flow: flow, card: card}
  end

  defp reload(board, card), do: Relay.Cards.get_card(board, card.id)

  test "answering a needs-input card resumes the same node with the stored session",
       %{user: user, board: board, flow: flow, card: card} do
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, job}

    {:ok, _run} =
      Runs.report_outcome(job, %{outcome: :needs_input, detail: "Which auth model?", session_id: "s_test1"})

    assert_receive {:run_parked, _run}

    {:ok, _card} = Relay.Cards.answer_input(reload(board, card), "Use board keys", {:user, user.id})

    assert_receive {:run_resumed, %Run{status: :running}}
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm", state: :queued} = fresh}
    assert fresh.payload["resume_session"] == "s_test1"
    assert %Run{status: :running, current_node: "brainstorm"} = Runs.get_run!(run.id)
  end

  test "a human claiming mid-run revokes the active job and parks the run; hand-back resumes fresh",
       %{user: user, board: board, flow: flow, card: card} do
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{id: job_id}}

    {:ok, _card} = Relay.Cards.take_over(reload(board, card), {:user, user.id})

    assert_receive {:revoked, %NodeJob{id: ^job_id, state: :revoked}}
    assert_receive {:run_parked, %Run{parked_reason: :claimed}}
    assert %Run{status: :parked, parked_reason: :claimed} = Runs.get_run!(run.id)

    {:ok, _card} = Relay.Cards.assign_ai(reload(board, card), {:user, user.id})

    assert_receive {:run_resumed, %Run{status: :running}}
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"} = fresh}
    assert fresh.payload["resume_session"] == nil
  end

  test "a review rejection re-enters the flow carrying the note",
       %{user: user, board: board, flow: flow, card: card} do
    {:ok, run1} = Runs.start_run(card, flow)
    assert_receive {:dispatched, job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "spec written"})
    assert_receive {:run_finished, %Run{status: :done}}

    # The card now sits in Spec:Review; a human rejects it back to Spec.
    {:ok, _card} = Relay.Cards.reject(reload(board, card), "needs more detail", {:user, user.id})

    # run1's own {:run_started, run1} broadcast (never asserted on above) is
    # still sitting unconsumed in the mailbox, so match on a run id other
    # than run1's rather than the first {:run_started, _} we see.
    assert_receive {:run_started, %Run{id: run2_id} = run2} when run2_id != run1.id
    refute run2.id == run1.id
    assert run2.context == %{"changes_requested" => "needs more detail"}
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"} = fresh}
    assert fresh.payload["vars"]["changes_requested"] == "needs more detail"
  end

  test "no re-entry when the card's latest run failed — a human must intervene",
       %{user: user, board: board, flow: flow, card: card} do
    # Get a rejection onto the card, then fail the re-entered run.
    {:ok, _run1} = Runs.start_run(card, flow)
    assert_receive {:dispatched, job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "v1"})
    assert_receive {:run_finished, %Run{status: :done}}
    {:ok, _card} = Relay.Cards.reject(reload(board, card), "redo it", {:user, user.id})
    assert_receive {:run_started, _run2}
    assert_receive {:dispatched, retry1}
    {:ok, _run} = Runs.report_outcome(retry1, %{outcome: :failed, detail: "err-a"})
    assert_receive {:dispatched, retry2}
    {:ok, _run} = Runs.report_outcome(retry2, %{outcome: :failed, detail: "err-b"})
    assert_receive {:run_finished, %Run{status: :failed}}

    # Another card event arrives; the listener must NOT start a third run.
    {:ok, _comment} =
      Relay.Activity.add_comment(reload(board, card), %{actor: {:user, user.id}, body: "looking"})

    _ = :sys.get_state(Relay.Runs.Listener)
    assert length(Runs.list_runs(reload(board, card))) == 2
  end
end
