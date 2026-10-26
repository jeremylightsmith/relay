defmodule HamacaWeb.BoardRedirectController do
  @moduledoc """
  Resolves the slugless `/board` URL to the user's first active (non-archived) board,
  in creation order (`Boards.list_boards/1`), and redirects to its canonical slug URL
  (`/board/<slug>`). A user with zero active boards is sent to `/boards`, where the
  New board picker opens in first-run mode (RE470) — this never creates a board. Sits
  behind the `:browser` + `require_authenticated` pipeline, so `current_scope.user`
  is always present.
  """

  use HamacaWeb, :controller

  alias Hamaca.Boards

  def index(conn, _params) do
    case Boards.list_boards(conn.assigns.current_scope.user) do
      [board | _] -> redirect(conn, to: ~p"/board/#{board.slug}")
      [] -> redirect(conn, to: ~p"/boards")
    end
  end
end
