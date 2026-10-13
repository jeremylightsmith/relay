defmodule RelayWeb.Api.ScaffoldController do
  @moduledoc """
  `GET /api/scaffold` and `GET /api/scaffold/*path` (RE304, ADR 0010) — the five Relay-owned
  files a project installs with `./relay update`.

  **Unauthenticated on purpose**, on the same `:api` pipeline as `/api/version`: the board's
  install script fetches them before anything has authenticated, and these files were published
  openly regardless. The glob route serves **only** manifest entries (`Relay.Scaffold.fetch/2`
  checks a static allowlist), so it is not a general file server.

  The served `relay` has this board's URL baked into its `BOARD_URL` line (RE443), so a project
  needs no `RELAY_URL`. The URL is `RelayWeb.Endpoint.url/0` — the configured one, **never** the
  request's Host header, which the client controls and which would end up in executed code.
  The manifest is built with the same URL, so its `relay` `sha256` is the sha of exactly the
  bytes `show/2` serves (every pre-v90 runner checks a download that way) and its
  `unbaked_sha256` is the placeholder copy's (what v90+ compares).

  A 503 rather than a 500 when the scaffold has not been built: that is a dev box that skipped
  `mix setup`, not a bug in the request.
  """
  use RelayWeb, :controller

  alias Relay.Scaffold
  alias RelayWeb.Api.ErrorJSON

  def manifest(conn, _params) do
    case Scaffold.manifest(board_url: RelayWeb.Endpoint.url()) do
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
    case Scaffold.fetch(Enum.join(segments, "/"), board_url: RelayWeb.Endpoint.url()) do
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
