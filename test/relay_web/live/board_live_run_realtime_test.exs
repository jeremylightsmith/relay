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
end
