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
      state = Agent.get(name(), & &1)
      if Map.get(state, :raise_on_start), do: raise("engine exploded")
      send(state.test, {:start_run, card_id, flow_key, runner_id})
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
  defp start_engine(runs, opts \\ []) do
    test = self()
    name = :"fake_engine_#{System.unique_integer([:positive])}"
    FakeEngine.put_name(name)

    start_supervised!(%{
      id: FakeEngine,
      start: {Agent, :start_link, [fn -> Map.merge(%{test: test, runs: runs}, Map.new(opts)) end, [name: name]]}
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
        stage_id: works.id
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

  # RE387: a reconcile that raises used to crash the board's scheduler; its boot reconcile raised
  # again on every restart, so one bad board blew the shared SchedulerSupervisor's restart
  # intensity and took EVERY board's scheduler down with it. The failure must stay on its board.
  test "a reconcile that raises is logged and the board's scheduler survives" do
    %{board: board, exec_a: exec_a} = board_with_flow(:ready)
    start_engine([], raise_on_start: true)
    pid = start_server(board.id)
    :ok = Capacity.put(exec_a, board.id, %{shared_clean: 1, exclusive: 0})

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Server.reconcile_now(pid) end)

    assert Process.alive?(pid)
    assert log =~ "engine exploded"
    assert log =~ to_string(board.id)
  end

  test "capacity appearing drives a dispatch without waiting a tick (criterion 2)" do
    %{board: board, card: card, exec_a: exec_a} = board_with_flow(:ready)
    start_engine([])
    _pid = start_server(board.id)

    :ok = Capacity.put(exec_a, board.id, %{shared_clean: 1, exclusive: 0})

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
    :ok = Capacity.put(exec_a, board.id, %{shared_clean: 1, exclusive: 0})
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
    :ok = Capacity.put(exec_a, board.id, %{shared_clean: 1, exclusive: 0})
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
    :ok = Capacity.put(exec_a, board.id, %{shared_clean: 1, exclusive: 0})
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
    :ok = Capacity.put(exec_a, board.id, %{shared_clean: 1, exclusive: 0})
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
    :ok = Capacity.put(exec_a, board.id, %{shared_clean: 0, exclusive: 1})
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
    :ok = Capacity.put(exec_a, board.id, %{shared_clean: 0, exclusive: 1})
    :ok = Capacity.put(exec_b, board.id, %{shared_clean: 0, exclusive: 1})
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
    :ok = Capacity.put(exec_a, board.id, %{shared_clean: 0, exclusive: 1})
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
    :ok = Capacity.put(exec_a, board.id, %{shared_clean: 1, exclusive: 0})
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

      :ok = Capacity.put(exec_a, board.id, %{shared_clean: 1, exclusive: 1})
      :ok = Capacity.put(foreign.id, foreign.board_id, %{shared_clean: 3, exclusive: 2})
      :ok = Capacity.put(orphan, board.id, %{shared_clean: 3, exclusive: 2})

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

      for {id, board_id} <- [
            {fresh, board.id},
            {stale.id, board.id},
            {gone.id, board.id},
            {foreign.id, foreign.board_id},
            {orphan, board.id}
          ] do
        :ok = Capacity.put(id, board_id, %{shared_clean: 1, exclusive: 1})
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
      :ok = Capacity.put(exec_a, board.id, %{shared_clean: 0, exclusive: 1})
      :ok = Capacity.put(foreign.id, foreign.board_id, %{shared_clean: 0, exclusive: 2})
      :ok = Server.reconcile_now(pid)

      refute_receive {:start_run, _card_id, _flow, _runner}, 300
      assert Repo.get!(Card, card.id).status == :queued
    end
  end

  describe "narrow snapshot assembly (RE402)" do
    # A second :ready pulls card, agent-owned and blocked by a card in the works stage.
    defp busy_board do
      ctx = board_with_flow(:ready)
      blocker = insert(:card, stage: ctx.works, status: :working)
      owned = insert(:card, stage: ctx.pulls, status: :ready)
      insert(:card_owner, card: owned)
      board = Repo.preload(ctx.board, [])
      {:ok, _} = Relay.Cards.set_dependencies(board, owned, [Relay.Cards.ref(board, blocker)])
      Map.merge(ctx, %{blocker: blocker, owned: owned})
    end

    test "a steady-state reconcile issues at most five Repo queries" do
      %{board: board, exec_a: exec_a} = busy_board()
      :ok = Capacity.put(exec_a, board.id, %{shared_clean: 1, exclusive: 0})
      start_engine([])
      pid = start_server(board.id)
      :ok = Server.reconcile_now(pid)

      {:ok, count} = count_repo_queries(pid, fn -> Server.reconcile_now(pid) end)

      assert count <= 5
    end

    test "build_snapshot/2 is exactly five queries and carries refusal_stamped on runs" do
      %{board: board, blocker: blocker} = busy_board()
      run = insert(:run, card: blocker, status: :running)

      {{snapshot, _cards_by_id}, count} =
        count_repo_queries(self(), fn -> Server.build_snapshot(board.id, Relay.Runs.Scheduler.RunsEngine) end)

      assert count == 5
      assert [%{id: run_id, refusal_stamped: false}] = snapshot.runs
      assert run_id == run.id
    end

    test "cards_by_id holds the snapshot card maps" do
      %{board: board, card: card} = board_with_flow(:ready)

      {snapshot, cards_by_id} = Server.build_snapshot(board.id, NoopEngine)
      snap_card = Enum.find(snapshot.cards, &(&1.id == card.id))

      assert cards_by_id[card.id] == snap_card

      assert snap_card |> Map.keys() |> Enum.sort() == [
               :active_owner,
               :blocked_by,
               :id,
               :position,
               :ref,
               :stage_id,
               :status
             ]
    end
  end

  describe "quiescent dormant boards and the jittered tick (RE402)" do
    # A dormant board (no advertised capacity) whose last full reconcile saw no active runs.
    defp settled_dormant_board do
      ctx = board_with_flow(:ready)
      start_engine([])
      pid = start_server(ctx.board.id)
      :ok = Server.reconcile_now(pid)
      # The reconcile's own `:queued` write echoes back as a card event — drain it first.
      assert %{settled?: true} = await_flushed(pid)
      Map.put(ctx, :pid, pid)
    end

    # `:sys.get_state/1` is a message queued after the tick, so it returns once the tick ran.
    defp tick_and_sync(pid) do
      send(pid, :tick)
      :sys.get_state(pid)
    end

    defp await_flushed(pid, tries \\ 100) do
      case :sys.get_state(pid) do
        %{pending: nil} = state ->
          state

        _pending when tries > 0 ->
          Process.sleep(5)
          await_flushed(pid, tries - 1)
      end
    end

    defp await_status(card_id, status, tries \\ 100) do
      case Repo.get!(Card, card_id).status do
        ^status ->
          status

        other when tries == 0 ->
          other

        _other ->
          Process.sleep(5)
          await_status(card_id, status, tries - 1)
      end
    end

    test "a tick on a settled dormant board issues zero Repo queries" do
      %{pid: pid} = settled_dormant_board()

      {_state, count} = count_repo_queries(pid, fn -> tick_and_sync(pid) end)

      assert count == 0
    end

    test "a capacity wake-up on a settled dormant board issues zero Repo queries" do
      %{pid: pid} = settled_dormant_board()

      {_state, count} =
        count_repo_queries(pid, fn ->
          send(pid, {:runner_capacity_changed, -1})
          await_flushed(pid)
        end)

      assert count == 0
    end

    test "a card event on a settled dormant board reconciles in full" do
      %{pulls: pulls, lands: lands} = settled_dormant_board()
      c2 = Repo.get!(Card, insert(:card, stage: lands, status: :ready).id)

      {:ok, _moved} = Relay.Cards.move_card(c2, pulls, 0, :agent)

      assert await_status(c2.id, :queued) == :queued
    end

    test "a tick on a live board reconciles in full" do
      %{pid: pid, board: board, exec_a: exec_a} = settled_dormant_board()
      :ok = Capacity.put(exec_a, board.id, %{shared_clean: 0, exclusive: 1})
      await_flushed(pid)

      {_state, count} = count_repo_queries(pid, fn -> tick_and_sync(pid) end)

      assert count > 0
    end

    test "a tick on a board whose last reconcile saw active runs reconciles in full" do
      %{board: board} = board_with_flow(:ready)

      start_engine([
        %{
          id: 99,
          card_id: -1,
          status: :parked,
          flow_key: "spec",
          isolation: :shared_clean,
          pinned_runner_id: nil,
          parked_reason: :runner_gone
        }
      ])

      pid = start_server(board.id)
      :ok = Server.reconcile_now(pid)
      assert :sys.get_state(pid).settled? == false

      {_state, count} = count_repo_queries(pid, fn -> tick_and_sync(pid) end)

      assert count > 0
    end

    test "reconcile_now/1 on a settled dormant board is never skipped" do
      %{pid: pid} = settled_dormant_board()

      {:ok, count} = count_repo_queries(pid, fn -> Server.reconcile_now(pid) end)

      assert count > 0
    end

    test "a reconcile that raises leaves the board unsettled" do
      %{board: board, exec_a: exec_a} = board_with_flow(:ready)
      start_engine([], raise_on_start: true)
      pid = start_server(board.id)
      assert :sys.get_state(pid).settled? == true
      :ok = Capacity.put(exec_a, board.id, %{shared_clean: 1, exclusive: 0})

      ExUnit.CaptureLog.capture_log(fn -> assert :ok = Server.reconcile_now(pid) end)

      assert Process.alive?(pid)
      assert :sys.get_state(pid).settled? == false
    end

    test "tick_delay/2 draws the first tick from 1..tick_ms and later ticks from ±20%" do
      firsts = for _ <- 1..1_000, do: Server.tick_delay(1_000, :first)
      assert Enum.all?(firsts, &(is_integer(&1) and &1 in 1..1_000))
      assert firsts |> Enum.uniq() |> length() >= 2

      nexts = for _ <- 1..1_000, do: Server.tick_delay(1_000, :next)
      assert Enum.all?(nexts, &(is_integer(&1) and &1 in 800..1_200))
      assert nexts |> Enum.uniq() |> length() >= 2

      assert Server.tick_delay(1, :first) == 1
    end

    test "boards started back-to-back do not tick in lockstep" do
      start_engine([])

      remaining =
        for _ <- 1..5 do
          board = insert(:board)

          pid =
            start_supervised!(
              {Server,
               [
                 board_id: board.id,
                 engine: FakeEngine,
                 tick_ms: 3_600_000,
                 callers: [self()],
                 name: :"sched_jitter_#{board.id}"
               ]},
              id: {:sched_jitter, board.id}
            )

          Process.read_timer(:sys.get_state(pid).tick_ref)
        end

      assert Enum.all?(remaining, &(is_integer(&1) and &1 in 0..3_600_000))
      assert Enum.max(remaining) - Enum.min(remaining) > 10_000
    end
  end
end
