defmodule HamacaWeb.Plugs.CanonicalHost do
  @moduledoc """
  Sends browser pages requested on a secondary hostname to the canonical one (RE480).

  A request is answered `301` to `HamacaWeb.Endpoint.url/0` plus the same path and query only
  when all of these hold:

    * its host (case-insensitive) is in `:hamaca, :extra_hosts` — the `PHX_EXTRA_HOSTS` list
      parsed once in `config/runtime.exs` (default `[]`, so the plug is a no-op unless set);
    * it is a `GET` (`Plug.Head` already turned `HEAD` into `GET`) — a 301 would turn a POST
      into a GET and drop its body;
    * its first path segment is not in `@pass_through`: `/auth/*` must finish on the host the
      OAuth dance started on (the provider's callback and the session cookie live there), and
      `/attachments/*` links are embedded in card markdown and should keep loading where they
      are;
    * it is not from the native app's webview (`HamacaWeb.Plugs.Embed.embedded?/1`): the
      shipped app loads its LiveViews from the host it signed in on, where its session
      cookie lives, so a redirect would land it signed out.

  Everything else is returned untouched. Sits **first** in the `:browser` pipeline, before
  `:fetch_session` and `Embed`, so a redirect never sets a cookie on the old host; being in
  `:browser` keeps the API, install scripts, webhooks and the LiveView socket out by
  construction. The host list is read on every call through `Hamaca.Config` (not in `init/1`,
  which runs at compile time for router plugs), so runtime config applies and a test can
  `Process.put(:extra_hosts, …)` its own list.
  """
  import Plug.Conn

  @pass_through ~w(auth attachments)

  def init(opts), do: opts

  def call(conn, _opts) do
    if redirect?(conn), do: redirect(conn), else: conn
  end

  defp redirect?(conn) do
    conn.method == "GET" and
      String.downcase(conn.host) in Hamaca.Config.get(:extra_hosts, []) and
      List.first(conn.path_info) not in @pass_through and
      not HamacaWeb.Plugs.Embed.embedded?(conn)
  end

  defp redirect(conn) do
    conn
    |> put_resp_header("location", HamacaWeb.Endpoint.url() <> conn.request_path <> query_suffix(conn))
    |> send_resp(301, "")
    |> halt()
  end

  defp query_suffix(%{query_string: ""}), do: ""
  defp query_suffix(%{query_string: query}), do: "?" <> query
end
