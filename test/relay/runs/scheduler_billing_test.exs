defmodule Relay.Runs.SchedulerBillingTest do
  # RE460 — a paused owner's board gets no new runs: the per-board scheduler skips the reconcile
  # entirely until the owner pays, then dispatches as usual.
  use Relay.DataCase, async: true

  import Relay.Factory

  alias Relay.Billing
  alias Relay.Runs.Capacity
  alias Relay.Runs.Scheduler.Server

  # A minimal Relay.Runs.Scheduler.Engine: no active runs, and every write is reported to the
  # test — the server re-seeds `$callers` from `callers: [self()]`, so the test pid is its head.
  defmodule RecordingEngine do
    @moduledoc false
    @behaviour Relay.Runs.Scheduler.Engine

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

  test "a paused owner's board dispatches nothing until the owner pays (scenario 8)" do
    today = Date.utc_today()
    board = insert(:board)
    pulls = insert(:stage, board: board, position: 1, type: :queue)
    works = insert(:stage, board: board, position: 2, type: :work)
    insert(:stage, board: board, position: 3, type: :done)
    insert(:flow, board: board, key: "spec", enabled: true, isolation: :shared_clean, stage_id: works.id)
    card = insert(:card, stage: pulls, status: :ready)
    runner = insert(:runner, board: board)
    insert(:billing_account, user: board.owner, paid_through: Date.add(today, -10), billing_day: today.day)

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
         ]}
      )

    :ok = Capacity.put(runner.id, board.id, %{shared_clean: 1, exclusive: 0})
    :ok = Server.reconcile_now(pid)

    refute_receive {:start_run, _, _, _}, 100

    assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{board.owner_id}", board.owner_id, today)
    :ok = Server.reconcile_now(pid)

    card_id = card.id
    runner_id = runner.id
    assert_receive {:start_run, ^card_id, "spec", ^runner_id}, 500
  end
end
