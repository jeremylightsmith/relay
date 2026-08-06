defmodule Relay.Runs.Scheduler.ServerTest do
  use Relay.DataCase, async: true

  import Relay.Factory

  alias Relay.Repo
  alias Relay.Runs.Capacity
  alias Relay.Runs.Scheduler.Server
  alias Schemas.Card

  # A fake Relay.Runs.Scheduler.Engine: forwards write calls to a test pid and returns canned
  # active runs. Its collaborators live in an Agent named per-test (started by start_engine/1
  # before the server, so the server's boot reconcile can read them).
  defmodule FakeEngine do
    @moduledoc false
    @behaviour Relay.Runs.Scheduler.Engine

    # The collaborator Agent's name is per-test (ADR 0009: no globally-named singletons). The
    # behaviour is module-based, so there is no state to thread through it; instead the test
    # stashes the name in its own process dictionary and this resolver walks the same
    # `[self() | $callers]` chain the engine uses — the scheduler server re-seeds $callers from
    # the test (Task 3), so the walk lands on it. Nothing to clean up: the entry dies with the
    # test process.
    def put_name(name), do: Process.put(:fake_engine_name, name)

    defp name do
      Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} -> Keyword.get(dict, :fake_engine_name)
          nil -> nil
        end
      end)
    end

    @impl true
    def active_runs(_board_id), do: Agent.get(name(), & &1.runs)

    @impl true
    def start_run(card_id, flow_key, executor_id) do
      send(Agent.get(name(), & &1.test), {:start_run, card_id, flow_key, executor_id})
      :ok
    end

    @impl true
    def resume_run(run_id, executor_id) do
      send(Agent.get(name(), & &1.test), {:resume_run, run_id, executor_id})
      :ok
    end
  end

  setup do
    start_capacity!()
    # Hardcoded executor ids would collide with a concurrent test's real Executor rows; these are
    # unique per test and live only in this test's capacity table. Sorted because
    # Scheduler.take_slot/3's greedy :any branch picks the LOWEST id — the pinned-debit test below
    # pins the higher one so a greedy regression changes which executor the fresh pull lands on.
    [exec_a, exec_b] =
      Enum.sort([System.unique_integer([:positive]), System.unique_integer([:positive])])

    %{exec_a: exec_a, exec_b: exec_b}
  end

  # Start the FakeEngine's collaborator Agent (named per-test), seeded with the test pid and
  # the canned active runs. Must run before the server so boot reconcile sees these runs.
  defp start_engine(runs) do
    test = self()
    name = :"fake_engine_#{System.unique_integer([:positive])}"
    FakeEngine.put_name(name)

    start_supervised!(%{
      id: FakeEngine,
      start: {Agent, :start_link, [fn -> %{test: test, runs: runs} end, [name: name]]}
    })

    :ok
  end

  defp start_server(board_id) do
    start_supervised!(
      {Server,
       [
         board_id: board_id,
         engine: FakeEngine,
         tick_ms: 3_600_000,
         debounce_ms: 5,
         callers: [self()],
         name: :"sched_#{board_id}"
       ]}
    )
  end

  # A board with one enabled flow (shared_clean by default): queue → work → done. Returns the
  # pulls-from card.
  defp board_with_flow(card_status, isolation \\ :shared_clean) do
    board = insert(:board)
    pulls = insert(:stage, board: board, position: 1, type: :queue)
    works = insert(:stage, board: board, position: 2, type: :work)
    lands = insert(:stage, board: board, position: 3, type: :done)

    flow =
      insert(:flow,
        board: board,
        key: "spec",
        enabled: true,
        isolation: isolation,
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id
      )

    card = insert(:card, stage: pulls, status: card_status)
    %{board: board, pulls: pulls, works: works, lands: lands, flow: flow, card: card}
  end

  test "zero capacity is inert and marks the eligible card :queued (criteria 3 + 5)" do
    %{board: board, card: card} = board_with_flow(:ready)
    start_engine([])
    pid = start_server(board.id)

    :ok = Server.reconcile_now(pid)

    refute_receive {:start_run, _, _, _}, 50
    assert Repo.get!(Card, card.id).status == :queued
  end

  test "capacity appearing drives a dispatch without waiting a tick (criterion 2)", %{exec_a: exec_a} do
    %{board: board, card: card} = board_with_flow(:ready)
    start_engine([])
    _pid = start_server(board.id)

    :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 0})

    assert_receive {:start_run, card_id, "spec", ^exec_a}, 500
    assert card_id == card.id
  end

  test "a capacity-parked (:executor_gone) run resumes once its card is eligible, not re-pulled fresh (criterion 4, scoped to scheduler-owned parks)",
       %{exec_a: exec_a} do
    %{board: board, works: works} = board_with_flow(:ready)
    resumed = insert(:card, stage: works, status: :working)

    start_engine([
      %{
        id: 99,
        card_id: resumed.id,
        status: :parked,
        flow_key: "spec",
        isolation: :shared_clean,
        pinned_executor_id: nil,
        parked_reason: :executor_gone
      }
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    assert_receive {:resume_run, 99, ^exec_a}, 500
    refute_receive {:start_run, _, _, _}, 50
  end

  test "a needs_input-parked run is left alone by the scheduler — the Listener owns it", %{exec_a: exec_a} do
    %{board: board, works: works} = board_with_flow(:ready)
    resumed = insert(:card, stage: works, status: :working)

    start_engine([
      %{
        id: 99,
        card_id: resumed.id,
        status: :parked,
        flow_key: "spec",
        isolation: :shared_clean,
        pinned_executor_id: nil,
        parked_reason: :needs_input
      }
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    refute_receive {:resume_run, _, _}, 50
  end

  test "an in-flight :running run holds its capacity slot across reconciles (B3 accounting)", %{exec_a: exec_a} do
    %{board: board, pulls: pulls} = board_with_flow(:ready)
    other_card = insert(:card, stage: pulls, status: :ready)

    # A running run (on some other card) already holds the board's only advertised
    # shared_clean slot — the executor's next heartbeat hasn't caught up yet.
    start_engine([
      %{id: 55, card_id: -1, status: :running, flow_key: "spec", isolation: :shared_clean, pinned_executor_id: nil}
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    refute_receive {:start_run, _, _, _}, 50
    assert Repo.get!(Card, other_card.id).status == :queued
  end

  test "a :parked run holds no capacity slot — only :running runs are debited", %{exec_a: exec_a} do
    %{board: board, card: card} = board_with_flow(:ready)

    start_engine([
      %{id: 55, card_id: -1, status: :parked, flow_key: "spec", isolation: :shared_clean, pinned_executor_id: nil}
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    assert_receive {:start_run, card_id, "spec", ^exec_a}, 500
    assert card_id == card.id
  end

  test "an in-flight :exclusive run with no pin debits greedily against :any", %{exec_a: exec_a} do
    %{board: board, pulls: pulls} = board_with_flow(:ready, :exclusive)
    other_card = insert(:card, stage: pulls, status: :ready)

    # A pre-first-claim exclusive run carries no pin (pinned_executor_id nil), so it
    # still debits greedily against :any — the aggregate slot count is what matters.
    start_engine([
      %{
        id: 55,
        card_id: -1,
        status: :running,
        flow_key: "spec",
        isolation: :exclusive,
        pinned_executor_id: nil,
        pinned_executor_name: nil
      }
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 0, exclusive: 1})
    :ok = Server.reconcile_now(pid)

    refute_receive {:start_run, _, _, _}, 50
    assert Repo.get!(Card, other_card.id).status == :queued
  end

  test "an in-flight pinned :exclusive run debits its pinned executor, not the lowest-id one",
       %{exec_a: exec_a, exec_b: exec_b} do
    # Two executors advertise one exclusive slot each. The running run is pinned to the
    # HIGHER-id executor (exec_b, since `setup` sorts the pair). A pin-targeted debit spends
    # exec_b, so the fresh pull lands on exec_a. A greedy-:any debit would instead spend
    # exec_a (the lowest id) and land the fresh pull on exec_b — so the executor the fresh card
    # lands on is what distinguishes the two behaviors.
    %{board: board, card: card} = board_with_flow(:ready, :exclusive)

    start_engine([
      %{
        id: 55,
        card_id: -1,
        status: :running,
        flow_key: "spec",
        isolation: :exclusive,
        pinned_executor_id: exec_b,
        pinned_executor_name: "pinned"
      }
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 0, exclusive: 1})
    :ok = Capacity.put(exec_b, %{shared_clean: 0, exclusive: 1})
    :ok = Server.reconcile_now(pid)

    # exec_b is spent by the pinned running run; exec_a is free → the ready card dispatches there.
    assert_receive {:start_run, card_id, "spec", ^exec_a}, 500
    assert card_id == card.id
  end

  test "a pinned :exclusive run whose executor is gone falls back to debiting :any", %{exec_a: exec_a, exec_b: exec_b} do
    # reserve_slot/2's `:none -> debit_any` branch: the run is pinned to exec_b, but exec_b
    # advertises no capacity (it went away). take_slot({:pinned, exec_b}) returns :none, so the
    # run falls back to a greedy :any debit and still consumes the one slot exec_a has — leaving
    # nothing for the fresh ready card, which must NOT dispatch. Without the fallback the pinned
    # run would hold no slot and the ready card would wrongly dispatch on exec_a.
    %{board: board} = board_with_flow(:ready, :exclusive)

    start_engine([
      %{
        id: 55,
        card_id: -1,
        status: :running,
        flow_key: "spec",
        isolation: :exclusive,
        pinned_executor_id: exec_b,
        pinned_executor_name: "pinned"
      }
    ])

    pid = start_server(board.id)
    # Only exec_a advertises capacity; the pinned executor (exec_b) is absent from the map.
    :ok = Capacity.put(exec_a, %{shared_clean: 0, exclusive: 1})
    :ok = Server.reconcile_now(pid)

    # The pinned run debits exec_a via the :any fallback, so no exclusive slot remains for the
    # ready card — it stays queued rather than dispatching.
    refute_receive {:start_run, _card_id, _flow, _executor}, 300
  end

  test "a :running run whose flow was deleted (isolation: nil) leaves capacity untouched", %{exec_a: exec_a} do
    %{board: board, card: card} = board_with_flow(:ready)

    start_engine([
      %{id: 55, card_id: -1, status: :running, flow_key: "gone", isolation: nil, pinned_executor_id: nil}
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    assert_receive {:start_run, card_id, "spec", ^exec_a}, 500
    assert card_id == card.id
  end

  test "disabling the flow unqueues a previously :queued card (criterion 5)" do
    %{board: board, flow: flow, card: card} = board_with_flow(:ready)
    start_engine([])
    pid = start_server(board.id)

    :ok = Server.reconcile_now(pid)
    assert Repo.get!(Card, card.id).status == :queued

    {:ok, _} = Relay.Flows.disable_flow(flow)
    :ok = Server.reconcile_now(pid)

    assert Repo.get!(Card, card.id).status == :ready
  end
end
