defmodule HamacaWeb.Api.DiagnosisController do
  @moduledoc """
  `GET /api/cards/:ref/diagnosis` (RLY-177) — one call answering "why isn't this card
  moving?", so an operator never again hand-writes an Ecto query through three quoting
  layers over `fly ssh console`. Read-only.
  """
  use HamacaWeb, :controller

  alias Hamaca.Cards
  alias Hamaca.Runs

  action_fallback HamacaWeb.Api.FallbackController

  def show(conn, %{"ref" => ref}) do
    board = conn.assigns.current_board

    # Re-queried scoped to this board: a ref belonging to another board must 404, never
    # 403 — a 403 would confirm the card exists somewhere.
    case Cards.get_card_by_ref(board, ref) do
      %Schemas.Card{} = card -> render(conn, :show, diagnosis: Runs.diagnose(board, card))
      nil -> {:error, :not_found}
    end
  end
end
