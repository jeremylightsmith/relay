defmodule HamacaWeb.Plugs.Embed do
  @moduledoc """
  Resolves whether this request is served **embedded** inside the native app's
  webview and promotes the answer into the Phoenix session, where it survives the
  websocket handshake and every `<.link navigate>` for free. LiveView `on_mount`
  receives only the signed session — never arbitrary cookies — which is why the
  raw cookie is promoted here, on the HTTP dead render.

  Precedence:

    1. `?embed=1`/`true` or `?embed=0`/`false` — the dev/desktop override. When the
       `embed` param is present its value is written to the session so it persists
       across subsequent navigation (use `?embed=0` to leave embedded mode in a
       plain browser).
    2. Else a truthy `relay_embed` cookie (`"1"`/`"true"`), set by the native webview
       in its own cookie store. The cookie never *clears* the flag.
    3. Else the session is left as-is (an already-promoted value, or absent).

  Also assigns `conn.assigns.embed` (a boolean) for controller-rendered surfaces.
  Sits in the `:browser` pipeline right after `:fetch_session`.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = conn |> fetch_query_params() |> fetch_cookies()

    conn =
      case override(conn.query_params["embed"]) do
        :unset -> maybe_from_cookie(conn)
        value -> put_session(conn, :embed, value)
      end

    assign(conn, :embed, get_session(conn, :embed) == true)
  end

  @doc """
  Whether `conn` comes from the native app's webview, by the same precedence as `call/2`
  (query param, then cookie, then an already-promoted session flag) — without writing
  anything. Safe to call before `:fetch_session`: it reads the session only when one is
  configured. `HamacaWeb.Plugs.CanonicalHost` uses it to keep the app on its own host.
  """
  def embedded?(conn) do
    conn = conn |> fetch_query_params() |> fetch_cookies()

    case override(conn.query_params["embed"]) do
      :unset -> cookie_embed?(conn) or session_embed?(conn)
      value -> value
    end
  end

  defp session_embed?(%{private: %{plug_session_fetch: _}} = conn),
    do: conn |> fetch_session() |> get_session(:embed) == true

  defp session_embed?(%{private: %{plug_session: session}}), do: session["embed"] == true
  defp session_embed?(_conn), do: false

  defp override(value) when value in ["1", "true"], do: true
  defp override(value) when value in ["0", "false"], do: false
  defp override(_value), do: :unset

  defp maybe_from_cookie(conn) do
    if cookie_embed?(conn), do: put_session(conn, :embed, true), else: conn
  end

  defp cookie_embed?(conn), do: override(conn.cookies["relay_embed"]) == true
end
