defmodule Hamaca.Runs.SchedulerBillingTest do
  # RE460, RE469 — a held owner's board, and a Free owner's read-only board, gets no new runs: the
  # per-board scheduler skips the reconcile entirely until the owner pays, then dispatches as usual.
  use Hamaca.DataCase, async: true

  import Hamaca.Factory

  alias Hamaca.Billing
  alias Hamaca.Runs.Capacity
  alias Hamaca.Runs.Scheduler.Server

  # A minimal Hamaca.Runs.Scheduler.Engine: no active runs, and every write is reported to the
  # test — the server re-seeds `$callers` from `callers: [self()]`, so the test pid is its head.
  defmodule RecordingEngine do
    @moduledoc false
    @behaviour Hamaca.Runs.Scheduler.Engine

    defp test_pid, do: hd(Process.get(:"$callers"))

    @impl true
    def active_runs(_board_id), do: []

    @impl true
    def start_run(card_id, flow_key, runner_id) do
      send(test_pid(), {:start_run, card_id, flow_key, runner_id})
      :ok
    end

    @impl true
    def resume_run(run_id, runner_id) do
      send(test_pid(), {:resume_run, run_id, runner_id})
      :ok
    end
  end

  setup do
    Process.put(:billing_enabled, true)
    start_capacity!()
    :ok
  end

  # A board with one ready card, a flow on its work stage and a runner with a free slot.
  defp dispatchable_board(owner, updated_at) do
    board = insert(:board, owner: owner, updated_at: updated_at)
    pulls = insert(:stage, board: board, position: 1, type: :queue)
    works = insert(:stage, board: board, position: 2, type: :work)
    insert(:stage, board: board, position: 3, type: :done)
    insert(:flow, board: board, key: "spec", enabled: true, isolation: :shared_clean, stage_id: works.id)
    card = insert(:card, stage: pulls, status: :ready, updated_at: updated_at)
    runner = insert(:runner, board: board)
    %{board: board, card: card, runner: runner}
  end

  defp start_server!(board, runner) do
    pid =
      start_supervised!(
        {Server,
         [
           board_id: board.id,
           engine: RecordingEngine,
           tick_ms: 3_600_000,
           debounce_ms: 5,
           callers: [self()],
           name: :"sched_billing_#{board.id}"
         ]},
        id: board.id
      )

    :ok = Capacity.put(runner.id, board.id, %{shared_clean: 1, exclusive: 0})
    pid
  end

  # A Free owner with boards A (older activity) and B: A is read-only, B editable.
  defp free_owner_of_two do
    owner = insert(:user)
    now = DateTime.utc_now(:second)
    a = dispatchable_board(owner, DateTime.add(now, -7200))
    b = dispatchable_board(owner, DateTime.add(now, -60))
    %{owner: owner, a: a, b: b}
  end

  test "a held owner's board dispatches nothing (scenario 8)" do
    today = Date.utc_today()
    %{board: board, runner: runner} = dispatchable_board(insert(:user), DateTime.utc_now(:second))
    insert(:billing_account, user: board.owner, held_on: today, hold_reason: "test")
    pid = start_server!(board, runner)

    :ok = Server.reconcile_now(pid)

    refute_receive {:start_run, _, _, _}, 100
    refute :sys.get_state(pid).settled?
  end

  test "a Free owner's read-only board dispatches nothing, and stays unsettled, until the owner pays" do
    today = Date.utc_today()
    %{owner: owner, a: %{board: a, card: card, runner: runner}} = free_owner_of_two()
    pid = start_server!(a, runner)

    :ok = Server.reconcile_now(pid)

    refute_receive {:start_run, _, _, _}, 100
    refute :sys.get_state(pid).settled?

    assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{owner.id}", owner.id, today)
    :ok = Server.reconcile_now(pid)

    card_id = card.id
    runner_id = runner.id
    assert_receive {:start_run, ^card_id, "spec", ^runner_id}, 500
  end

  test "a Free owner's editable board plans and dispatches as usual" do
    %{b: %{board: b, card: card, runner: runner}} = free_owner_of_two()
    pid = start_server!(b, runner)

    :ok = Server.reconcile_now(pid)

    card_id = card.id
    runner_id = runner.id
    assert_receive {:start_run, ^card_id, "spec", ^runner_id}, 500
  end
end
