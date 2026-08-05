defmodule RelayWeb.Api.TalkController do
  @moduledoc """
  The executor's transcript transport (RE268 / ADR 0009). Two routes, both board-scoped by the
  same board-key auth as the rest of `/api`: the executor streams a turn's lines here as it
  produces them, then reports the turn's end state.

  Deliberately NOT `POST /api/node-jobs/:id/outcome`: that route finalises a job through the RUN
  lifecycle, and a talk turn has no run. Keeping them apart is what lets
  `Relay.Runs.get_claimed_job/2` stay flow-only, so a talk job can never be routed through the
  engine by a confused (or hostile) client.

  Pure transport over `Relay.Talk` — ordering, de-duplication and the session pin all live in the
  context.
  """
  use RelayWeb, :controller

  alias Relay.Talk

  action_fallback RelayWeb.Api.FallbackController

  @doc "Appends a batch of transcript lines. At-least-once: a replayed `client_seq` is accepted and stored once, so the executor may retry freely."
  def events(conn, %{"id" => id} = params) do
    with {:ok, turn} <- fetch_turn(conn, id),
         raw when is_list(raw) <- Map.get(params, "events", []) do
      {:ok, stored} = Talk.append_events(turn, raw)
      json(conn, %{status: "ok", accepted: length(stored)})
    else
      {:error, reason} -> {:error, reason}
      _not_a_list -> {:error, :invalid_events}
    end
  end

  @doc "Ends a turn. `done` carries the `claude` session id that makes the NEXT turn a continuation."
  def outcome(conn, %{"id" => id} = params) do
    with {:ok, turn} <- fetch_turn(conn, id),
         {:ok, status} <- parse_status(params["status"]) do
      {:ok, updated} = Talk.finish_turn(turn, status, %{session_id: params["session_id"], detail: params["detail"]})
      json(conn, %{status: "ok", turn_state: Atom.to_string(updated.status)})
    end
  end

  # A turn on another board is `:not_found`, never a 403 — the same rule the rest of /api uses,
  # so a probe cannot learn that an id exists elsewhere.
  defp fetch_turn(conn, id) do
    board = conn.assigns.current_board

    with {int, ""} <- Integer.parse(to_string(id)),
         %{} = turn <- Talk.get_turn(int),
         ^board <- (Talk.board_id_of(turn) == board.id && board) || nil do
      {:ok, turn}
    else
      _absent -> {:error, :not_found}
    end
  end

  # The accepted end states are derived from `Schemas.TalkTurn.statuses/0` minus the ones only
  # the server writes, so the transport can never name a status the domain lacks.
  defp reportable_statuses, do: Schemas.TalkTurn.statuses() -- Schemas.TalkTurn.active_statuses()

  defp parse_status(value) when is_binary(value) do
    case Enum.find(reportable_statuses(), &(Atom.to_string(&1) == value)) do
      nil -> {:error, :unknown_status}
      status -> {:ok, status}
    end
  end

  defp parse_status(_value), do: {:error, :unknown_status}
end
