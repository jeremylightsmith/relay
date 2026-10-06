defmodule Relay.Runs.SchedulerPresenceTest do
  # async: false — this test flips the global `:runs_auto_start` env and inspects the
  # application-wide `SchedulerSupervisor` / `SchedulerRegistry`, which every other test shares.
  use Relay.DataCase, async: false

  alias Relay.Runs.RunnerReaper
  alias Relay.Runs.SchedulerRegistry
  alias Relay.Runs.SchedulerSupervisor

  setup do
    start_engine!()

    # Boot-time enumeration (`start_all/0`) is gated on this; it is off in test so booting never
    # queries the DB. The sweep under test is the same policy, so turn it on for this test only.
    previous = Application.get_env(:relay, :runs_auto_start, false)
    Application.put_env(:relay, :runs_auto_start, true)

    # The schedulers this test starts are children of the APPLICATION-wide supervisor, so they
    # outlive the sandbox unless stopped — left running, their next tick queries this test's
    # rolled-back board and crash-loops, which can exhaust the supervisor's restart intensity
    # and take down schedulers belonging to later tests (see spec_flow_e2e_test.exs).
    before = scheduler_pids()

    on_exit(fn ->
      Application.put_env(:relay, :runs_auto_start, previous)
      Enum.each(scheduler_pids() -- before, &DynamicSupervisor.terminate_child(SchedulerSupervisor, &1))
    end)

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Appeared After Boot"})

    # Long interval → the reaper's own timer stays dormant and each sweep is one we trigger. Its
    # sandbox access comes from `callers:`, the same seam the engine tree uses. Started once per
    # test: `start_supervised!` dedups on the spec's id, so a second start would collide.
    reaper =
      start_supervised!(
        {RunnerReaper,
         interval_ms: to_timeout(hour: 1), name: :"reaper_#{System.unique_integer([:positive])}", callers: [self()]}
      )

    %{board: board, reaper: reaper}
  end

  defp scheduler_pids do
    SchedulerSupervisor |> DynamicSupervisor.which_children() |> Enum.map(fn {_, pid, _, _} -> pid end)
  end

  defp scheduler_running?(board_id), do: Registry.lookup(SchedulerRegistry, board_id) != []

  defp sweep!(reaper) do
    send(reaper, :sweep)
    # Ensure the :sweep message has been fully handled before asserting.
    _ = :sys.get_state(reaper)
    :ok
  end

  test "a sweep starts a scheduler for a board that appeared after boot", %{board: board, reaper: reaper} do
    refute scheduler_running?(board.id),
           "precondition: a board created after boot has no scheduler yet"

    :ok = sweep!(reaper)

    assert scheduler_running?(board.id),
           "the sweep must adopt a board that did not exist at boot, or its cards never dispatch"
  end

  test "a sweep adopts a board unarchived after boot", %{board: board, reaper: reaper} do
    # Archived boards are not enumerated, so one archived at boot has no scheduler. Unarchiving
    # makes it dispatch-eligible again — the sweep has to notice.
    {:ok, board} = Relay.Boards.archive_board(board)
    :ok = sweep!(reaper)
    refute scheduler_running?(board.id), "precondition: an archived board is correctly skipped"

    {:ok, board} = Relay.Boards.unarchive_board(board)
    :ok = sweep!(reaper)

    assert scheduler_running?(board.id), "unarchiving must put the board back under a scheduler"
  end
end
