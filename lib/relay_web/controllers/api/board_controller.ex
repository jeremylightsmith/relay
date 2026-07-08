defmodule RelayWeb.Api.BoardController do
  use RelayWeb, :controller

  alias Relay.Boards
  alias Relay.Cards

  action_fallback RelayWeb.Api.FallbackController

  def show(conn, _params) do
    board = conn.assigns.current_board
    render(conn, :show, board: board, stages: Boards.list_stages(board), cards: Cards.list_cards(board))
  end
end
