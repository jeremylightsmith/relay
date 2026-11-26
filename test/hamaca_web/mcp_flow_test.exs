defmodule HamacaWeb.McpFlowTest do
  use HamacaWeb.ConnCase, async: true

  # RE519 end to end: what claude.ai does when a user adds Hamaca as a custom connector —
  # register, consent, token, then MCP calls with the bearer.

  @redirect_uri "https://claude.ai/api/mcp/auth_callback"

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp post_form(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(params))
  end

  test "register → consent → token → initialize → board_status" do
    user = insert(:user)
    board = insert(:board, name: "Relay", key: "RFL", slug: unique_slug("relay"))
    insert(:membership, board: board, user: user)
    insert(:card, stage: insert(:stage, board: board, position: 1), status: :needs_input)

    # 1. Dynamic client registration.
    client_id =
      build_conn()
      |> post_json(~p"/oauth/register", %{"client_name" => "claude.ai", "redirect_uris" => [@redirect_uri]})
      |> json_response(201)
      |> Map.fetch!("client_id")

    # 2. The signed-in user sees the consent page.
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    authorize = %{
      "client_id" => client_id,
      "redirect_uri" => @redirect_uri,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "flow"
    }

    browser = log_in_user(build_conn(), user)
    query = URI.encode_query(Map.put(authorize, "response_type", "code"))
    assert browser |> get("/oauth/authorize?" <> query) |> html_response(200)

    # 3. Allow → the code comes back on the redirect.
    location = browser |> post(~p"/oauth/authorize", Map.put(authorize, "decision", "allow")) |> redirected_to(302)
    assert %{"code" => code, "state" => "flow"} = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    # 4. Exchange the code with the real verifier.
    exchange = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => @redirect_uri,
      "client_id" => client_id,
      "code_verifier" => verifier
    }

    access_token =
      build_conn() |> post_form(~p"/oauth/token", exchange) |> json_response(200) |> Map.fetch!("access_token")

    # 5. MCP with the bearer.
    mcp = put_req_header(build_conn(), "authorization", "Bearer " <> access_token)

    init =
      mcp
      |> post_json(~p"/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-06-18"}
      })
      |> json_response(200)

    assert init["result"]["serverInfo"]["name"] == "Hamaca"

    reply =
      mcp
      |> post_json(~p"/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "board_status", "arguments" => %{"board" => "Relay"}}
      })
      |> json_response(200)

    assert %{"content" => [%{"text" => text}], "isError" => false} = reply["result"]
    assert String.starts_with?(text, "Relay has 1 card waiting on you")

    # A code is single use.
    replay = post_form(build_conn(), ~p"/oauth/token", exchange)
    assert json_response(replay, 400)["error"] == "invalid_grant"
  end
end
