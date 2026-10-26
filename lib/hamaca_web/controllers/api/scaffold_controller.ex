defmodule HamacaWeb.Api.ScaffoldController do
  @moduledoc """
  `GET /api/scaffold` and `GET /api/scaffold/*path` (RE304, ADR 0010) — the Hamaca-owned
  files a project installs with its runner's `update`.

  **Two layouts (RE478).** No `layout` query param is the legacy layout — byte-for-byte what
  every v≤93 `./relay` has always been served; `?layout=hamaca` is the Hamaca-named one (see
  `Hamaca.Scaffold`). A `layout` that is not one of `Hamaca.Scaffold.layouts/0` is a 400
  `unknown_layout` on both routes, never a silent fallback: a client that asked for a layout
  it was not given would compare versions across layouts.

  **Unauthenticated on purpose**, on the same `:api` pipeline as `/api/version`: the board's
  install script fetches them before anything has authenticated, and these files were published
  openly regardless. The glob route serves **only** manifest entries (`Hamaca.Scaffold.fetch/2`
  checks a static allowlist), so it is not a general file server.

  The served runner (`Hamaca.Scaffold.runner_path/1` of the layout) has this board's URL baked
  into its `BOARD_URL` line (RE443), so a project needs no `RELAY_URL`. The URL is `HamacaWeb.Endpoint.url/0` — the configured one, **never** the
  request's Host header, which the client controls and which would end up in executed code.
  The manifest is built with the same URL, so its runner `sha256` is the sha of exactly the
  bytes `show/2` serves (every pre-v90 runner checks a download that way) and its
  `unbaked_sha256` is the placeholder copy's (what v90+ compares).

  A 503 rather than a 500 when the scaffold has not been built: that is a dev box that skipped
  `mix setup`, not a bug in the request.
  """
  use HamacaWeb, :controller

  alias Hamaca.Scaffold
  alias HamacaWeb.Api.ErrorJSON

  def manifest(conn, params) do
    case requested_layout(params) do
      {:ok, layout} ->
        case Scaffold.manifest(layout: layout, board_url: HamacaWeb.Endpoint.url()) do
          {:ok, manifest} ->
            json(conn, manifest)

          :error ->
            error(conn, :service_unavailable, "scaffold_unavailable", "run `mix hamaca.build_scaffold`")
        end

      :error ->
        unknown_layout(conn)
    end
  end

  def show(conn, %{"path" => segments} = params) do
    case requested_layout(params) do
      {:ok, layout} ->
        case Scaffold.fetch(Enum.join(segments, "/"), layout: layout, board_url: HamacaWeb.Endpoint.url()) do
          {:ok, body} ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(200, body)

          :error ->
            error(conn, :not_found, "not_found", "Not found")
        end

      :error ->
        unknown_layout(conn)
    end
  end

  # No param is the default (legacy) layout; anything else must name one of Scaffold.layouts/0.
  defp requested_layout(params) do
    case Map.fetch(params, Scaffold.layout_param()) do
      :error -> {:ok, Scaffold.default_layout()}
      {:ok, layout} -> if layout in Scaffold.layouts(), do: {:ok, layout}, else: :error
    end
  end

  defp unknown_layout(conn) do
    error(conn, :bad_request, "unknown_layout", "layout must be one of: #{Enum.join(Scaffold.layouts(), ", ")}")
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: code, message: message)
  end
end
