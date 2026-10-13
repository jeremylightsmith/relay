defmodule RelayWeb.Api.SetupController do
  @moduledoc """
  `POST /api/setup/preflight` and `POST /api/setup/installed` (RE443) — the board-key half of the
  install handshake. The script served at `GET /b/:slug/install` calls them: preflight before it
  writes anything (its first authed call ticks setup step 3), installed after (finishing step 4).
  `Relay.Setup.preflight/2` / `installed/2` do the work; this maps their refusals to the
  `RelayWeb.Api.ErrorJSON` envelope.
  """
  use RelayWeb, :controller

  alias Relay.Setup
  alias RelayWeb.Api.ErrorJSON

  def preflight(conn, params), do: respond(conn, Setup.preflight(conn.assigns.current_api_key, params))

  def installed(conn, params), do: respond(conn, Setup.installed(conn.assigns.current_api_key, params))

  defp respond(conn, {:ok, body}), do: json(conn, body)

  defp respond(conn, {:error, :wrong_board}),
    do: error(conn, :forbidden, "wrong_board", "this key belongs to a different board")

  defp respond(conn, {:error, :step_2_pending}),
    do: error(conn, :conflict, "step_2_pending", "Pick a default LLM in the setup wizard first (step 2).")

  defp respond(conn, {:error, :invalid}), do: error(conn, :unprocessable_entity, "invalid", "Invalid request")

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: code, message: message)
  end
end
