defmodule RelayWeb.UsageTrackTest do
  @moduledoc """
  RE475 — the `RelayWeb.UsageTrack` `on_mount` hook and the `RelayWeb.Plugs.UsageTrack` plug
  touch the signed-in user's visit on `Relay.Usage.Tracker`. Each test runs its own tracker,
  reached through the `:usage_tracker` `Relay.Config` seam.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Usage.Tracker

  setup do
    name = :"usage_tracker_#{System.unique_integer([:positive])}"
    # Allowed because terminate/2 flushes into the sandbox when the test stops it.
    tracker = allow!(start_supervised!({Tracker, name: name, flush_ms: 3_600_000}))
    Process.put(:usage_tracker, name)

    %{tracker: tracker}
  end

  describe "a signed-in user" do
    setup :register_and_log_in_user

    setup %{user: user} do
      %{board: Boards.get_or_create_default_board(user)}
    end

    test "mounting BoardLive records the board and the ?card ref", %{
      conn: conn,
      user: user,
      board: board,
      tracker: tracker
    } do
      {:ok, _view, _html} = live(conn, ~p"/board/#{board.slug}?card=RL1")

      assert %{board_id: board_id, card_refs: card_refs} = Tracker.open_visits(tracker)[user.id]
      assert board_id == board.id
      assert "RL1" in card_refs
    end

    test "an event through the view touches the visit again", %{
      conn: conn,
      user: user,
      board: board,
      tracker: tracker
    } do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      Tracker.flush(tracker)
      refute Tracker.open_visits(tracker)[user.id].dirty?

      render_click(view, "open_archived", %{})

      visit = Tracker.open_visits(tracker)[user.id]
      assert visit.dirty?
      assert visit.board_id == board.id
    end

    test "a dead render through the :browser pipeline opens a visit", %{conn: conn, user: user, tracker: tracker} do
      conn = get(conn, ~p"/boards")

      assert html_response(conn, 200)
      assert Map.has_key?(Tracker.open_visits(tracker), user.id)
    end
  end

  test "a signed-out request records nothing and is served unchanged", %{conn: conn, tracker: tracker} do
    conn = get(conn, ~p"/")

    assert conn.status == 200
    assert Tracker.open_visits(tracker) == %{}
  end

  test "the superadmin is tracked on the :admin live_session", %{conn: conn, tracker: tracker} do
    admin = insert(:user, email: hd(Schemas.Scope.superadmin_emails()))

    {:ok, _view, _html} = conn |> log_in_user(admin) |> live(~p"/admin/users")

    assert Map.has_key?(Tracker.open_visits(tracker), admin.id)
  end
end
