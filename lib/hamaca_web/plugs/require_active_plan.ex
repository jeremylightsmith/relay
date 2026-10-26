defmodule HamacaWeb.Plugs.RequireActivePlan do
  @moduledoc """
  RE460 — refuses every board-key `/api/*` request for a board whose owner's plan is paused with
  `HamacaWeb.PlanPaused`'s 402. Sits right after `HamacaWeb.ApiAuth` in the `:api_auth` pipeline: it
  reads the `:current_board` that plug assigns, and a bad key must still be a 401. Always passes
  while billing is disabled (`Hamaca.Billing.board_paused?/1` short-circuits on `enabled?/0`).
  """

  alias Hamaca.Billing
  alias HamacaWeb.PlanPaused

  def init(opts), do: opts

  def call(conn, _opts) do
    if Billing.board_paused?(conn.assigns.current_board) do
      PlanPaused.send_refusal(conn)
    else
      conn
    end
  end
end
