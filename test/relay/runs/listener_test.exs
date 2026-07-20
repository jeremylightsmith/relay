defmodule Relay.Runs.ListenerTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Relay.Runs.Listener
  alias Relay.Runs.Scheduler.Server
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

    _ = :sys.get_state(Listener)
    assert length(Runs.list_runs(reload(board, card))) == 2
  end

  test "a parked run with an unexpected parked_reason (e.g. nil) is left alone, not crashed on",
       %{user: user, board: board, card: card} do
    run =
      insert(:run,
        card: card,
        flow_key: "spec",
        status: :parked,
        parked_reason: nil,
        current_node: "brainstorm"
      )

    listener_pid = Process.whereis(Listener)
    ref = Process.monitor(listener_pid)

    {:ok, _comment} =
      Relay.Activity.add_comment(reload(board, card), %{actor: {:user, user.id}, body: "still parked"})

    _ = :sys.get_state(Listener)
    refute_receive {:DOWN, ^ref, :process, ^listener_pid, _reason}

    assert %Run{status: :parked, parked_reason: nil} = Runs.get_run!(run.id)
  end

  test "answering a needs-input card resumes with the stored session even when the scheduler reconciles first",
       %{user: user, board: board, flow: flow, card: card} do
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, job}

    {:ok, _run} =
      Runs.report_outcome(job, %{outcome: :needs_input, detail: "Which auth model?", session_id: "s_race"})

    assert_receive {:run_parked, _run}

    start_supervised!(
      {Server,
       [
         board_id: board.id,
         engine: Relay.Runs.Scheduler.RunsEngine,
         tick_ms: 3_600_000,
         debounce_ms: 5,
         name: :"race_sched_#{board.id}"
       ]}
    )

    {:ok, _card} = Relay.Cards.answer_input(reload(board, card), "Use board keys", {:user, user.id})

    # Force the scheduler to reconcile SYNCHRONOUSLY, ahead of the Listener's own async
    # mailbox processing of the same card event — proving the authority split (the
    # scheduler now refuses to touch a :needs_input park at all), not debounce timing, is
    # what keeps this from double-resuming.
    :ok = Server.reconcile_now(:"race_sched_#{board.id}")

    assert_receive {:run_resumed, %Run{status: :running}}
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"} = fresh}
    assert fresh.payload["resume_session"] == "s_race"
    assert %Run{status: :running, current_node: "brainstorm"} = Runs.get_run!(run.id)

    # Exactly one resume — no second broadcast from a scheduler-driven resume.
    refute_receive {:run_resumed, _}, 100
  end

  test "boot sweep resumes a parked needs-input run whose answer arrived while the Listener was down",
       %{user: user, board: board, flow: flow, card: card} do
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, job}

    {:ok, _run} =
      Runs.report_outcome(job, %{outcome: :needs_input, detail: "Which auth model?", session_id: "s_boot"})

    assert_receive {:run_parked, _run}

    # Take the whole engine tree down — the Listener is gone — then answer the card. In
    # production this is "the answer arrived while nothing was listening".
    stop_supervised!(Relay.Runs.Supervisor)
    {:ok, _card} = Relay.Cards.answer_input(reload(board, card), "Use board keys", {:user, user.id})

    refute_receive {:run_resumed, _}, 100

    # Bring the engine tree back — the Listener's own boot sweep must self-heal without any
    # new card event.
    start_supervised!(Relay.Runs.Supervisor)

    assert_receive {:run_resumed, %Run{status: :running}}
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"} = fresh}
    assert fresh.payload["resume_session"] == "s_boot"
    assert %Run{status: :running} = Runs.get_run!(run.id)
  end
end
