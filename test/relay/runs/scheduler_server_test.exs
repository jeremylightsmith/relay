defmodule Relay.Runs.Scheduler.ServerTest do
  use Relay.DataCase, async: true

  import Relay.Factory

  alias Relay.Repo
  alias Relay.Runs.Capacity
  alias Relay.Runs.Scheduler.NoopEngine
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
    def start_run(card_id, flow_key, runner_id) do
      send(Agent.get(name(), & &1.test), {:start_run, card_id, flow_key, runner_id})
      :ok
    end

    @impl true
    def resume_run(run_id, runner_id) do
      send(Agent.get(name(), & &1.test), {:resume_run, run_id, runner_id})
      :ok
    end
  end

  setup do
    start_capacity!()
    :ok
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

    # RE338: the snapshot counts only THIS board's non-:gone runners, so every capacity entry a
    # test advertises must belong to a real Runner row on the board. Sorted because
    # Scheduler.take_slot/3's greedy :any branch picks the LOWEST id — the pinned-debit test
    # pins the higher one so a greedy regression changes which runner the fresh pull lands on.
    [exec_a, exec_b] = Enum.sort([insert(:runner, board: board).id, insert(:runner, board: board).id])

    %{
      board: board,
      pulls: pulls,
      works: works,
      lands: lands,
      flow: flow,
      card: card,
      exec_a: exec_a,
      exec_b: exec_b
    }
  end

  test "zero capacity is inert and marks the eligible card :queued (criteria 3 + 5)" do
    %{board: board, card: card} = board_with_flow(:ready)
    start_engine([])
    pid = start_server(board.id)

    :ok = Server.reconcile_now(pid)

    refute_receive {:start_run, _, _, _}, 50
    assert Repo.get!(Card, card.id).status == :queued
  end

  test "capacity appearing drives a dispatch without waiting a tick (criterion 2)" do
    %{board: board, card: card, exec_a: exec_a} = board_with_flow(:ready)
    start_engine([])
    _pid = start_server(board.id)

    :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 0})

    assert_receive {:start_run, card_id, "spec", ^exec_a}, 500
    assert card_id == card.id
  end

  test "a capacity-parked (:runner_gone) run resumes once its card is eligible, not re-pulled fresh (criterion 4, scoped to scheduler-owned parks)" do
    %{board: board, works: works, exec_a: exec_a} = board_with_flow(:ready)
    resumed = insert(:card, stage: works, status: :working)

    start_engine([
      %{
        id: 99,
        card_id: resumed.id,
        status: :parked,
        flow_key: "spec",
        isolation: :shared_clean,
        pinned_runner_id: nil,
        parked_reason: :runner_gone
      }
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    assert_receive {:resume_run, 99, ^exec_a}, 500
    refute_receive {:start_run, _, _, _}, 50
  end

  test "a needs_input-parked run is left alone by the scheduler — the Listener owns it" do
    %{board: board, works: works, exec_a: exec_a} = board_with_flow(:ready)
    resumed = insert(:card, stage: works, status: :working)

    start_engine([
      %{
        id: 99,
        card_id: resumed.id,
        status: :parked,
        flow_key: "spec",
        isolation: :shared_clean,
        pinned_runner_id: nil,
        parked_reason: :needs_input
      }
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    refute_receive {:resume_run, _, _}, 50
  end

  test "an in-flight :running run holds its capacity slot across reconciles (B3 accounting)" do
    %{board: board, pulls: pulls, exec_a: exec_a} = board_with_flow(:ready)
    other_card = insert(:card, stage: pulls, status: :ready)

    # A running run (on some other card) already holds the board's only advertised
    # shared_clean slot — the runner's next heartbeat hasn't caught up yet.
    start_engine([
      %{id: 55, card_id: -1, status: :running, flow_key: "spec", isolation: :shared_clean, pinned_runner_id: nil}
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    refute_receive {:start_run, _, _, _}, 50
    assert Repo.get!(Card, other_card.id).status == :queued
  end

  test "a :parked run holds no capacity slot — only :running runs are debited" do
    %{board: board, card: card, exec_a: exec_a} = board_with_flow(:ready)

    start_engine([
      %{id: 55, card_id: -1, status: :parked, flow_key: "spec", isolation: :shared_clean, pinned_runner_id: nil}
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    assert_receive {:start_run, card_id, "spec", ^exec_a}, 500
    assert card_id == card.id
  end

  test "an in-flight :exclusive run with no pin debits greedily against :any" do
    %{board: board, pulls: pulls, exec_a: exec_a} = board_with_flow(:ready, :exclusive)
    other_card = insert(:card, stage: pulls, status: :ready)

    # A pre-first-claim exclusive run carries no pin (pinned_runner_id nil), so it
    # still debits greedily against :any — the aggregate slot count is what matters.
    start_engine([
      %{
        id: 55,
        card_id: -1,
        status: :running,
        flow_key: "spec",
        isolation: :exclusive,
        pinned_runner_id: nil,
        pinned_runner_name: nil
      }
    ])

    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, %{shared_clean: 0, exclusive: 1})
    :ok = Server.reconcile_now(pid)

    refute_receive {:start_run, _, _, _}, 50
    assert Repo.get!(Card, other_card.id).status == :queued
  end

  test "an in-flight pinned :exclusive run debits its pinned runner, not the lowest-id one" do
    # Two runners advertise one exclusive slot each. The running run is pinned to the
    # HIGHER-id runner (exec_b, since `setup` sorts the pair). A pin-targeted debit spends
    # exec_b, so the fresh pull lands on exec_a. A greedy-:any debit would instead spend
    # exec_a (the lowest id) and land the fresh pull on exec_b — so the runner the fresh card
    # lands on is what distinguishes the two behaviors.
    %{board: board, card: card, exec_a: exec_a, exec_b: exec_b} = board_with_flow(:ready, :exclusive)

    start_engine([
      %{
        id: 55,
        card_id: -1,
        status: :running,
        flow_key: "spec",
        isolation: :exclusive,
        pinned_runner_id: exec_b,
        pinned_runner_name: "pinned"
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

  test "a pinned :exclusive run whose runner is gone falls back to debiting :any" do
    # reserve_slot/2's `:none -> debit_any` branch: the run is pinned to exec_b, but exec_b
    # advertises no capacity (it went away). take_slot({:pinned, exec_b}) returns :none, so the
    # run falls back to a greedy :any debit and still consumes the one slot exec_a has — leaving
    # nothing for the fresh ready card, which must NOT dispatch. Without the fallback the pinned
    # run would hold no slot and the ready card would wrongly dispatch on exec_a.
    %{board: board, exec_a: exec_a, exec_b: exec_b} = board_with_flow(:ready, :exclusive)

    start_engine([
      %{
        id: 55,
        card_id: -1,
        status: :running,
        flow_key: "spec",
        isolation: :exclusive,
        pinned_runner_id: exec_b,
        pinned_runner_name: "pinned"
      }
    ])

    pid = start_server(board.id)
    # Only exec_a advertises capacity; the pinned runner (exec_b) is absent from the map.
    :ok = Capacity.put(exec_a, %{shared_clean: 0, exclusive: 1})
    :ok = Server.reconcile_now(pid)

    # The pinned run debits exec_a via the :any fallback, so no exclusive slot remains for the
    # ready card — it stays queued rather than dispatching.
    refute_receive {:start_run, _card_id, _flow, _runner}, 300
  end

  test "a :running run whose flow was deleted (isolation: nil) leaves capacity untouched" do
    %{board: board, card: card, exec_a: exec_a} = board_with_flow(:ready)

    start_engine([
      %{id: 55, card_id: -1, status: :running, flow_key: "gone", isolation: nil, pinned_runner_id: nil}
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

  describe "board-scoped capacity (RE338)" do
    test "another board's runner and an orphan ETS entry contribute no capacity to this board's snapshot" do
      %{board: board, exec_a: exec_a} = board_with_flow(:ready)
      foreign = insert(:runner, board: insert(:board))
      # A negative id can never be a Runner row: an ETS entry nothing on any board owns.
      orphan = -System.unique_integer([:positive])

      :ok = Capacity.put(exec_a, %{shared_clean: 1, exclusive: 1})
      :ok = Capacity.put(foreign.id, %{shared_clean: 3, exclusive: 2})
      :ok = Capacity.put(orphan, %{shared_clean: 3, exclusive: 2})

      {snapshot, _cards} = Server.build_snapshot(board.id, NoopEngine)

      assert Map.keys(snapshot.capacity) == [exec_a]
    end

    test "every capacity key is a counting runner the roster names (invariant)" do
      %{board: board, exec_a: fresh} = board_with_flow(:ready)
      now = DateTime.truncate(DateTime.utc_now(), :second)
      # interval 30 (factory default): fresh <= 45s, gone > 60s, so 50s old is :stale.
      stale = insert(:runner, board: board, last_heartbeat: DateTime.add(now, -50, :second))
      gone = insert(:runner, board: board, last_heartbeat: DateTime.add(now, -600, :second))
      foreign = insert(:runner, board: insert(:board))
      orphan = -System.unique_integer([:positive])

      for id <- [fresh, stale.id, gone.id, foreign.id, orphan] do
        :ok = Capacity.put(id, %{shared_clean: 1, exclusive: 1})
      end

      {snapshot, _cards} = Server.build_snapshot(board.id, NoopEngine)
      capacity_ids = snapshot.capacity |> Map.keys() |> MapSet.new()

      roster_ids =
        for r <- Relay.Runs.list_runner_status(board), Relay.Runs.counting_runner?(r), into: MapSet.new(), do: r.id

      assert MapSet.subset?(capacity_ids, roster_ids)
      assert capacity_ids == MapSet.new([fresh, stale.id])
    end

    test "another board's free exclusive slots do not dispatch this board's card (no over-dispatch)" do
      %{board: board, card: card, exec_a: exec_a} = board_with_flow(:ready, :exclusive)
      # Inserted after exec_a, so it has the higher id: before RE338 the in-flight run's greedy
      # :any debit spent exec_a's only slot and the fresh pull landed on this foreign runner.
      foreign = insert(:runner, board: insert(:board))

      # Board 1's only advertised exclusive slot is held by an in-flight run.
      start_engine([
        %{
          id: 55,
          card_id: -1,
          status: :running,
          flow_key: "spec",
          isolation: :exclusive,
          pinned_runner_id: nil,
          pinned_runner_name: nil
        }
      ])

      pid = start_server(board.id)
      :ok = Capacity.put(exec_a, %{shared_clean: 0, exclusive: 1})
      :ok = Capacity.put(foreign.id, %{shared_clean: 0, exclusive: 2})
      :ok = Server.reconcile_now(pid)

      refute_receive {:start_run, _card_id, _flow, _runner}, 300
      assert Repo.get!(Card, card.id).status == :queued
    end
  end
end
