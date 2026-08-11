defmodule RelayWeb.Api.ScaffoldController do
  @moduledoc """
  `GET /api/scaffold` and `GET /api/scaffold/*path` (RE304, ADR 0010) — the five Relay-owned
  files a project installs with `bin/relay update`.

  **Unauthenticated on purpose**, on the same `:api` pipeline as `/api/version`: `/relay-setup`
  runs before a project has a board key, and these files were published openly regardless. The
  glob route serves **only** manifest entries (`Relay.Scaffold.fetch/1` checks a static
  allowlist), so it is not a general file server.

  A 503 rather than a 500 when the scaffold has not been built: that is a dev box that skipped
  `mix setup`, not a bug in the request.
  """
  use RelayWeb, :controller

  alias Relay.Scaffold
  alias RelayWeb.Api.ErrorJSON

  def manifest(conn, _params) do
    case Scaffold.manifest() do
      {:ok, manifest} ->
        json(conn, manifest)

      :error ->
        conn
        |> put_status(:service_unavailable)
        |> put_view(json: ErrorJSON)
        |> render(:error, code: "scaffold_unavailable", message: "run `mix relay.build_scaffold`")
    end
  end

  def show(conn, %{"path" => segments}) do
    case Scaffold.fetch(Enum.join(segments, "/")) do
      {:ok, body} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, body)

      :error ->
        conn
        |> put_status(:not_found)
        |> put_view(json: ErrorJSON)
        |> render(:error, code: "not_found", message: "Not found")
    end
  end
end
