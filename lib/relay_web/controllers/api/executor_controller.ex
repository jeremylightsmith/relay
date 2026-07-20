defmodule RelayWeb.Api.ExecutorController do
  @moduledoc """
  `GET /api/executors` (RLY-177) — the machine answer to "is anything connected?", so it
  is one call rather than an SSH session.

  Composes `Relay.Runs.list_executor_status/2` rather than adding a second executor read:
  that function already board-scopes the `NodeJob → Run → Card` join and computes the
  tri-state `freshness` (`Runs.executor_freshness/2`), whose `:gone` branch is deliberately
  the same `executor_stale?/2` predicate the reclaim sweep uses — so a `gone` row here means
  the reaper has already acted, not merely that a beat looks late.
  """
  use RelayWeb, :controller

  alias Relay.Runs

  def index(conn, _params) do
    render(conn, :index, executors: Runs.list_executor_status(conn.assigns.current_board))
  end
end
