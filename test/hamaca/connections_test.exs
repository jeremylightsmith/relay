defmodule Hamaca.ConnectionsTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Accounts
  alias Hamaca.Connections
  alias HamacaWeb.TokenHelpers
  alias Schemas.OAuthClient
  alias Schemas.OAuthCode
  alias Schemas.OAuthGrant
  alias Schemas.OAuthToken
  alias Schemas.User

  @redirect_uri "https://claude.ai/api/mcp/auth_callback"

  defp pkce_pair do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    {verifier, challenge}
  end

  defp register!(redirect_uris \\ [@redirect_uri]) do
    {:ok, client} = Connections.register_client(%{"client_name" => "claude.ai", "redirect_uris" => redirect_uris})
    client
  end

  # Authorizes `user` for `client` and returns the raw code plus the params to exchange it.
  defp authorize!(user, client, opts \\ []) do
    {verifier, challenge} = pkce_pair()
    resource = Keyword.get(opts, :resource)

    {:ok, code} =
      Connections.authorize(user, client, %{redirect_uri: @redirect_uri, code_challenge: challenge, resource: resource})

    %{
      "code" => code,
      "redirect_uri" => @redirect_uri,
      "client_id" => client.client_id,
      "code_verifier" => verifier
    }
  end

  defp connect!(user \\ nil) do
    user = user || insert(:user)
    client = register!()
    params = authorize!(user, client)
    {:ok, tokens} = Connections.exchange_code(params)
    %{user: user, client: client, tokens: tokens, grant: grant_for(user, client)}
  end

  defp grant_for(user, client), do: Repo.get_by!(OAuthGrant, user_id: user.id, oauth_client_id: client.id)

  defp code_row(raw_code) do
    Repo.get_by!(OAuthCode, code_hash: Base.encode16(:crypto.hash(:sha256, raw_code), case: :lower))
  end

  describe "register_client/1" do
    # Scenario 1
    test "registers a client and get_client/1 finds it" do
      assert {:ok,
              %OAuthClient{
                client_name: "claude.ai",
                redirect_uris: ["https://claude.ai/api/mcp/auth_callback"],
                client_id: client_id
              } = client} =
               Connections.register_client(%{
                 "client_name" => "claude.ai",
                 "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]
               })

      assert is_binary(client_id) and String.trim(client_id) != ""
      assert Connections.get_client(client_id).id == client.id
    end

    test "get_client/1 returns nil for an unknown client_id" do
      assert Connections.get_client("nope") == nil
    end

    # Scenario 2
    test "accepts loopback http redirect URIs" do
      assert {:ok, _} = Connections.register_client(%{"redirect_uris" => ["http://localhost:6274/callback"]})
      assert {:ok, _} = Connections.register_client(%{"redirect_uris" => ["http://127.0.0.1/cb"]})
    end

    # Scenario 3
    test "rejects a non-loopback http, a javascript: and a fragment-carrying redirect URI" do
      for uri <- ["http://evil.example/cb", "javascript:alert(1)", "https://claude.ai/cb#frag"] do
        assert {:error, :invalid_redirect_uri} = Connections.register_client(%{"redirect_uris" => [uri]}),
               "expected #{uri} to be rejected"
      end
    end

    test "rejects a redirect URI longer than the cap" do
      %{max_redirect_uri_length: max} = Connections.registration_limits()
      long = "https://claude.ai/" <> String.duplicate("a", max)

      assert {:error, :invalid_redirect_uri} = Connections.register_client(%{"redirect_uris" => [long]})
    end

    test "a redirect URI of exactly the cap registers and completes the code flow" do
      %{max_redirect_uri_length: max} = Connections.registration_limits()
      prefix = "https://claude.ai/"
      uri = prefix <> String.duplicate("a", max - byte_size(prefix))
      assert byte_size(uri) == max

      assert {:ok, client} = Connections.register_client(%{"redirect_uris" => [uri]})
      assert Connections.redirect_uri_registered?(client, uri)

      user = insert(:user)
      {verifier, challenge} = pkce_pair()
      {:ok, code} = Connections.authorize(user, client, %{redirect_uri: uri, code_challenge: challenge, resource: nil})

      assert {:ok, %{access_token: "relaym_" <> _}} =
               Connections.exchange_code(%{
                 "code" => code,
                 "redirect_uri" => uri,
                 "client_id" => client.client_id,
                 "code_verifier" => verifier
               })
    end

    test "a client name within the grapheme cap registers even when it spans more codepoints" do
      %{max_client_name_length: max} = Connections.registration_limits()
      # "e" + U+0301 COMBINING ACUTE ACCENT: one grapheme, two codepoints, three bytes.
      name = String.duplicate("é", max)
      assert String.length(name) == max
      assert length(String.codepoints(name)) > 255

      assert {:ok, %OAuthClient{client_name: ^name}} =
               Connections.register_client(%{"client_name" => name, "redirect_uris" => [@redirect_uri]})
    end

    # Scenario 4
    test "rejects missing, empty, oversized and badly-named metadata" do
      %{max_redirect_uris: max_uris, max_client_name_length: max_name} = Connections.registration_limits()
      too_many = for i <- 0..max_uris, do: "https://claude.ai/cb/#{i}"

      for params <- [
            %{"client_name" => "claude.ai"},
            %{"redirect_uris" => []},
            %{"redirect_uris" => "https://claude.ai/cb"},
            %{"redirect_uris" => too_many},
            %{"client_name" => String.duplicate("a", max_name + 1), "redirect_uris" => [@redirect_uri]},
            %{"client_name" => 42, "redirect_uris" => [@redirect_uri]}
          ] do
        assert {:error, :invalid_client_metadata} = Connections.register_client(params),
               "expected #{inspect(params, limit: 3)} to be rejected"
      end

      assert length(too_many) == 11
    end
  end

  # Scenario 5
  test "redirect_uri_registered?/2 is an exact string match" do
    client = register!()

    assert Connections.redirect_uri_registered?(client, "https://claude.ai/api/mcp/auth_callback")
    refute Connections.redirect_uri_registered?(client, "https://claude.ai/api/mcp/auth_callback/")
  end

  describe "authorize/3 + exchange_code/1" do
    # Scenario 6
    test "exchanges a code for a Bearer access + refresh token pair" do
      user = insert(:user)
      client = register!()
      params = authorize!(user, client)

      assert {:ok, %{token_type: "Bearer", expires_in: 3600, access_token: access, refresh_token: refresh}} =
               Connections.exchange_code(params)

      assert Connections.access_token_ttl_seconds() == 3600
      assert String.starts_with?(access, "relaym_")
      assert String.starts_with?(refresh, "relaym_")
      assert access =~ ~r/^relaym_[0-9a-f]{12}_[0-9a-f]{64}$/
      refute access == refresh
    end

    test "stores only the SHA-256 of the code" do
      user = insert(:user)
      client = register!()
      %{"code" => code} = authorize!(user, client)

      row = code_row(code)
      refute inspect(Map.from_struct(row)) =~ code
      assert DateTime.diff(row.expires_at, DateTime.utc_now(), :second) <= Connections.code_ttl_seconds()
    end

    # Scenario 7
    test "a replayed code is refused and revokes the tokens it minted" do
      user = insert(:user)
      client = register!()
      params = authorize!(user, client)
      {:ok, %{access_token: access}} = Connections.exchange_code(params)

      assert {:error, :invalid_grant} = Connections.exchange_code(params)
      assert :error = Connections.authenticate_access_token(access)
    end

    # Scenario 8
    test "a verifier whose S256 does not match is refused" do
      params = authorize!(insert(:user), register!())
      {other_verifier, _} = pkce_pair()

      assert {:error, :invalid_grant} = Connections.exchange_code(%{params | "code_verifier" => other_verifier})
    end

    test "a too-short verifier is refused" do
      params = authorize!(insert(:user), register!())

      assert {:error, :invalid_grant} = Connections.exchange_code(%{params | "code_verifier" => "0123456789"})
    end

    # Scenario 9
    test "an expired code is refused" do
      params = authorize!(insert(:user), register!())
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      params["code"] |> code_row() |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      assert {:error, :invalid_grant} = Connections.exchange_code(params)
    end

    # Scenario 10
    test "a different redirect_uri is invalid_grant" do
      params = authorize!(insert(:user), register!())

      assert {:error, :invalid_grant} =
               Connections.exchange_code(%{params | "redirect_uri" => "https://claude.ai/other"})
    end

    test "an unknown client_id is invalid_client" do
      params = authorize!(insert(:user), register!())

      assert {:error, :invalid_client} = Connections.exchange_code(%{params | "client_id" => "nope"})
    end

    test "a missing code is invalid_request" do
      params = authorize!(insert(:user), register!())

      assert {:error, :invalid_request} = Connections.exchange_code(Map.delete(params, "code"))
    end

    test "a code presented by another client is invalid_grant" do
      params = authorize!(insert(:user), register!())
      other = register!()

      assert {:error, :invalid_grant} = Connections.exchange_code(%{params | "client_id" => other.client_id})
    end

    test "a code of a revoked grant is invalid_grant" do
      user = insert(:user)
      client = register!()
      params = authorize!(user, client)

      user
      |> grant_for(client)
      |> Ecto.Changeset.change(revoked_at: DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update!()

      assert {:error, :invalid_grant} = Connections.exchange_code(params)
    end

    # Scenario 11
    test "a resource that differs from the authorized one is refused" do
      params = authorize!(insert(:user), register!(), resource: "http://127.0.0.1:4002/mcp")

      assert {:error, :invalid_grant} = Connections.exchange_code(Map.put(params, "resource", "https://other/mcp"))
    end

    test "the matching resource is accepted" do
      params = authorize!(insert(:user), register!(), resource: "http://127.0.0.1:4002/mcp")

      assert {:ok, _} = Connections.exchange_code(Map.put(params, "resource", "http://127.0.0.1:4002/mcp"))
    end

    test "an absent resource is accepted" do
      params = authorize!(insert(:user), register!(), resource: "http://127.0.0.1:4002/mcp")

      assert {:ok, _} = Connections.exchange_code(params)
    end

    # Scenario 19
    test "re-authorizing a revoked grant reconnects the same row" do
      user = insert(:user)
      client = register!()
      authorize!(user, client)
      grant = grant_for(user, client)
      long_ago = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      grant |> Ecto.Changeset.change(connected_at: long_ago) |> Repo.update!()
      :ok = Connections.revoke_grant(user, grant.id)

      params = authorize!(user, client)
      reconnected = grant_for(user, client)

      assert reconnected.id == grant.id
      assert reconnected.revoked_at == nil
      assert DateTime.after?(reconnected.connected_at, long_ago)
      assert {:ok, _} = Connections.exchange_code(params)
    end

    test "minting deletes the grant's expired tokens" do
      %{user: user, client: client, grant: grant} = connect!()
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(t in OAuthToken, where: t.grant_id == ^grant.id), set: [expires_at: past])

      {:ok, _} = Connections.exchange_code(authorize!(user, client))

      assert Repo.aggregate(from(t in OAuthToken, where: t.grant_id == ^grant.id), :count) == 2
    end
  end

  describe "refresh/1" do
    # Scenario 12
    test "rotates the refresh token; the old one is then refused" do
      %{client: client, tokens: %{refresh_token: r1}} = connect!()

      assert {:ok, %{access_token: a2, refresh_token: r2}} =
               Connections.refresh(%{"refresh_token" => r1, "client_id" => client.client_id})

      refute r2 == r1
      assert {:ok, _, _} = Connections.authenticate_access_token(a2)
      assert {:error, :invalid_grant} = Connections.refresh(%{"refresh_token" => r1, "client_id" => client.client_id})
    end

    # Scenario 13
    test "an access token presented as refresh_token is invalid_grant" do
      %{client: client, tokens: %{access_token: access}} = connect!()

      assert {:error, :invalid_grant} = Connections.refresh(%{"refresh_token" => access, "client_id" => client.client_id})
    end

    test "an unknown client is invalid_client and a missing param is invalid_request" do
      %{tokens: %{refresh_token: refresh}} = connect!()

      assert {:error, :invalid_client} = Connections.refresh(%{"refresh_token" => refresh, "client_id" => "nope"})
      assert {:error, :invalid_request} = Connections.refresh(%{"refresh_token" => refresh})
    end

    test "another client's refresh token is invalid_grant" do
      %{tokens: %{refresh_token: refresh}} = connect!()
      other = register!()

      assert {:error, :invalid_grant} = Connections.refresh(%{"refresh_token" => refresh, "client_id" => other.client_id})
    end

    test "an expired refresh token is invalid_grant" do
      %{client: client, grant: grant, tokens: %{refresh_token: refresh}} = connect!()
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(t in OAuthToken, where: t.grant_id == ^grant.id), set: [expires_at: past])

      assert {:error, :invalid_grant} =
               Connections.refresh(%{"refresh_token" => refresh, "client_id" => client.client_id})
    end
  end

  describe "authenticate_access_token/1" do
    # RE509: a deleted account is a tombstone, never a deleted row, so no cascade protects it.
    test "refuses both tokens of a tombstoned user" do
      %{user: user, client: client, tokens: %{access_token: access, refresh_token: refresh}} = connect!()
      user |> User.deletion_changeset() |> Repo.update!()

      assert Connections.authenticate_access_token(access) == :error

      assert Connections.refresh(%{"refresh_token" => refresh, "client_id" => client.client_id}) ==
               {:error, :invalid_grant}
    end

    # Scenario 14
    test "authenticates the user and touches last_used_at, throttled" do
      %{user: user, grant: grant, tokens: %{access_token: access}} = connect!()
      assert grant.last_used_at == nil

      assert {:ok, %User{id: user_id}, %OAuthGrant{id: grant_id}} = Connections.authenticate_access_token(access)
      assert user_id == user.id
      assert grant_id == grant.id

      %DateTime{} = touched = Repo.get!(OAuthGrant, grant.id).last_used_at

      # Inside the throttle window but well clear of "now", so an unthrottled write would show.
      recent = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:second)
      assert DateTime.diff(touched, recent) < Accounts.last_used_throttle_seconds()
      Repo.update_all(from(g in OAuthGrant, where: g.id == ^grant.id), set: [last_used_at: recent])

      assert {:ok, _, _} = Connections.authenticate_access_token(access)
      assert Repo.get!(OAuthGrant, grant.id).last_used_at == recent
    end

    # Scenario 15
    test "an expired access token is refused" do
      %{tokens: %{access_token: access}} = connect!()
      ["relaym", prefix, _secret] = String.split(access, "_", parts: 3)
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(t in OAuthToken, where: t.token_prefix == ^prefix), set: [expires_at: past])

      assert :error = Connections.authenticate_access_token(access)
    end

    test "a refresh token is not an access token" do
      %{tokens: %{refresh_token: refresh}} = connect!()

      assert :error = Connections.authenticate_access_token(refresh)
    end

    # Scenario 18
    test "user tokens, board keys, tampered tokens, nil and blank are all refused" do
      user = insert(:user)
      %{tokens: %{access_token: access}} = connect!(user)
      {:ok, %{token: user_token}} = Accounts.create_user_api_token(user)
      {:ok, %{token: board_token}} = Hamaca.ApiKeys.create_key(insert(:board), user)
      ["relaym", prefix, secret] = String.split(access, "_", parts: 3)
      {first, rest} = String.split_at(secret, 1)
      forged = "relaym_#{prefix}_#{if first == "0", do: "1", else: "0"}#{rest}"

      assert board_token =~ ~r/^relay_/

      for raw <- [user_token, board_token, TokenHelpers.tamper(access), forged, nil, ""] do
        assert :error = Connections.authenticate_access_token(raw), "expected #{inspect(raw)} to be refused"
      end

      # The relaym_ sentinel never authenticates against the other two schemes either.
      assert :error = Accounts.authenticate_user_api_token(access)
      assert :error = Hamaca.ApiKeys.authenticate(access)
    end
  end

  describe "revoke_grant/2 + list_grants/1" do
    # Scenario 16
    test "revoking kills the access token, the refresh token and the listing" do
      %{user: user, client: client, grant: grant, tokens: tokens} = connect!()

      assert :ok = Connections.revoke_grant(user, grant.id)
      assert :error = Connections.authenticate_access_token(tokens.access_token)

      assert {:error, :invalid_grant} =
               Connections.refresh(%{"refresh_token" => tokens.refresh_token, "client_id" => client.client_id})

      assert Connections.list_grants(user) == []
    end

    # Scenario 17
    test "another user's grant is not_found and untouched" do
      user = insert(:user)
      other_grant = insert(:oauth_grant)

      assert {:error, :not_found} = Connections.revoke_grant(user, other_grant.id)
      assert Repo.get!(OAuthGrant, other_grant.id).revoked_at == nil
    end

    # Scenario 20
    test "lists live grants with their client, newest connected_at first" do
      user = insert(:user)
      older = insert(:oauth_grant, user: user, connected_at: ~U[2026-01-01 00:00:00Z])
      newer = insert(:oauth_grant, user: user, connected_at: ~U[2026-02-01 00:00:00Z])

      assert [first, second] = Connections.list_grants(user)
      assert [first.id, second.id] == [newer.id, older.id]
      assert %OAuthClient{client_name: "claude.ai"} = first.oauth_client
      assert %OAuthClient{} = second.oauth_client
    end
  end

  # Scenario 21
  describe "capabilities/1" do
    test "phrases the read bullet by board count" do
      assert hd(Connections.capabilities(7).can).title == "Read all 7 of your boards"
      assert hd(Connections.capabilities(1).can).title == "Read your 1 board"
      assert hd(Connections.capabilities(0).can).title == "Read your boards"
    end

    test "has exactly one can entry and the fixed cannot line" do
      %{can: can, cannot: cannot} = Connections.capabilities(7)

      assert [
               %{
                 icon: "hero-eye",
                 detail: ": cards, comments and who has the baton. Boards you join later are included too."
               }
             ] = can

      assert cannot == "Claude can't approve, reject, answer questions or move cards. Those stay with you in Hamaca."
    end
  end

  test "policy numbers" do
    assert Connections.refresh_token_ttl_seconds() == 2_592_000
    assert Connections.code_ttl_seconds() == 60
    assert Connections.token_sentinel() == "relaym"

    assert Connections.registration_limits() == %{
             max_redirect_uris: 10,
             max_client_name_length: 200,
             max_redirect_uri_length: 2000
           }
  end
end
