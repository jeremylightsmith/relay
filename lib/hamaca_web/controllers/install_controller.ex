defmodule HamacaWeb.InstallController do
  @moduledoc """
  `GET /b/:slug/install` (RE443) — the public install script, `curl -fsSL <host>/b/<slug>/install | sh`.

  Unauthenticated: the script itself carries no secret (it reads `RELAY_API_KEY` from the shell
  that runs it), and it is served for any slug in the board slug format whether or not such a
  board exists, so the route says nothing about which boards do. Anything else is a plain 404.
  The script bakes `HamacaWeb.Endpoint.url/0`, never `conn.host`: the output is piped into `sh`.
  """
  use HamacaWeb, :controller

  alias HamacaWeb.InstallScript

  # The body is text/plain and holds only the configured URL and a slug already matched against
  # the board slug format, so there is no HTML context for a script to run in.
  # sobelow_skip ["XSS.SendResp"]
  def show(conn, %{"slug" => slug}) do
    conn = put_resp_content_type(conn, "text/plain")

    if Regex.match?(Schemas.Board.slug_format(), slug),
      do: send_resp(conn, 200, InstallScript.render(HamacaWeb.Endpoint.url(), slug)),
      else: send_resp(conn, 404, "Not found\n")
  end
end
