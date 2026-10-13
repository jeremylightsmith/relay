defmodule RelayWeb.Api.SetupController do
  @moduledoc """
  The board-key setup endpoints.

  `POST /api/setup/preflight` and `POST /api/setup/installed` (RE443) are the install handshake.
  The script served at `GET /b/:slug/install` calls them: preflight before it writes anything (its
  first authed call ticks setup step 3), installed after (finishing step 4).
  `Relay.Setup.preflight/2` / `installed/2` do the work.

  `GET /api/setup` and `POST /api/setup/steps/:step` (RE445) are how `./relay setup status|report`
  — and through it the `/relay-onboard` skill — read the checklist and move its reportable step
  (`Relay.Setup.reportable_id/1`). Both answer `{"data": checklist}` (`RelayWeb.Api.SetupJSON`).
  Every endpoint works the key's own setup (`Relay.Setup.target_for_key/1`, RE446): a connected
  machine's checklist for the key minted for it, else the board's.

  Refusals use the `RelayWeb.Api.ErrorJSON` envelope.
  """
  use RelayWeb, :controller

  alias Relay.Flows
  alias Relay.Setup
  alias RelayWeb.Api.ErrorJSON

  @statuses Map.new(Setup.advance_statuses(), &{Atom.to_string(&1), &1})

  def preflight(conn, params), do: respond(conn, Setup.preflight(conn.assigns.current_api_key, params))

  def installed(conn, params), do: respond(conn, Setup.installed(conn.assigns.current_api_key, params))

  def status(conn, _params) do
    case conn |> target() |> Setup.checklist() do
      nil -> no_checklist(conn)
      checklist -> render_checklist(conn, checklist)
    end
  end

  # The body is read from `conn.body_params`, not `params`, so the path's `step` can't collide.
  def report(conn, %{"step" => step_id}) do
    target = target(conn)

    with {:ok, status, attrs} <- parse_report(conn.body_params),
         {:ok, checklist} <- Setup.advance(target, step_id, status, attrs) do
      render_checklist(conn, checklist)
    else
      {:error, :invalid} -> error(conn, :unprocessable_entity, "invalid", "Invalid request")
      {:error, :no_checklist} -> no_checklist(conn)
      {:error, :not_current} -> not_current(conn, step_id, Setup.checklist(target))
    end
  end

  defp target(conn), do: Setup.target_for_key(conn.assigns.current_api_key)

  defp parse_report(%{"status" => status} = body) when is_map_key(@statuses, status) do
    optional = [{"evidence", &is_binary/1}, {"error", &is_binary/1}, {"data", &is_map/1}]

    Enum.reduce_while(optional, {:ok, @statuses[status], %{}}, fn {key, valid?}, {:ok, status, attrs} ->
      case Map.get(body, key) do
        nil -> {:cont, {:ok, status, attrs}}
        value -> put_valid(valid?.(value), key, value, status, attrs)
      end
    end)
  end

  defp parse_report(_body), do: {:error, :invalid}

  defp put_valid(true, key, value, status, attrs), do: {:cont, {:ok, status, Map.put(attrs, key, value)}}
  defp put_valid(false, _key, _value, _status, _attrs), do: {:halt, {:error, :invalid}}

  # Both routes answer the files the board's flows name (RE447); computed here because
  # `Relay.Setup` can't depend on `Relay.Flows`.
  defp render_checklist(conn, checklist) do
    board = conn.assigns.current_board

    conn
    |> put_view(json: RelayWeb.Api.SetupJSON)
    |> render(:show,
      checklist: checklist,
      board: board,
      referenced_files: Flows.referenced_files(Flows.list_flows(board))
    )
  end

  defp no_checklist(conn), do: error(conn, :not_found, "no_checklist", "no guided setup on this board")

  defp not_current(conn, _step_id, nil), do: no_checklist(conn)

  defp not_current(conn, step_id, checklist) do
    current = Setup.reportable_id(checklist)

    message =
      if current,
        do: "step #{step_id} isn't current; the current step is #{current}",
        else: "step #{step_id} isn't current; setup is finished"

    error(conn, :conflict, "not_current", message, %{current: current})
  end

  defp respond(conn, {:ok, body}), do: json(conn, body)

  defp respond(conn, {:error, :wrong_board}),
    do: error(conn, :forbidden, "wrong_board", "this key belongs to a different board")

  defp respond(conn, {:error, :step_2_pending}),
    do: error(conn, :conflict, "step_2_pending", "Pick a default LLM in the setup wizard first (step 2).")

  defp respond(conn, {:error, :invalid}), do: error(conn, :unprocessable_entity, "invalid", "Invalid request")

  defp error(conn, status, code, message, details \\ %{}) do
    conn
    |> put_status(status)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: code, message: message, details: details)
  end
end
