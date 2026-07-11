defmodule RelayWeb.BoardLiveAgentLogTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.AgentLog
  alias Relay.Boards

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  test "the top-right toggle opens the bottom sheet", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    refute has_element?(view, "#agent-log-sheet")

    view |> element("#agent-logs-button") |> render_click()

    assert has_element?(view, "#agent-log-sheet")
    assert has_element?(view, "#agent-log-empty")
  end

  test "the open panel is in-flow inside the board viewport, not a fixed overlay",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    view |> element("#agent-logs-button") |> render_click()

    # the panel lives inside the fixed-height board viewport, as a flex sibling of the
    # board, so opening it pushes the board up instead of floating over the bottom of it
    assert has_element?(view, "#board-viewport #board")
    assert has_element?(view, "#board-viewport #agent-log-sheet.flex-none")

    # regression (the rejection): it must NOT be a fixed overlay anymore
    refute has_element?(view, "#agent-log-sheet.fixed")
  end

  test "an agent_log broadcast renders a line while the sheet is open", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    view |> element("#agent-logs-button") |> render_click()

    AgentLog.record(board.id, [%{"ref" => "RLY-1", "kind" => "claude", "text" => "hello from claude"}])

    html = render(view)
    assert html =~ "hello from claude"
    assert has_element?(view, "#agent-log-lines", "RLY-1")
  end

  test "closing the sheet removes it and unsubscribes", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    view |> element("#agent-logs-button") |> render_click()
    assert has_element?(view, "#agent-log-sheet")

    view |> element("#agent-log-close") |> render_click()
    refute has_element?(view, "#agent-log-sheet")

    # unsubscribed: a new broadcast is not rendered
    AgentLog.record(board.id, [%{"kind" => "claude", "text" => "after close"}])
    refute render(view) =~ "after close"
  end

  test "the sheet keeps only the newest 500 lines", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    view |> element("#agent-logs-button") |> render_click()

    entries =
      for n <- 1..501 do
        %{"kind" => "claude", "text" => "line-#{String.pad_leading(Integer.to_string(n), 4, "0")}"}
      end

    AgentLog.record(board.id, entries)

    html = render(view)
    refute html =~ "line-0001"
    assert html =~ "line-0501"
  end
end
