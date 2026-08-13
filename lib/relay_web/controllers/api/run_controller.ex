defmodule RelayWeb.Api.RunController do
  @moduledoc """
  Human-initiated run recovery (RLY-189) and run observability (RLY-177).

  `POST /api/runs/:id/retry` is the id-addressed route the card names;
  `POST /api/cards/:ref/retry` is the ref-addressed alias the CLI uses, because every
  other `relay` verb is ref-addressed and making the CLI discover a run id first would
  be a worse surface for no gain. Both funnel into one private function.

  `GET /api/cards/:ref/runs` is the card's run history with **untruncated**
  node-execution detail — the observability surface that replaces hand-written Ecto
  queries over `fly ssh console`. Read-only.

  `POST /api/board/restart-stalled` bulk-revives every restartable run on the token's
  board — the headless-operator path for a mass outage (RLY-228).

  `POST /api/runs/:id/cancel` and `POST /api/cards/:ref/cancel` are the stop half of the
  same pair (RE309), delegating to `Relay.Runs.cancel_run/2`. Cancel targets the card's
  ACTIVE run, where retry targets its newest one. Cancelling never moves the card: a caller
  that wants it elsewhere follows with `POST /api/cards/:ref/move`, whose 409 keeps meaning
  exactly what it says.

  Board-scoped like the rest of this scope: a run (or card) on another board is a 404,
  never a refusal that would confirm it exists.
  """
  use RelayWeb, :controller

  alias Relay.Cards
  alias Relay.Runs
  alias RelayWeb.Api.ErrorJSON

  action_fallback RelayWeb.Api.FallbackController

  def index(conn, %{"ref" => ref}) do
    board = conn.assigns.current_board

    # Re-queried scoped to this board: a ref belonging to another board must 404, never
    # 403 — a 403 would confirm the card exists somewhere.
    case Cards.get_card_by_ref(board, ref) do
      %Schemas.Card{} = card -> render(conn, :index, runs: Runs.list_runs_for_card(card))
      nil -> {:error, :not_found}
    end
  end

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

  @doc """
  Bulk-restart every environmentally-stalled run on the caller's board — the headless-operator
  path for a mass outage (RLY-228). Board-scoped by the bearer token like every other route.
  """
  def restart_stalled(conn, _params) do
    board = conn.assigns.current_board
    summary = Runs.restart_stalled(board, conn.assigns.actor)

    json(conn, %{data: %{status: "ok", restarted: summary.restarted, refused: summary.refused}})
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

  @doc """
  Cancel a run by id. Board-scoped: a run on another board is a 404, never a refusal that
  would confirm it exists — the same guard `retry/2` uses.
  """
  def cancel(conn, %{"id" => id} = params) do
    board = conn.assigns.current_board

    with {run_id, ""} <- Integer.parse(id),
         %Schemas.Run{} = run <- Runs.get_run(run_id),
         true <- Runs.board_id_of(run) == board.id do
      do_cancel(conn, run, params)
    else
      _not_found -> {:error, :not_found}
    end
  end

  @doc """
  Cancel a card's ACTIVE run — the ref-addressed route `relay cancel <ref>` calls (RE309).

  `Runs.active_run/1`, not `latest_run_for_retry/1`: retry targets the card's newest run
  whatever its status, cancel targets the live one. An unknown ref is a 404; a card that
  exists with nothing to cancel is a named 422, because a silent success on a refused cancel
  is the specific failure this verb exists to prevent.
  """
  def cancel_card(conn, %{"ref" => ref} = params) do
    board = conn.assigns.current_board

    case Cards.get_card_by_ref(board, ref) do
      nil -> {:error, :not_found}
      %Schemas.Card{} = card -> cancel_active_run(conn, Runs.active_run(card), params)
    end
  end

  defp cancel_active_run(conn, nil, _params), do: refuse_cancel(conn, :not_active)
  defp cancel_active_run(conn, %Schemas.Run{} = run, params), do: do_cancel(conn, run, params)

  defp do_cancel(conn, run, params) do
    board = conn.assigns.current_board
    # Read BEFORE the call: cancel_run/2 nils current_node and moves the status, so the
    # returned run describes the cancel, not what was cancelled.
    previous_status = run.status
    node = run.current_node

    case Runs.cancel_run(run, reason: params["reason"], actor: conn.assigns.actor) do
      {:ok, cancelled} ->
        card = Cards.get_card(board, cancelled.card_id)

        json(conn, %{
          data: %{
            status: "ok",
            run_id: cancelled.id,
            ref: Cards.ref(board, card),
            previous_status: to_string(previous_status),
            node: node
          }
        })

      {:error, reason} ->
        refuse_cancel(conn, reason)
    end
  end

  defp refuse_cancel(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error,
      code: Runs.cancel_refusal_code(reason),
      message: Runs.cancel_refusal_message(reason)
    )
  end
end
