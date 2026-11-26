defmodule HamacaWeb.McpControllerTest do
  use HamacaWeb.ConnCase, async: true

  import Ecto.Query

  alias Hamaca.Accounts
  alias Hamaca.Cards
  alias Hamaca.Connections
  alias Hamaca.Repo
  alias HamacaWeb.Endpoint
  alias HamacaWeb.Mcp.Server
  alias HamacaWeb.Mcp.Tools.BoardStatus
  alias Schemas.OAuthGrant
  alias Schemas.OAuthToken

  @redirect_uri "https://claude.ai/api/mcp/auth_callback"

  # A real relaym_ token pair for `user`, minted through the Connections flow.
  defp connect!(user) do
    {:ok, client} = Connections.register_client(%{"client_name" => "claude.ai", "redirect_uris" => [@redirect_uri]})
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    {:ok, code} =
      Connections.authorize(user, client, %{redirect_uri: @redirect_uri, code_challenge: challenge, resource: nil})

    {:ok, tokens} =
      Connections.exchange_code(%{
        "code" => code,
        "redirect_uri" => @redirect_uri,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      })

    %{token: tokens.access_token, grant: Repo.get_by!(OAuthGrant, user_id: user.id, oauth_client_id: client.id)}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/mcp", Jason.encode!(body))
  end

  defp rpc(conn, method, params \\ %{}, id \\ 1) do
    post_json(conn, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  defp call_tool(conn, name, arguments \\ %{}) do
    result = conn |> rpc("tools/call", %{"name" => name, "arguments" => arguments}) |> json_response(200)
    assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}], "isError" => is_error}} = result
    {text, is_error}
  end

  defp member_board(user, name: name, key: key) do
    board = insert(:board, name: name, key: key, slug: unique_slug(String.downcase(name)))
    insert(:membership, board: board, user: user)
    board
  end

  defp ago(now, seconds), do: DateTime.add(now, -seconds, :second)

  defp board_url(board), do: "#{Endpoint.url()}/board/#{board.slug}"

  defp card_link(board, card) do
    ref = Cards.ref(board, card)
    "[#{ref}](#{board_url(board)}?card=#{ref})"
  end

  defp line_with(text, needle), do: text |> String.split("\n") |> Enum.find(&String.contains?(&1, needle))

  defp index_of(text, needle) do
    case :binary.match(text, needle) do
      {index, _} -> index
      :nomatch -> flunk("expected #{inspect(needle)} in:\n#{text}")
    end
  end

  setup %{conn: conn} do
    user = insert(:user)
    %{token: token, grant: grant} = connect!(user)
    %{conn: conn, authed: bearer(conn, token), user: user, token: token, grant: grant}
  end

  describe "authentication" do
    # Scenario 8
    test "no Authorization header is 401 with the resource metadata challenge", %{conn: conn} do
      conn = rpc(conn, "initialize")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer resource_metadata="#{Endpoint.url()}/.well-known/oauth-protected-resource")
             ]
    end

    # Scenario 9
    test "an expired token, a revoked grant's token and a relayu_ user token are 401 invalid_token", %{conn: conn} do
      expired_user = insert(:user)
      %{token: expired} = connect!(expired_user)
      [_sentinel, prefix, _secret] = String.split(expired, "_", parts: 3)
      past = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -60, :second)
      Repo.update_all(from(t in OAuthToken, where: t.token_prefix == ^prefix), set: [expires_at: past])

      revoked_user = insert(:user)
      %{token: revoked, grant: grant} = connect!(revoked_user)
      :ok = Connections.revoke_grant(revoked_user, grant.id)

      {:ok, %{token: user_token}} = Accounts.create_user_api_token(insert(:user))

      for token <- [expired, revoked, user_token] do
        conn = conn |> bearer(token) |> rpc("ping")

        assert json_response(conn, 401) == %{"error" => "unauthorized"}
        assert [challenge] = get_resp_header(conn, "www-authenticate")
        assert challenge =~ "resource_metadata="
        assert challenge =~ ~s(error="invalid_token")
      end
    end

    # Scenario 10
    test "a foreign Origin is 403", %{authed: authed} do
      conn = authed |> put_req_header("origin", "https://evil.example") |> rpc("ping")

      assert json_response(conn, 403) == %{"error" => "forbidden_origin"}
    end

    test "the server's own Origin is allowed", %{authed: authed} do
      conn = authed |> put_req_header("origin", Endpoint.url()) |> rpc("ping", %{}, 7)

      assert json_response(conn, 200) == %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
    end
  end

  describe "protocol" do
    # Scenario 11
    test "initialize echoes a supported protocol version", %{authed: authed} do
      result = authed |> rpc("initialize", %{"protocolVersion" => "2025-06-18"}) |> json_response(200)

      assert %{"protocolVersion" => "2025-06-18", "capabilities" => capabilities, "serverInfo" => info} =
               result["result"]

      assert capabilities == %{"tools" => %{}}
      assert info["name"] == "Hamaca"
      assert is_binary(info["version"])
    end

    test "initialize answers the newest version for an unsupported one", %{authed: authed} do
      result = authed |> rpc("initialize", %{"protocolVersion" => "1999-01-01"}) |> json_response(200)

      assert result["result"]["protocolVersion"] == hd(Server.protocol_versions())
    end

    # Scenario 12
    test "a notification is 202 with an empty body", %{authed: authed} do
      conn = post_json(authed, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    # Scenario 13
    test "tools/list lists exactly the four read tools", %{authed: authed} do
      tools = authed |> rpc("tools/list") |> json_response(200) |> get_in(["result", "tools"])

      assert Enum.map(tools, & &1["name"]) == ["list_boards", "board_status", "needs_me", "get_card"]

      for tool <- tools do
        assert is_binary(tool["description"]) and String.trim(tool["description"]) != ""
        assert tool["inputSchema"]["type"] == "object"
      end

      board_status = Enum.find(tools, &(&1["name"] == "board_status"))
      assert board_status["inputSchema"]["required"] == ["board"]
    end

    # Scenario 14
    test "an unknown method is -32601", %{authed: authed} do
      body = authed |> rpc("tools/approve") |> json_response(200)
      assert body["error"]["code"] == -32_601
    end

    test "an unknown tool is -32602", %{authed: authed} do
      body = authed |> rpc("tools/call", %{"name" => "approve_card", "arguments" => %{}}) |> json_response(200)
      assert body["error"]["code"] == -32_602
    end

    test "a batch array is an invalid request with HTTP 400", %{authed: authed} do
      body = authed |> post_json([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}]) |> json_response(400)

      assert body["error"]["code"] == -32_600
      assert body["id"] == nil
    end

    # Scenario 15
    test "GET /mcp is 405 allowing POST", %{authed: authed} do
      conn = get(authed, ~p"/mcp")

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    test "DELETE /mcp is 405 allowing POST", %{authed: authed} do
      conn = delete(authed, ~p"/mcp")

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end
  end

  describe "list_boards" do
    # Scenario 16
    test "one line per board with its waiting count and link", %{authed: authed, user: user} do
      relay = member_board(user, name: "Relay", key: "RE")
      stage = insert(:stage, board: relay, position: 1)
      insert(:card, stage: stage, status: :needs_input)
      docs = member_board(user, name: "Docs", key: "DO")

      {text, false} = call_tool(authed, "list_boards")

      assert line_with(text, "**Relay** (RE)") =~ "1 waiting on you"
      assert line_with(text, "**Docs** (DO)") =~ "0 waiting on you"
      assert text =~ board_url(relay)
      assert text =~ board_url(docs)
    end

    test "with no boards it says so", %{authed: authed} do
      assert {"You aren't a member of any Hamaca boards yet.", false} = call_tool(authed, "list_boards")
    end
  end

  describe "board_status" do
    # Scenario 17
    test "leads with the baton and links every card", %{authed: authed, user: user} do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      board = member_board(user, name: "Relay", key: "RBS")
      code = insert_ai_stage(board: board, name: "Code", position: 1)
      review = insert(:stage, board: board, name: "Review", type: :review, position: 2)
      done = insert(:stage, board: board, name: "Done", category: :complete, position: 3)

      a = insert(:card, stage: code, status: :needs_input, blocked_since: ago(now, 3 * 3600))
      b = insert(:card, stage: review, status: :in_review, updated_at: ago(now, 3600))
      c = insert(:card, stage: code, status: :working)
      insert(:card_owner, card: c)
      for done? <- [true, true, false], do: insert(:sub_task, card: c, done: done?)
      d = insert(:card, stage: code, status: :working)
      insert(:card_owner, card: d, user: user)
      e = insert(:card, stage: done, status: :ready, done_at: ago(now, 2 * 86_400))
      insert(:card, stage: done, status: :ready, done_at: ago(now, 10 * 86_400))

      {text, false} = call_tool(authed, "board_status", %{"board" => "relay"})

      assert hd(String.split(text, "\n")) ==
               "Relay has 2 cards waiting on you, 1 that agents are working on, and 1 shipped this week."

      assert index_of(text, "**Waiting on you (2)**") < index_of(text, "**Agents working (1)**")
      assert index_of(text, "**Agents working (1)**") < index_of(text, "**Shipped this week (1)**")

      for card <- [a, b, c, e], do: assert(text =~ card_link(board, card))

      assert line_with(text, card_link(board, c)) =~ "Code · 2/3 tasks"
      assert line_with(text, card_link(board, a)) =~ "1 question"
      assert line_with(text, card_link(board, b)) =~ "review"
      assert text |> String.trim_trailing() |> String.ends_with?("Board: #{board_url(board)}")
    end

    test "an empty section says nothing right now", %{authed: authed, user: user} do
      board = member_board(user, name: "Quiet", key: "QBS")
      insert(:stage, board: board, position: 1)

      {text, false} = call_tool(authed, "board_status", %{"board" => "quiet"})

      assert text =~ "**Waiting on you (0)**\n- Nothing right now."
    end

    # Scenario 18
    test "a section shows at most section_limit rows, then a link to the rest", %{authed: authed, user: user} do
      board = member_board(user, name: "Busy", key: "BBS")
      code = insert_ai_stage(board: board, name: "Code", position: 1)

      for _ <- 1..(BoardStatus.section_limit() + 2) do
        card = insert(:card, stage: code, status: :working)
        insert(:card_owner, card: card)
      end

      {text, false} = call_tool(authed, "board_status", %{"board" => "busy"})

      [_, working] = String.split(text, "**Agents working (#{BoardStatus.section_limit() + 2})**\n", parts: 2)
      [working | _] = String.split(working, "\n\n", parts: 2)
      rows = String.split(working, "\n")

      assert length(rows) == BoardStatus.section_limit() + 1
      assert List.last(rows) == "- …and 2 more: #{board_url(board)}"
    end

    # Scenario 19
    test "an ambiguous board asks which one", %{authed: authed, user: user} do
      member_board(user, name: "Hamaca Mobile", key: "HM")
      member_board(user, name: "Mobile Brief", key: "MB")

      assert {"Two boards match 'mobile': Hamaca Mobile (HM) and Mobile Brief (MB). Which one?", true} =
               call_tool(authed, "board_status", %{"board" => "mobile"})
    end

    test "a foreign board is not found and lists only the user's boards", %{authed: authed, user: user} do
      member_board(user, name: "Relay", key: "RE")
      insert(:board, name: "Secret", key: "SXQ", slug: unique_slug("secret"))

      {text, true} = call_tool(authed, "board_status", %{"board" => "Secret"})

      assert String.starts_with?(text, "No board matches 'Secret'. Your boards:")
      assert text =~ "Relay (RE)"
      refute text =~ "SXQ"
    end

    test "a missing board argument is an error", %{authed: authed} do
      {text, true} = call_tool(authed, "board_status", %{})
      assert text =~ "board is required"
    end
  end

  describe "needs_me" do
    # Scenario 20
    test "groups the feed by board, oldest first", %{authed: authed, user: user} do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      relay = member_board(user, name: "Relay", key: "RE")
      relay_stage = insert(:stage, board: relay, position: 1)
      a = insert(:card, stage: relay_stage, status: :needs_input, blocked_since: ago(now, 3 * 3600))
      b = insert(:card, stage: relay_stage, status: :in_review, updated_at: ago(now, 3600))
      docs = member_board(user, name: "Docs", key: "DO")
      docs_stage = insert(:stage, board: docs, position: 1)
      x = insert(:card, stage: docs_stage, status: :needs_input, blocked_since: ago(now, 5 * 3600))

      foreign = insert(:board, name: "Foreign", key: "FXQ", slug: unique_slug("foreign"))
      foreign_card = insert(:card, stage: insert(:stage, board: foreign), status: :needs_input)

      {text, false} = call_tool(authed, "needs_me")

      assert index_of(text, "**Docs (DO)**") < index_of(text, "**Relay (RE)**")
      assert index_of(text, card_link(relay, a)) < index_of(text, card_link(relay, b))
      assert line_with(text, card_link(relay, a)) =~ "3h ago"
      assert line_with(text, card_link(docs, x)) =~ "5h ago"
      refute text =~ Cards.ref(foreign, foreign_card)

      rows = text |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "- "))
      assert Enum.all?(rows, &(&1 =~ ~r/^- \[[A-Z]+\d+\]\(http.+\?card=[A-Z]+\d+\) .+ · .+ ago$/))

      refs = for [ref] <- Regex.scan(~r/^- \[([A-Z]+\d+)\]/m, text, capture: :all_but_first), do: ref
      feed_refs = for %{card: card} <- Cards.needs_you_feed(user), do: Cards.ref(card.board, card)
      assert Enum.sort(refs) == Enum.sort(feed_refs)
    end

    test "with nothing waiting it says so", %{authed: authed} do
      assert {"Nothing is waiting on you right now.", false} = call_tool(authed, "needs_me")
    end
  end

  describe "get_card" do
    # Scenario 21
    test "the card's header, spec excerpt and 10 newest timeline entries", %{authed: authed, user: user} do
      board = member_board(user, name: "Relay", key: "RGC")
      stage = insert_ai_stage(board: board, name: "Code", position: 1)
      card = insert(:card, stage: stage, title: "Ship it", status: :working, spec: "## The spec\nDo the thing.")
      insert(:card_owner, card: card)

      base = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -3600, :second)

      for i <- 1..6 do
        insert(:comment, card: card, user: user, body: "comment #{i}", inserted_at: DateTime.add(base, i * 60, :second))

        insert(:activity,
          card: card,
          type: :moved,
          text: "moved #{i}",
          inserted_at: DateTime.add(base, i * 60 + 30, :second)
        )
      end

      ref = Cards.ref(board, card)
      {text, false} = call_tool(authed, "get_card", %{"ref" => ref})

      assert text =~ "**#{ref} · Ship it** — Relay (RGC)"
      assert text =~ "Baton: #{Hamaca.Brand.agent_name()}"
      assert text =~ "Link: #{board_url(board)}?card=#{ref}"
      assert text =~ "**Spec (excerpt)**"

      [_, activity] = String.split(text, "**Recent activity**\n", parts: 2)
      lines = activity |> String.trim_trailing() |> String.split("\n")
      assert length(lines) == 10
      assert Enum.all?(lines, &String.starts_with?(&1, "- "))
      # The two oldest entries fell off; the newest is last.
      refute activity =~ "comment 1"
      assert List.last(lines) =~ "moved 6"
    end

    test "a foreign card is not found", %{authed: authed} do
      foreign = insert(:board, name: "Foreign", key: "FGC", slug: unique_slug("foreign"))
      card = insert(:card, stage: insert(:stage, board: foreign))
      ref = Cards.ref(foreign, card)

      assert {"No card #{ref} on your boards.", true} == call_tool(authed, "get_card", %{"ref" => ref})
    end

    # Scenario 22
    test "a ref on two boards sharing a key asks for board", %{authed: authed, user: user} do
      one = member_board(user, name: "Relay One", key: "RLY")
      two = member_board(user, name: "Relay Two", key: "RLY")
      insert(:card, stage: insert(:stage, board: one), ref_number: 1, title: "On one")
      insert(:card, stage: insert(:stage, board: two), ref_number: 1, title: "On two")

      {text, true} = call_tool(authed, "get_card", %{"ref" => "RLY1"})

      assert text =~ "Relay One (RLY)"
      assert text =~ "Relay Two (RLY)"
      assert text =~ "board"

      {text, false} = call_tool(authed, "get_card", %{"ref" => "RLY1", "board" => two.slug})
      assert text =~ "**RLY1 · On two** — Relay Two (RLY)"
    end
  end
end
