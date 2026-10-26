defmodule HamacaWeb.Api.RunnerController do
  @moduledoc """
  `GET /api/runners` (RLY-177) — the machine answer to "is anything connected?", so it
  is one call rather than an SSH session.

  Composes `Hamaca.Runs.list_runner_status/2` rather than adding a second runner read:
  that function already board-scopes the `NodeJob → Run → Card` join and computes the
  tri-state `freshness` (`Runs.runner_freshness/2`), whose `:gone` branch is deliberately
  the same `runner_stale?/2` predicate the reclaim sweep uses — so a `gone` row here means
  the runner no longer counts (it is not offered work), not merely that a beat looks late. Its
  in-flight work is held for up to the reclaim window (`Runs.shared_reclaim_after_s/0`,
  `Runs.exclusive_reclaim_after_s/0`, RE449) before the reaper requeues or parks it.
  """
  use HamacaWeb, :controller

  alias Hamaca.Runs

  def index(conn, _params) do
    render(conn, :index, runners: Runs.list_runner_status(conn.assigns.current_board))
  end
end
