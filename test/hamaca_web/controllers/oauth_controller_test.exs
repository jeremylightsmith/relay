defmodule HamacaWeb.OAuthControllerTest do
  use HamacaWeb.ConnCase, async: true

  import Hamaca.Factory

  alias Hamaca.Connections
  alias HamacaWeb.ContentSecurityPolicy

  @redirect_uri "https://claude.ai/api/mcp/auth_callback"

  setup do
    {:ok, client} = Connections.register_client(%{"client_name" => "claude.ai", "redirect_uris" => [@redirect_uri]})
    %{client: client}
  end

  # A real RFC 7636 S256 pair: a 43+ char unreserved verifier and its base64url SHA-256.
  defp pkce_pair do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp authorize_params(client, overrides \\ %{}) do
    {_verifier, challenge} = pkce_pair()

    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.client_id,
        "redirect_uri" => @redirect_uri,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "xyz"
      },
      overrides
    )
  end

  defp authorize_query(client, overrides \\ %{}), do: URI.encode_query(authorize_params(client, overrides))

  defp decide_params(client, decision, overrides \\ %{}) do
    client
    |> authorize_params(overrides)
    |> Map.delete("response_type")
    |> Map.put("decision", decision)
  end

  defp document(conn), do: conn |> html_response(200) |> LazyHTML.from_document()

  defp text(document, selector), do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp directives(policy) do
    policy
    |> String.split(";", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp location_params(conn) do
    conn |> redirected_to(302) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end

  defp post_form(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(params))
  end

  defp post_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(params))
  end

  defp allow_code(conn, client, challenge) do
    conn
    |> post(~p"/oauth/authorize", decide_params(client, "allow", %{"code_challenge" => challenge}))
    |> location_params()
    |> Map.fetch!("code")
  end

  defp tokens_for(client, user) do
    {verifier, challenge} = pkce_pair()
    code = build_conn() |> log_in_user(user) |> allow_code(client, challenge)

    build_conn()
    |> post_form(~p"/oauth/token", %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => @redirect_uri,
      "client_id" => client.client_id,
      "code_verifier" => verifier
    })
    |> json_response(200)
  end

  describe "POST /oauth/register" do
    test "registers a public client and returns 201 (scenario 3)", %{conn: conn} do
      body =
        conn
        |> post_json(~p"/oauth/register", %{
          "client_name" => "claude.ai",
          "redirect_uris" => [@redirect_uri]
        })
        |> json_response(201)

      assert is_binary(body["client_id"]) and String.trim(body["client_id"]) != ""
      assert body["client_name"] == "claude.ai"
      assert body["redirect_uris"] == [@redirect_uri]
      assert body["token_endpoint_auth_method"] == "none"
      assert body["grant_types"] == ["authorization_code", "refresh_token"]
      assert body["response_types"] == ["code"]
      assert is_integer(body["client_id_issued_at"])
      assert Connections.get_client(body["client_id"])
    end

    test "a non-https redirect URI is 400 invalid_redirect_uri (scenario 4)", %{conn: conn} do
      body =
        conn
        |> post_json(~p"/oauth/register", %{"redirect_uris" => ["http://evil.example/cb"]})
        |> json_response(400)

      assert body["error"] == "invalid_redirect_uri"
      assert is_binary(body["error_description"]) and body["error_description"] != ""
    end

    test "missing redirect_uris is 400 invalid_client_metadata (scenario 4)", %{conn: conn} do
      body = conn |> post_json(~p"/oauth/register", %{"client_name" => "x"}) |> json_response(400)

      assert body["error"] == "invalid_client_metadata"
      assert is_binary(body["error_description"]) and body["error_description"] != ""
    end
  end

  describe "GET /oauth/authorize — consent page" do
    setup %{conn: conn} do
      user = insert(:user, name: "Ada Lovelace", provider: "google")

      for _ <- 1..7, do: insert(:membership, board: insert(:board), user: user, email: user.email)

      archived = insert(:board, archived_at: DateTime.truncate(DateTime.utc_now(), :second))
      insert(:membership, board: archived, user: user, email: user.email)

      %{conn: log_in_user(conn, user), user: user}
    end

    test "renders the consent screen for the client and the user's 7 live boards (scenario 5)", %{
      conn: conn,
      client: client
    } do
      conn = get(conn, "/oauth/authorize?" <> authorize_query(client))
      html = html_response(conn, 200)
      doc = LazyHTML.from_document(html)

      assert html =~ "Connect Claude to Hamaca?"
      assert text(doc, "#consent-client-name") == "claude.ai"

      items = LazyHTML.query(doc, "#consent-capabilities li")
      assert Enum.count(items) == 1
      assert items |> LazyHTML.text() |> squish() =~ "Read all 7 of your boards"

      assert text(doc, "#consent-cannot") =~ "approve, reject, answer questions or move cards"
      assert doc |> LazyHTML.query("#consent-allow") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#consent-cancel") |> Enum.count() == 1

      refute html =~ "via Claude"
      refute html =~ "Connections"
    end

    test "widens form-action to the redirect URI's origin and Google sign-in, nothing else (scenario 6)",
         %{conn: conn, client: client} do
      conn = get(conn, "/oauth/authorize?" <> authorize_query(client))
      assert html_response(conn, 200)

      # "Not you?" and an expired-session Allow/Cancel submit a form whose redirect chain ends
      # at Google sign-in; browsers enforce form-action on every hop.
      [policy] = get_resp_header(conn, "content-security-policy")
      form_action = Enum.find(directives(policy), &String.starts_with?(&1, "form-action"))
      assert form_action == "form-action 'self' https://claude.ai https://accounts.google.com"
      assert ContentSecurityPolicy.google_sign_in_origin() == "https://accounts.google.com"

      not_form_action = &Enum.reject(directives(&1), fn d -> String.starts_with?(d, "form-action") end)
      assert not_form_action.(policy) == not_form_action.(ContentSecurityPolicy.header())
    end

    test "shows the signed-in account and a Not-you sign-out back to this page (scenario 7)", %{
      conn: conn,
      client: client
    } do
      doc = conn |> get("/oauth/authorize?" <> authorize_query(client)) |> document()

      account = text(doc, "#consent-account")
      assert account =~ "Ada Lovelace"
      assert account =~ "Signed in with Google"

      not_you = LazyHTML.query(doc, "#consent-not-you")
      assert LazyHTML.attribute(not_you, "data-method") == ["delete"]
      assert [href] = LazyHTML.attribute(not_you, "href")
      assert String.starts_with?(href, "/logout?return_to=%2Foauth%2Fauthorize")
    end

    test "a client registered without a name shows \"An application\" (scenario 8)", %{conn: conn} do
      {:ok, nameless} = Connections.register_client(%{"redirect_uris" => [@redirect_uri]})

      doc = conn |> get("/oauth/authorize?" <> authorize_query(nameless)) |> document()

      assert text(doc, "#consent-client-name") == "An application"
    end

    test "a hostile client name renders as escaped text (scenario 8)", %{conn: conn} do
      {:ok, hostile} =
        Connections.register_client(%{"client_name" => "<script>x</script>", "redirect_uris" => [@redirect_uri]})

      conn = get(conn, "/oauth/authorize?" <> authorize_query(hostile))
      html = html_response(conn, 200)

      refute html =~ "<script>x"
      assert html =~ "&lt;script&gt;x&lt;/script&gt;"
      assert text(LazyHTML.from_document(html), "#consent-client-name") == "<script>x</script>"
    end

    test "the form posts the decision and the authorize request as hidden fields", %{conn: conn, client: client} do
      params = authorize_params(client, %{"resource" => HamacaWeb.OAuthMetadata.resource_url()})
      doc = conn |> get("/oauth/authorize?" <> URI.encode_query(params)) |> document()

      form = LazyHTML.query(doc, "form#consent-form")
      assert LazyHTML.attribute(form, "method") == ["post"]
      assert LazyHTML.attribute(form, "action") == ["/oauth/authorize"]

      for field <- ~w(client_id redirect_uri code_challenge code_challenge_method state resource) do
        assert form |> LazyHTML.query(~s(input[type="hidden"][name="#{field}"])) |> LazyHTML.attribute("value") ==
                 [params[field]]
      end

      assert doc |> LazyHTML.query(~s(button#consent-allow[name="decision"])) |> LazyHTML.attribute("value") ==
               ["allow"]

      assert doc |> LazyHTML.query(~s(button#consent-cancel[name="decision"])) |> LazyHTML.attribute("value") ==
               ["cancel"]
    end

    test "matches the mockup's layout classes (card mockup \"Consent — OAuth allow screen\")", %{
      conn: conn,
      client: client
    } do
      doc = conn |> get("/oauth/authorize?" <> authorize_query(client)) |> document()

      classes = fn selector ->
        doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> Enum.join(" ") |> String.split()
      end

      assert ~w(flex flex-col items-center justify-center px-4 py-10) -- classes.("main#oauth-consent") == []

      assert ~w(card w-full max-w-md border border-base-300 bg-base-100 p-6) --
               classes.("#oauth-consent section.card") == []

      assert doc
             |> LazyHTML.query(~s(#oauth-consent img[src="/images/logo_transparent_128.png"][width="36"][alt="Hamaca"]))
             |> Enum.count() == 1

      assert ~w(size-9 rounded-xl bg-secondary/15 text-secondary) -- classes.("#consent-ai-mark") == []
      assert ~w(text-center text-xl font-semibold tracking-tight) -- classes.("#oauth-consent h1") == []
      assert ~w(mt-5 flex items-center gap-3 rounded-box bg-base-200 p-3) -- classes.("#consent-account") == []
      assert ~w(link text-xs text-base-content/65) -- classes.("#consent-not-you") == []
      assert ~w(mt-2 space-y-2.5 text-sm) -- classes.("#consent-capabilities") == []

      assert ~w(mt-3 flex items-start gap-2.5 rounded-box border border-base-300 p-3 text-xs text-base-content/65) --
               classes.("#consent-cannot") == []

      assert ~w(btn btn-ghost flex-1) -- classes.("#consent-cancel") == []
      assert ~w(btn btn-primary flex-1) -- classes.("#consent-allow") == []
      assert text(doc, "#oauth-consent") =~ "CLAUDE WILL BE ABLE TO"
      assert text(doc, "#consent-cannot .font-medium") == "can't"

      avatar_style = doc |> LazyHTML.query("#consent-account [data-avatar]") |> LazyHTML.attribute("style")
      assert [style] = avatar_style
      assert style =~ "width:32px"
    end
  end

  describe "GET /oauth/authorize — signed out" do
    test "redirects to Google sign-in carrying the full authorize URL as return_to (scenario 9)", %{
      conn: conn,
      client: client
    } do
      query = authorize_query(client)
      conn = get(conn, "/oauth/authorize?" <> query)

      assert redirected_to(conn, 302) == "/auth/google?return_to=" <> URI.encode_www_form("/oauth/authorize?" <> query)
    end

    test "signing in with that return_to lands back on the consent page (scenario 10)", %{conn: conn, client: client} do
      query = authorize_query(client)
      return_to = "/oauth/authorize?" <> query
      assert redirected_to(get(conn, return_to), 302) =~ "return_to="

      signed_in = get(build_conn(), "/dev/login?" <> URI.encode_query(%{"return_to" => return_to}))
      assert redirected_to(signed_in, 302) == return_to

      doc = signed_in |> recycle() |> get(return_to) |> document()
      assert text(doc, "#consent-client-name") == "claude.ai"
    end
  end

  describe "GET /oauth/authorize — invalid requests" do
    setup :register_and_log_in_user

    test "an unknown client_id is 400 HTML and never redirects (scenario 11)", %{conn: conn, client: client} do
      conn = get(conn, "/oauth/authorize?" <> authorize_query(client, %{"client_id" => "nope"}))

      assert html_response(conn, 400)
      assert get_resp_header(conn, "location") == []
    end

    test "an unregistered redirect_uri is 400 HTML and never redirects (scenario 11)", %{conn: conn, client: client} do
      conn =
        get(conn, "/oauth/authorize?" <> authorize_query(client, %{"redirect_uri" => "https://attacker.example/cb"}))

      assert html_response(conn, 400)
      assert get_resp_header(conn, "location") == []
    end

    test "code_challenge_method=plain redirects back with invalid_request (scenario 12)", %{conn: conn, client: client} do
      conn = get(conn, "/oauth/authorize?" <> authorize_query(client, %{"code_challenge_method" => "plain"}))

      assert redirected_to(conn, 302) == @redirect_uri <> "?error=invalid_request&state=xyz"
    end

    test "response_type=token redirects back with unsupported_response_type (scenario 12)", %{
      conn: conn,
      client: client
    } do
      conn = get(conn, "/oauth/authorize?" <> authorize_query(client, %{"response_type" => "token"}))

      assert redirected_to(conn, 302) == @redirect_uri <> "?error=unsupported_response_type&state=xyz"
    end

    test "a foreign resource redirects back with invalid_request (scenario 12)", %{conn: conn, client: client} do
      conn = get(conn, "/oauth/authorize?" <> authorize_query(client, %{"resource" => "https://other/mcp"}))

      assert redirected_to(conn, 302) == @redirect_uri <> "?error=invalid_request&state=xyz"
    end

    test "a missing code_challenge redirects back with invalid_request", %{conn: conn, client: client} do
      params = client |> authorize_params() |> Map.delete("code_challenge")
      conn = get(conn, "/oauth/authorize?" <> URI.encode_query(params))

      assert redirected_to(conn, 302) == @redirect_uri <> "?error=invalid_request&state=xyz"
    end
  end

  describe "POST /oauth/authorize" do
    setup :register_and_log_in_user

    test "Cancel redirects back with access_denied (scenario 13)", %{conn: conn, client: client} do
      conn = post(conn, ~p"/oauth/authorize", decide_params(client, "cancel"))

      assert redirected_to(conn, 302) == @redirect_uri <> "?error=access_denied&state=xyz"
    end

    test "Allow issues a code that exchanges once for relaym_ tokens (scenario 14)", %{
      conn: conn,
      client: client
    } do
      {verifier, challenge} = pkce_pair()
      conn = post(conn, ~p"/oauth/authorize", decide_params(client, "allow", %{"code_challenge" => challenge}))

      assert String.starts_with?(redirected_to(conn, 302), @redirect_uri <> "?code=")
      assert %{"code" => code, "state" => "xyz"} = location_params(conn)

      exchange = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => @redirect_uri,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      }

      token_conn = post_form(build_conn(), ~p"/oauth/token", exchange)
      body = json_response(token_conn, 200)

      assert body["token_type"] == "Bearer"
      assert body["expires_in"] == Connections.access_token_ttl_seconds()
      assert String.starts_with?(body["access_token"], Connections.token_sentinel() <> "_")
      assert String.starts_with?(body["refresh_token"], Connections.token_sentinel() <> "_")
      assert String.starts_with?(body["access_token"], "relaym_")
      assert get_resp_header(token_conn, "cache-control") == ["no-store"]

      replay = post_form(build_conn(), ~p"/oauth/token", exchange)
      assert json_response(replay, 400)["error"] == "invalid_grant"
      assert get_resp_header(replay, "cache-control") == ["no-store"]
    end

    test "Allow appends with & when the redirect URI already has a query (scenario 15)", %{conn: conn} do
      redirect_uri = "https://app.example/cb?x=1"
      {:ok, client} = Connections.register_client(%{"client_name" => "App", "redirect_uris" => [redirect_uri]})

      conn = post(conn, ~p"/oauth/authorize", decide_params(client, "allow", %{"redirect_uri" => redirect_uri}))

      location = redirected_to(conn, 302)
      assert location =~ ~r{\Ahttps://app\.example/cb\?x=1&code=[^&]+&state=xyz\z}
    end

    test "a tampered redirect_uri is 400 HTML and never redirects (scenario 18)", %{conn: conn, client: client} do
      conn =
        post(
          conn,
          ~p"/oauth/authorize",
          decide_params(client, "allow", %{"redirect_uri" => "https://attacker.example/cb"})
        )

      assert html_response(conn, 400)
      assert get_resp_header(conn, "location") == []
    end

    test "a bad code_challenge_method redirects back with invalid_request", %{conn: conn, client: client} do
      conn = post(conn, ~p"/oauth/authorize", decide_params(client, "allow", %{"code_challenge_method" => "plain"}))

      assert redirected_to(conn, 302) == @redirect_uri <> "?error=invalid_request&state=xyz"
    end

    test "signed out, it sends the user to sign in instead of issuing a code", %{client: client} do
      conn = post(build_conn(), ~p"/oauth/authorize", decide_params(client, "allow"))

      assert redirected_to(conn, 302) =~ ~r{\A/auth/google\?return_to=%2Foauth%2Fauthorize%3F}
    end
  end

  describe "POST /oauth/token" do
    test "a JSON refresh_token grant rotates the refresh token (scenario 16)", %{client: client} do
      tokens = tokens_for(client, insert(:user))

      refresh = %{
        "grant_type" => "refresh_token",
        "refresh_token" => tokens["refresh_token"],
        "client_id" => client.client_id
      }

      conn = post_json(build_conn(), ~p"/oauth/token", refresh)
      body = json_response(conn, 200)

      assert String.starts_with?(body["refresh_token"], "relaym_")
      assert body["refresh_token"] != tokens["refresh_token"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert build_conn() |> post_json(~p"/oauth/token", refresh) |> json_response(400) |> Map.fetch!("error") ==
               "invalid_grant"
    end

    test "an unknown grant_type is 400 unsupported_grant_type (scenario 17)", %{conn: conn} do
      conn = post_form(conn, ~p"/oauth/token", %{"grant_type" => "password"})

      assert json_response(conn, 400)["error"] == "unsupported_grant_type"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "an unknown client is 401 invalid_client (scenario 17)", %{conn: conn} do
      conn =
        post_form(conn, ~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => "abc",
          "redirect_uri" => @redirect_uri,
          "client_id" => "nope",
          "code_verifier" => String.duplicate("a", 43)
        })

      assert json_response(conn, 401)["error"] == "invalid_client"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a missing code is 400 invalid_request (scenario 17)", %{conn: conn, client: client} do
      conn =
        post_form(conn, ~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "redirect_uri" => @redirect_uri,
          "client_id" => client.client_id,
          "code_verifier" => String.duplicate("a", 43)
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert is_binary(body["error_description"])
    end
  end
end
