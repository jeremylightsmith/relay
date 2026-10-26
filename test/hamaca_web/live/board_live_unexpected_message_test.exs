defmodule HamacaWeb.BoardLiveUnexpectedMessageTest do
  @moduledoc """
  RE411 — a message `HamacaWeb.BoardLive` has no clause for (a `Hamaca.Events`
  broadcast it doesn't consume yet, an orphaned `Task` reply) must be ignored
  rather than crash every open board with a `FunctionClauseError`.
  """
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hamaca.Boards

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  test "survives an unknown atom message", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    send(view.pid, :unexpected)

    assert render(view) =~ ~s(id="board")
    assert has_element?(view, "#board")
    assert Process.alive?(view.pid)
  end

  test "survives a stray Task reply tuple", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    send(view.pid, {make_ref(), :stray_task_reply})

    _ = render(view)
    assert has_element?(view, "#board")
    assert Process.alive?(view.pid)
  end
end
