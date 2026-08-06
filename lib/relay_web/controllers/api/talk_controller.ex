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

  @doc """
  Appends a batch of transcript lines. At-least-once: a replayed `client_seq` is accepted and
  stored once, so the executor may retry freely. Only a non-list `events` 422s the whole batch —
  a list containing a malformed element is `Relay.Talk`'s concern, which drops that one line and
  stores the rest (the same "a mangled line must never cost the whole batch" rule as a map
  missing `client_seq`).
  """
  def events(conn, %{"id" => id} = params) do
    with {:ok, turn} <- fetch_turn(conn, id),
         raw when is_list(raw) <- Map.get(params, "events", []) do
      {:ok, stored} = Talk.append_events(turn, raw)
      json(conn, %{status: "ok", accepted: length(stored)})
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_events}
    end
  end

  @doc "Ends a turn. `done` carries the `claude` session id that makes the NEXT turn a continuation."
  def outcome(conn, %{"id" => id} = params) do
    with {:ok, turn} <- fetch_turn(conn, id),
         {:ok, status} <- parse_status(params["status"]),
         {:ok, session_id} <- binary_or_nil(params["session_id"]),
         {:ok, detail} <- binary_or_nil(params["detail"]) do
      {:ok, updated} = Talk.finish_turn(turn, status, %{session_id: session_id, detail: detail})
      json(conn, %{status: "ok", turn_state: Atom.to_string(updated.status)})
    end
  end

  # The executor is untrusted input — the same rule `Relay.Talk.normalize_event/1` states for the
  # events route. Unchecked, a JSON object or number here fails `cast(…, :string)` and
  # `Repo.update!` raises `Ecto.InvalidChangesetError`, which the FallbackController cannot
  # render: a 500, and a turn left `:claimed` behind a `:done` job.
  defp binary_or_nil(nil), do: {:ok, nil}
  defp binary_or_nil(value) when is_binary(value), do: {:ok, value}
  defp binary_or_nil(_value), do: {:error, :invalid_outcome}

  # A turn on another board is `:not_found`, never a 403 — the same rule the rest of /api uses,
  # so a probe cannot learn that an id exists elsewhere.
  defp fetch_turn(conn, id) do
    board = conn.assigns.current_board

    with {int, ""} <- Integer.parse(to_string(id)),
         %{} = turn <- Talk.get_turn(int),
         true <- Talk.board_id_of(turn) == board.id do
      {:ok, turn}
    else
      _absent -> {:error, :not_found}
    end
  end

  defp parse_status(value) when is_binary(value) do
    case Enum.find(Schemas.TalkTurn.reportable_statuses(), &(Atom.to_string(&1) == value)) do
      nil -> {:error, :unknown_status}
      status -> {:ok, status}
    end
  end

  defp parse_status(_value), do: {:error, :unknown_status}
end
