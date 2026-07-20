defmodule RelayWeb.Api.ExecutorController do
  @moduledoc """
  `GET /api/executors` (RLY-177) — the machine answer to "is anything connected?", so it
  is one call rather than an SSH session.

  Composes `Relay.Runs.list_executor_status/2` rather than adding a second executor read:
  that function already board-scopes the `NodeJob → Run → Card` join and derives freshness
  from the same `executor_stale?/2` predicate the reclaim sweep uses.
  """
  use RelayWeb, :controller

  alias Relay.Runs

  def index(conn, _params) do
    render(conn, :index, executors: Runs.list_executor_status(conn.assigns.current_board))
  end
end
