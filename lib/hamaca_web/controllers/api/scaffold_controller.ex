defmodule HamacaWeb.Api.ScaffoldController do
  @moduledoc """
  `GET /api/scaffold` and `GET /api/scaffold/*path` (RE304, ADR 0010) — the Hamaca-owned
  files a project installs with its runner's `update`.

  **One layout (RE482).** `?layout=hamaca` is the served layout (see `Hamaca.Scaffold`). A
  request with no `layout` param, or with `Hamaca.Scaffold.retired_layout/0` (`legacy`), can
  only come from a v≤93 `./relay` auto-updating: it gets a **410**
  `Hamaca.Scaffold.retired_code/0` (`runner_renamed`) whose message is the board's install
  one-liner (`Hamaca.Setup.install_command/2`), on both routes. Any other `layout` is a 400
  `unknown_layout`, never a silent fallback. The route is unauthenticated, so no board is
  known: the one-liner carries a `<your-board>` placeholder slug.

  **Unauthenticated on purpose**, on the same `:api` pipeline as `/api/version`: the board's
  install script fetches them before anything has authenticated, and these files were published
  openly regardless. The glob route serves **only** manifest entries (`Hamaca.Scaffold.fetch/2`
  checks a static allowlist), so it is not a general file server.

  The served runner (`Hamaca.Scaffold.runner_path/1`) has this board's URL baked into its
  `BOARD_URL` line (RE443), so a project needs no `HAMACA_URL`. The URL is
  `HamacaWeb.Endpoint.url/0` — the configured one, **never** the request's Host header, which
  the client controls and which would end up in executed code. The manifest is built with the
  same URL, so its runner `sha256` is the sha of exactly the bytes `show/2` serves and its
  `unbaked_sha256` is the placeholder copy's (what the runner compares).

  A 503 rather than a 500 when the scaffold has not been built: that is a dev box that skipped
  `mix setup`, not a bug in the request.
  """
  use HamacaWeb, :controller

  alias Hamaca.Scaffold
  alias Hamaca.Setup
  alias HamacaWeb.Api.ErrorJSON

  # The route is unauthenticated, so the refusal cannot name the caller's board.
  @placeholder_slug "<your-board>"

  def manifest(conn, params) do
    case requested_layout(params) do
      {:ok, layout} ->
        case Scaffold.manifest(layout: layout, board_url: HamacaWeb.Endpoint.url()) do
          {:ok, manifest} ->
            json(conn, manifest)

          :error ->
            error(conn, :service_unavailable, "scaffold_unavailable", "run `mix hamaca.build_scaffold`")
        end

      :retired ->
        runner_renamed(conn)

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

      :retired ->
        runner_renamed(conn)

      :error ->
        unknown_layout(conn)
    end
  end

  # No param, or the retired value, is a v≤93 ./relay (410); anything else must name one of
  # Scaffold.layouts/0.
  defp requested_layout(params) do
    retired = Scaffold.retired_layout()

    case Map.fetch(params, Scaffold.layout_param()) do
      :error -> :retired
      {:ok, ^retired} -> :retired
      {:ok, layout} -> if layout in Scaffold.layouts(), do: {:ok, layout}, else: :error
    end
  end

  defp runner_renamed(conn) do
    install = Setup.install_command(HamacaWeb.Endpoint.url(), @placeholder_slug)

    error(
      conn,
      :gone,
      Scaffold.retired_code(),
      "./relay is retired — in your checkout run #{install}, then ./hamaca start"
    )
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
