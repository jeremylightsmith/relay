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

  test "an open Run tab flips a node row on {:run_changed, card_id} without remount",
       %{conn: conn, board: board, card: card, run: run, ne: ne} do
    ref = Cards.ref(board, card)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    refute has_element?(view, "#card-drawer-tab-panel-run", "2:40")

    # `Schemas.NodeExecution` has no stored `duration_s` column (RLY-132 drift, see
    # `RelayWeb.RunComponents`'s moduledoc) — the read side derives it from the
    # started_at/finished_at gap, so a 160s duration is a finished_at 160s out.
    ne
    |> Ecto.Changeset.change(outcome: :succeeded, finished_at: DateTime.add(ne.started_at, 160, :second))
    |> Relay.Repo.update!()

    run
    |> Ecto.Changeset.change(current_node: "spec_review")
    |> Relay.Repo.update!()

    Runs.broadcast_run_changed(board.id, card.id)

    assert has_element?(view, "#card-drawer-tab-panel-run", "2:40")
    assert has_element?(view, "#card-drawer-tab-panel-run", "spec_review")
    assert has_element?(view, "#card-drawer")
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
end
