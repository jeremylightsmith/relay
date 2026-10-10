defmodule RelayWeb.Api.HarnessController do
  @moduledoc """
  `GET /api/harnesses` (RE433) — the board's harness definitions as the runner expands them, plus
  `Relay.Agents.harnesses_digest/1`. The runner fetches this at start and again whenever a
  heartbeat's `harnesses_digest` differs from the one it holds.
  """
  use RelayWeb, :controller

  alias Relay.Agents

  def index(conn, _params) do
    board = conn.assigns.current_board
    render(conn, :index, harnesses: Agents.list_harnesses(board), digest: Agents.harnesses_digest(board))
  end
end
