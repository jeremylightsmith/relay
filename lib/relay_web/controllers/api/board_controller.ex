defmodule RelayWeb.Api.BoardController do
  use RelayWeb, :controller

  alias Relay.Boards
  alias Relay.BoardWatch
  alias Relay.Cards

  action_fallback RelayWeb.Api.FallbackController

  def show(conn, _params) do
    board = conn.assigns.current_board
    render(conn, :show, board: board, stages: Boards.list_stages(board), cards: Cards.list_cards(board))
  end

  def version(conn, _params) do
    version = BoardWatch.version(conn.assigns.current_board.id)

    conn
    |> put_resp_header("etag", Integer.to_string(version))
    |> json(%{version: version})
  end
end
