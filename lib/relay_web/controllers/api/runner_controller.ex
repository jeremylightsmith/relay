defmodule RelayWeb.Api.RunnerController do
  @moduledoc """
  `GET /api/runners` (RLY-177) — the machine answer to "is anything connected?", so it
  is one call rather than an SSH session.

  Composes `Relay.Runs.list_runner_status/2` rather than adding a second runner read:
  that function already board-scopes the `NodeJob → Run → Card` join and computes the
  tri-state `freshness` (`Runs.runner_freshness/2`), whose `:gone` branch is deliberately
  the same `runner_stale?/2` predicate the reclaim sweep uses — so a `gone` row here means
  the reaper has already acted, not merely that a beat looks late.
  """
  use RelayWeb, :controller

  alias Relay.Runs

  def index(conn, _params) do
    render(conn, :index, runners: Runs.list_runner_status(conn.assigns.current_board))
  end
end
