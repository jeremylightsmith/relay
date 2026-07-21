defmodule RelayWeb.BoardLiveRunRealtimeTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Runs

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Live run"})
    {:ok, card} = Cards.assign_ai(card)
    {:ok, card} = Cards.set_status(card, %{status: :working})
    run = insert(:run, card: card, current_node: "implement")
    ne = insert(:node_execution, run: run, node: "implement", outcome: nil, duration_s: nil)
    %{board: board, card: card, run: run, ne: ne}
  end

  test "an open Run tab flips a node row on {:run_changed, card_id} after the debounced flush",
       %{conn: conn, board: board, card: card, run: run, ne: ne} do
    ref = Cards.ref(board, card)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    refute has_element?(view, "#card-drawer-tab-panel-run", "2:40")

    # `Schemas.NodeExecution` has no stored `duration_s` column (RLY-132 drift) — the read
    # side derives it from the started_at/finished_at gap, so a 160s duration is finished_at 160s out.
    ne
    |> Ecto.Changeset.change(outcome: :succeeded, finished_at: DateTime.add(ne.started_at, 160, :second))
    |> Relay.Repo.update!()

    run
    |> Ecto.Changeset.change(current_node: "spec_review")
    |> Relay.Repo.update!()

    board_id = board.id
    attach_run_flush_telemetry()
    Runs.broadcast_run_changed(board.id, card.id)

    assert_receive {:run_flush, %{card_count: 1}, %{board_id: ^board_id}}, 500

    assert has_element?(view, "#card-drawer-tab-panel-run", "2:40")
    assert has_element?(view, "#card-drawer-tab-panel-run", "spec_review")
    assert has_element?(view, "#card-drawer")
  end

  test "a burst of run events triggers one card-scoped flush, not one per event",
       %{conn: conn, board: board, run: run} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    board_id = board.id
    attach_run_flush_telemetry()

    for _ <- 1..5, do: send(view.pid, {:run_started, run})

    assert_receive {:run_flush, measurements, %{board_id: ^board_id}}, 500
    assert measurements.event_count == 5
    assert measurements.card_count == 1

    # exactly one flush covers the whole burst
    refute_receive {:run_flush, _measurements, %{board_id: ^board_id}}, 300
  end

  test "a run event updates only the card it names", %{conn: conn, board: board} do
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card_a} = Cards.create_card(code, %{title: "Card A"})
    {:ok, card_b} = Cards.create_card(code, %{title: "Card B"})
    run_a = insert(:run, card: card_a, current_node: "implement", status: :running)
    run_b = insert(:run, card: card_b, current_node: "implement", status: :running)
    insert(:node_execution, run: run_a, node: "implement", outcome: nil, duration_s: nil)
    insert(:node_execution, run: run_b, node: "implement", outcome: nil, duration_s: nil)

    ref_a = Cards.ref(board, card_a)
    ref_b = Cards.ref(board, card_b)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    assert has_element?(view, "#card-#{ref_a}-run-face[data-run-state=running]")
    assert has_element?(view, "#card-#{ref_b}-run-face[data-run-state=running]")

    # Park card A's run (parked stays an active status, so its face renders regardless of stage),
    # then emit a run event naming ONLY card A.
    run_a
    |> Ecto.Changeset.change(status: :parked, parked_reason: :needs_input)
    |> Relay.Repo.update!()

    board_id = board.id
    attach_run_flush_telemetry()
    send(view.pid, {:run_parked, run_a})

    assert_receive {:run_flush, %{card_count: 1}, %{board_id: ^board_id}}, 500

    # A's face reflects the parked run; B's face is untouched.
    assert has_element?(view, "#card-#{ref_a}-run-face[data-run-state=parked]")
    assert has_element?(view, "#card-#{ref_b}-run-face[data-run-state=running]")
  end

  test "a runs message for another card leaves the drawer alone",
       %{conn: conn, board: board, card: card} do
    ref = Cards.ref(board, card)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    send(view.pid, {:run_changed, card.id + 999})

    assert has_element?(view, "#card-drawer-tab-panel-run", "implement")
  end

  # RLY-137 — the live engine (Relay.Runs.Listener, Relay.Runs.RunServer) broadcasts
  # these fine-grained events on the same `board:<id>:runs` topic during ordinary
  # board use (claim/park, answer/resume, rejection re-entry, every node transition).
  # BoardLive previously only matched the coarse {:run_changed, card_id} used by
  # tests, so any of these crashed the LiveView with a FunctionClauseError.
  test "surviving the engine's :run_started event on the runs topic", %{conn: conn, board: board, card: card, run: run} do
    assert_survives_run_event(conn, board, card, {:run_started, run})
  end

  test "surviving the engine's :run_parked event on the runs topic", %{conn: conn, board: board, card: card, run: run} do
    assert_survives_run_event(conn, board, card, {:run_parked, run})
  end

  test "surviving the engine's :run_resumed event on the runs topic", %{conn: conn, board: board, card: card, run: run} do
    assert_survives_run_event(conn, board, card, {:run_resumed, run})
  end

  test "surviving the engine's :run_finished event on the runs topic", %{conn: conn, board: board, card: card, run: run} do
    assert_survives_run_event(conn, board, card, {:run_finished, run})
  end

  test "surviving the engine's :node_started event on the runs topic",
       %{conn: conn, board: board, card: card, run: run, ne: ne} do
    assert_survives_run_event(conn, board, card, {:node_started, run, ne})
  end

  test "surviving the engine's :node_finished event on the runs topic",
       %{conn: conn, board: board, card: card, run: run, ne: ne} do
    assert_survives_run_event(conn, board, card, {:node_finished, run, ne})
  end

  defp assert_survives_run_event(conn, board, card, message) do
    ref = Cards.ref(board, card)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    send(view.pid, message)

    assert has_element?(view, "#card-drawer")
  end

  # Attach a per-test handler for the RLY-204 flush event that forwards each measurement +
  # metadata to the test process. Detached on exit. Tests pin `board_id` in their assert so a
  # concurrent (async) test's flush on a different board is ignored.
  defp attach_run_flush_telemetry do
    handler_id = "test-run-flush-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:relay, :board, :run_flush],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:run_flush, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end
end
