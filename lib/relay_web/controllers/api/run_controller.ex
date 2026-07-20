defmodule RelayWeb.Api.RunController do
  @moduledoc """
  Human-initiated run recovery (RLY-189). `POST /api/runs/:id/retry` is the
  id-addressed route the card names; `POST /api/cards/:ref/retry` is the
  ref-addressed alias the CLI uses, because every other `relay` verb is
  ref-addressed and making the CLI discover a run id first would be a worse
  surface for no gain. Both funnel into one private function.

  Board-scoped like the rest of this scope: a run on another board is a 404,
  never a refusal that would confirm it exists.
  """
  use RelayWeb, :controller

  alias Relay.Cards
  alias Relay.Runs
  alias RelayWeb.Api.ErrorJSON

  action_fallback RelayWeb.Api.FallbackController

  def retry(conn, %{"id" => id} = params) do
    board = conn.assigns.current_board

    with {run_id, ""} <- Integer.parse(id),
         %Schemas.Run{} = run <- Runs.get_run(run_id),
         true <- Runs.board_id_of(run) == board.id do
      do_retry(conn, run, params)
    else
      _not_found -> {:error, :not_found}
    end
  end

  def retry_card(conn, %{"ref" => ref} = params) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         %Schemas.Run{} = run <- Runs.latest_run_for_retry(card) do
      do_retry(conn, run, params)
    else
      _not_found -> {:error, :not_found}
    end
  end

  defp do_retry(conn, run, params) do
    case Runs.retry_run(run, at: params["at"]) do
      {:ok, run} ->
        json(conn, %{
          data: %{status: "ok", run_id: run.id, node: run.current_node, retries: run.retries}
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: ErrorJSON)
        |> render(:error,
          code: Runs.retry_refusal_code(reason),
          message: Runs.retry_refusal_message(reason)
        )
    end
  end
end
