defmodule RelayWeb.Api.SpecFlowE2ETest do
  use RelayWeb.ConnCase, async: false

  import Ecto.Query

  alias Relay.Accounts
  alias Relay.Cards
  alias Relay.Runs
  alias Relay.Runs.Scheduler.ScriptedExecutor, as: Exec
  alias Relay.Runs.SchedulerSupervisor
  alias Schemas.Card

  setup %{conn: conn} do
    Runs.Capacity.reset()
    start_supervised!(Relay.Runs.Supervisor)

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Spec E2E"})
    {:ok, %{token: board_key}} = Relay.ApiKeys.create_key(board, user)
    {:ok, %{token: user_token}} = Accounts.create_user_api_token(user)

    {:ok, _spec} = Relay.Flows.enable_flow(Relay.Flows.get_flow!(board, "spec"))

    {:ok, sched_pid} = SchedulerSupervisor.ensure_started(board.id, debounce_ms: 5, tick_ms: 60_000)
    :ok = Runs.subscribe(board.id)

    # The scheduler is a child of the GLOBAL SchedulerSupervisor (started by the application,
    # not by this test's start_supervised!), so it outlives the test's sandbox unless stopped
    # explicitly. Left running, its next tick/flush queries this test's board after the sandbox
    # rolls the transaction back, crash-looping and — worse — able to exhaust the DynamicSupervisor's
    # restart intensity and take down schedulers for later tests' boards too.
    on_exit(fn -> DynamicSupervisor.terminate_child(SchedulerSupervisor, sched_pid) end)

    exec = put_req_header(conn, "authorization", "Bearer " <> board_key)
    human = put_req_header(conn, "authorization", "Bearer " <> user_token)

    next_up = Enum.find(Relay.Boards.list_stages(board), &(&1.name == "Next up"))
    %{board: board, exec: exec, human: human, next_up: next_up}
  end

  defp card_ref(board, card), do: Cards.ref(board, Relay.Repo.get!(Card, card.id))
  defp reload(card), do: Relay.Repo.get!(Card, card.id)
  defp stage_named(board, name), do: Enum.find(Relay.Boards.list_stages(board), &(&1.name == name))

  test "a card in Next up runs the Spec flow end to end: claim -> logs -> needs_input -> answer -> resume -> Spec:Review",
       %{board: board, exec: exec, human: human, next_up: next_up} do
    {:ok, card} = Cards.create_card(next_up, %{title: "Design the widget"})
    ref = card_ref(board, card)

    # 1-3. Advertise capacity; the capacity broadcast wakes the scheduler (no tick wait),
    # which dispatches a run whose brainstorm node-job reaches :queued (this is B0).
    Exec.heartbeat(exec, "exec-1", %{"shared_clean" => 1})
    assert_receive {:run_started, run}, 2_000
    assert run.card_id == card.id
    assert reload(card).stage_id == board_stage_id(board, "Spec")

    # start_run/3 broadcasts the first node_started right after run_started; consume it here
    # so later `assert_receive {:node_started, ...}` calls in this test can't match this stale
    # message instead of the resume's own node_started.
    assert_receive {:node_started, %{id: first_run_id}, first_execution}, 2_000
    assert first_run_id == run.id
    assert first_execution.node_key == "brainstorm"
    assert first_execution.attempt == 1

    # 4. The executor claims it - raw, unexpanded run string; resume_session nil.
    job = Exec.claim(exec, "exec-1", %{"shared_clean" => 1})
    assert job["node_id"] == "brainstorm"
    assert job["node_type"] == "agent"
    assert job["isolation"] == "shared_clean"
    assert job["run"] == "/brainstorm {ref}"
    assert job["vars"]["ref"] == ref
    assert job["resume_session"] == nil

    # 5. Log lines land attributed to the run (via node_job_id -> run). The per-line
    # broadcast is synchronous, so assert_receive proves it with no sleep.
    :ok = Relay.AgentLog.subscribe(board.id)
    Exec.log(exec, ref, job["id"], ["starting brainstorm", "reading the card"])
    assert_receive {:agent_log, %{node_job_id: node_job_id, text: "starting brainstorm"}}, 1_000
    assert node_job_id == to_string(job["id"])

    # 6. The skill asks a structured question, then reports needs_input with a session id.
    questions = [%{"prompt" => "Which storage backend?", "options" => ["Postgres", "SQLite"], "allow_text" => true}]
    Exec.needs_input(exec, ref, questions)
    Exec.outcome(exec, job["id"], %{"outcome" => "needs_input", "session_id" => "sess_e2e_1"})

    # 7. Run parked on needs_input; card blocked; questions round-trip STRUCTURED (RLY-109).
    assert_receive {:run_parked, parked}, 2_000
    assert parked.parked_reason == :needs_input
    blocked = reload(card)
    assert blocked.status == :needs_input

    assert [%{"prompt" => "Which storage backend?", "options" => ["Postgres", "SQLite"]}] =
             Cards.latest_questions(blocked)

    refute Runs.active_job(Runs.get_run!(run.id))

    # 8-9. The human answers; the Listener resumes the SAME node with resume_session set -
    # the single assertion most likely to catch a break between W5's listener and W9's payload.
    human
    |> post("/api/all/cards/#{ref}/answer", %{"answer" => "Use Postgres"})
    |> json_response(200)

    assert_receive {:node_started, resumed_run, resumed_exec}, 2_000
    assert resumed_run.id == run.id
    assert resumed_exec.node_key == "brainstorm"
    resume_job = Runs.active_job(Runs.get_run!(run.id))
    assert resume_job.payload["resume_session"] == "sess_e2e_1"

    # 10-11. The executor claims the resume job and succeeds -> run :done, card at Spec:Review.
    job2 = Exec.claim(exec, "exec-1", %{"shared_clean" => 1})
    assert job2["node_id"] == "brainstorm"
    assert job2["resume_session"] == "sess_e2e_1"
    Exec.outcome(exec, job2["id"], %{"outcome" => "succeeded", "detail" => "spec written"})

    assert_receive {:run_finished, finished}, 2_000
    assert Runs.get_run!(finished.id).status == :done
    landed = reload(card)
    assert landed.stage_id == board_stage_id(board, "Spec:Review")
    assert landed.status == :in_review
  end

  test "advertised capacity is respected: 2 cards, cap 1 -> one dispatches, the second waits",
       %{board: board, exec: exec, next_up: next_up} do
    {:ok, _card_a} = Cards.create_card(next_up, %{title: "First card"})
    {:ok, _card_b} = Cards.create_card(next_up, %{title: "Second card"})

    Exec.heartbeat(exec, "exec-1", %{"shared_clean" => 1})
    assert_receive {:run_started, run1}, 2_000

    # Exactly one active run exists for the board; the second card has none (held for later).
    assert length(Runs.active_runs(board.id)) == 1

    # The running run holds the single shared_clean slot across reconciles: force a
    # synchronous reconcile and confirm the second card still has no run.
    {:ok, sched} = SchedulerSupervisor.ensure_started(board.id)
    :ok = Relay.Runs.Scheduler.Server.reconcile_now(sched)
    assert length(Runs.active_runs(board.id)) == 1

    # Finish the first run; its slot frees and the second card dispatches.
    job1 = Exec.claim(exec, "exec-1", %{"shared_clean" => 1})
    Exec.outcome(exec, job1["id"], %{"outcome" => "succeeded", "detail" => "done"})
    assert_receive {:run_finished, %{id: finished_id}}, 2_000
    assert finished_id == run1.id
    assert_receive {:run_started, run2}, 2_000
    refute run2.card_id == run1.card_id
  end

  test "a node that fails past its retries flags the card with the node's real output (B1)",
       %{board: board, exec: exec, next_up: next_up} do
    {:ok, card} = Cards.create_card(next_up, %{title: "Doomed card"})

    Exec.heartbeat(exec, "exec-1", %{"shared_clean" => 1})
    assert_receive {:run_started, run}, 2_000

    # start_run/3 broadcasts the first node_started right after run_started; drain it here
    # (as the first test does) so the retry's own node_started below is the next message in
    # the mailbox, not this stale one — otherwise the retry assertion below would match the
    # initial attempt-1 message and prove nothing about the retry actually happening.
    assert_receive {:node_started, %{id: first_run_id}, _first_execution}, 2_000
    assert first_run_id == run.id

    # brainstorm has max_retries: 1 and no failed edge -> attempt 1 retries, attempt 2 fails.
    detail = "Traceback (most recent call last):\n  boom\nfatal: the node exploded"

    job1 = Exec.claim(exec, "exec-1", %{"shared_clean" => 1})
    Exec.outcome(exec, job1["id"], %{"outcome" => "failed", "detail" => detail})
    assert_receive {:node_started, _retry_run, %{node_key: "brainstorm", attempt: 2}}, 2_000

    job2 = Exec.claim(exec, "exec-1", %{"shared_clean" => 1})
    Exec.outcome(exec, job2["id"], %{"outcome" => "failed", "detail" => detail})
    assert_receive {:run_finished, %{id: failed_id}}, 2_000

    assert Runs.get_run!(failed_id).status == :failed
    card = reload(card)
    # B1: the card blocks immediately (not silently :ready) and enters the needs-you rollup.
    assert card.status == :needs_input
    assert Cards.needs_you?(card, Relay.Boards.list_stages(board))
    # the failing node's actual output tail is captured on the run's execution (the card's
    # run panel surfaces it) - the reported detail reached the human, not a generic message.
    assert Relay.Repo.exists?(
             from e in Schemas.NodeExecution,
               where: e.run_id == ^failed_id and e.outcome == :failed and ilike(e.detail, "%exploded%")
           )
  end

  defp board_stage_id(board, name), do: stage_named(board, name).id
end
