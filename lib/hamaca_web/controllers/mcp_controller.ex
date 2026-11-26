defmodule HamacaWeb.McpController do
  @moduledoc """
  `POST /mcp` — the MCP endpoint Claude clients connect to (RE519, ADR 0015). Authenticated by
  `HamacaWeb.McpAuth`; the JSON-RPC itself is `HamacaWeb.Mcp.Server`'s. A reply is 200 JSON, a
  notification 202 with an empty body, and a body that is not a JSON-RPC request object (a batch
  array arrives as `"_json"`) 400. Stateless JSON mode has no server-to-client stream, so
  `GET`/`DELETE /mcp` are 405.
  """

  use HamacaWeb, :controller

  alias HamacaWeb.Mcp.Server

  def handle(conn, _params) do
    message = if Map.has_key?(conn.body_params, "_json"), do: :batch, else: conn.body_params

    case Server.handle(message, conn.assigns.current_user) do
      {:reply, %{error: %{code: code}} = reply} ->
        status = if code == Server.invalid_request_code(), do: 400, else: 200
        conn |> put_status(status) |> json(reply)

      {:reply, reply} ->
        json(conn, reply)

      :accepted ->
        send_resp(conn, 202, "")
    end
  end

  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end
end
