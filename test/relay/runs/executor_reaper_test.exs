defmodule Relay.Runs.ExecutorReaperTest do
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Relay.Runs.ExecutorReaper
  alias Schemas.Run

  setup do
    # cancel_run/2 (via close_orphaned_runs/0) looks the run up in this instance's Registry to
    # stop its server, so the test needs a real engine tree. start_engine!/0 gives it one under
    # unique names (ADR 0009), which is what makes this module async.
    start_engine!()

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Reaper Board"})
    %{board: board}
  end

  test "one sweep closes a zombie run whose card is already in Done", %{board: board} do
    done = Enum.find(board.stages, &(&1.name == "Done"))
    card = insert(:card, stage: done)
    run = insert(:run, card: card, status: :running)

    # Long interval → the reaper's own timer stays dormant; we trigger exactly one sweep. Its own
    # sandbox access comes from `callers:`, the same seam the engine tree uses.
    pid =
      start_supervised!(
        {ExecutorReaper,
         interval_ms: to_timeout(hour: 1), name: :"reaper_#{System.unique_integer([:positive])}", callers: [self()]}
      )

    send(pid, :sweep)
    # Ensure the :sweep message has been fully handled before asserting.
    _ = :sys.get_state(pid)

    assert %Run{status: :cancelled} = Runs.get_run!(run.id)
  end
end
