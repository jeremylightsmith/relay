defmodule RelayWeb.BoardRedirectController do
  @moduledoc """
  Resolves the slugless `/board` URL to the user's default board and
  redirects to its canonical slug URL (`/board/<slug>`). Sits behind the
  `:browser` + `require_authenticated` pipeline, so `current_scope.user`
  is always present.
  """

  use RelayWeb, :controller

  alias Relay.Boards

  def index(conn, _params) do
    board = Boards.get_or_create_default_board(conn.assigns.current_scope.user)
    redirect(conn, to: ~p"/board/#{board.slug}")
  end
end
