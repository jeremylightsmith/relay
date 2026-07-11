defmodule RelayWeb.BoardLiveMobileTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  describe "board at mobile widths" do
    setup :register_and_log_in_user

    test "the horizontal band container allows momentum touch scrolling",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      style = view |> element("#board-bands") |> render()
      assert style =~ "-webkit-overflow-scrolling:touch"
      assert style =~ "overscroll-behavior-x:contain"
    end
  end
end
