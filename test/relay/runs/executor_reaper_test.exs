defmodule Relay.Runs.ExecutorReaperTest do
  use Relay.DataCase, async: false

  alias Relay.Runs
  alias Relay.Runs.ExecutorReaper
  alias Schemas.Run

  setup do
    # cancel_run/2 (via close_orphaned_runs/0) looks the run up in Relay.Runs.Registry to stop
    # its server; that registry is normally started by Relay.Runs.Supervisor, which config
    # disables app-wide in test (see config/test.exs `:start_runs_supervisor`). Start just the
    # Registry here — not the whole Supervisor — so it doesn't also boot its own default-named
    # ExecutorReaper, which would collide with the one this test starts below.
    start_supervised!({Registry, keys: :unique, name: Relay.Runs.Registry})

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Reaper Board"})
    %{board: board}
  end

  test "one sweep closes a zombie run whose card is already in Done", %{board: board} do
    done = Enum.find(board.stages, &(&1.name == "Done"))
    card = insert(:card, stage: done)
    run = insert(:run, card: card, status: :running)

    # Long interval → the reaper's own timer stays dormant; we trigger exactly one sweep.
    pid = start_supervised!({ExecutorReaper, interval_ms: to_timeout(hour: 1)})
    send(pid, :sweep)
    # Ensure the :sweep message has been fully handled before asserting.
    _ = :sys.get_state(pid)

    assert %Run{status: :cancelled} = Runs.get_run!(run.id)
  end
end
