defmodule RelayWeb.NativeAuthControllerTest do
  use RelayWeb.ConnCase, async: true

  import Relay.AppleTokenFixtures

  # Bad-token cases log `[error] Google tokeninfo failed` on purpose; capture it (shown only on
  # failure) so it doesn't clutter the suite output.
  alias Relay.Accounts.GoogleTokenValidator
  alias Relay.Repo
  alias Schemas.Membership
  alias Schemas.User

  @moduletag :capture_log

  @tokeninfo %{
    "aud" => "test-google-client-id",
    "iss" => "https://accounts.google.com",
    "email" => "ada@example.com",
    "email_verified" => "true",
    "name" => "Ada Lovelace",
    "picture" => "https://example.com/ada.png",
    "sub" => "google-sub-1"
  }

  defp stub_google(payload) do
    Req.Test.stub(GoogleTokenValidator, fn conn -> Req.Test.json(conn, payload) end)
  end

  describe "POST /api/auth/native/google" do
    test "happy path mints the session, sets the cookie, and returns the user", %{conn: conn} do
      stub_google(@tokeninfo)

      conn = post(conn, ~p"/api/auth/native/google", %{id_token: "tok"})

      user = Repo.get_by!(User, provider_uid: "google-sub-1")
      assert %{"success" => true, "user" => body_user} = json_response(conn, 200)

      assert body_user == %{
               "id" => user.id,
               "name" => "Ada Lovelace",
               "email" => "ada@example.com",
               "avatar_url" => "https://example.com/ada.png"
             }

      assert get_session(conn, :user_id) == user.id
      assert Map.has_key?(conn.resp_cookies, "_relay_key")
    end

    test "returns a bearer token that authenticates the /api/all scope", %{conn: conn} do
      stub_google(@tokeninfo)

      conn = post(conn, ~p"/api/auth/native/google", %{id_token: "tok"})

      assert %{"success" => true, "token" => token} = json_response(conn, 200)
      assert is_binary(token) and String.starts_with?(token, "relayu_")

      # The point is not that a `token` key exists — it is that the native app can
      # actually call the bearer-only scope with it. Without this the app signs in
      # and the inbox still cannot load, which is the bug users see.
      authed =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/all/feed")

      assert json_response(authed, 200)
    end

    test "resolves pending invites on native login", %{conn: conn} do
      stub_google(@tokeninfo)
      membership = insert(:membership, email: "ada@example.com", user: nil)

      post(conn, ~p"/api/auth/native/google", %{id_token: "tok"})

      user = Repo.get_by!(User, provider_uid: "google-sub-1")
      assert Repo.get!(Membership, membership.id).user_id == user.id
    end

    test "missing id_token returns 400", %{conn: conn} do
      conn = post(conn, ~p"/api/auth/native/google", %{})

      assert %{"success" => false, "error" => _} = json_response(conn, 400)
      refute get_session(conn, :user_id)
    end

    test "an invalid token returns 401", %{conn: conn} do
      Req.Test.stub(GoogleTokenValidator, fn conn ->
        Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid_token"}))
      end)

      conn = post(conn, ~p"/api/auth/native/google", %{id_token: "bad"})

      assert %{"success" => false} = json_response(conn, 401)
      refute get_session(conn, :user_id)
      assert Repo.aggregate(User, :count) == 0
    end

    test "an upsert failure returns 422", %{conn: conn} do
      # A return visit (sub g-1) whose new email already belongs to another user collides on
      # the unique email constraint, so the profile refresh fails.
      insert(:user, provider_uid: "g-1", email: "one@example.com")
      insert(:user, email: "two@example.com")
      stub_google(%{@tokeninfo | "sub" => "g-1", "email" => "two@example.com"})

      conn = post(conn, ~p"/api/auth/native/google", %{id_token: "tok"})

      assert %{"success" => false, "error" => "Could not save user", "details" => %{"email" => _}} =
               json_response(conn, 422)

      refute get_session(conn, :user_id)
    end

    test "a new google sub with an existing user's email signs in that user", %{conn: conn} do
      existing = insert(:user, email: "ada@example.com", provider_uid: "someone-else")
      stub_google(@tokeninfo)

      conn = post(conn, ~p"/api/auth/native/google", %{id_token: "tok"})

      assert %{"success" => true, "user" => %{"id" => id}} = json_response(conn, 200)
      assert id == existing.id
      assert get_session(conn, :user_id) == existing.id
      assert Repo.get!(User, existing.id).provider_uid == "someone-else"
    end
  end

  describe "POST /api/auth/native/apple" do
    setup do
      key = signing_key()
      stub_jwks(key, "test-kid")
      %{key: key}
    end

    test "happy path signs in, sets the cookie, and returns the user and a working bearer",
         %{conn: conn, key: key} do
      token = apple_token(key, "test-kid", %{})

      conn =
        post(conn, ~p"/api/auth/native/apple", %{
          identity_token: token,
          nonce: "raw-nonce-1",
          given_name: "Alice",
          family_name: "Apple"
        })

      user = Repo.get_by!(User, provider_uid: "apple-sub-1")
      assert user.provider == "apple"
      body = json_response(conn, 200)
      assert body["success"] == true

      assert body["user"] == %{
               "id" => user.id,
               "name" => "Alice Apple",
               "email" => "alice@example.com",
               "avatar_url" => nil
             }

      assert get_session(conn, :user_id) == user.id
      assert Map.has_key?(conn.resp_cookies, "_relay_key")
      assert String.starts_with?(body["token"], "relayu_")

      authed =
        build_conn()
        |> put_req_header("authorization", "Bearer #{body["token"]}")
        |> get(~p"/api/all/feed")

      assert json_response(authed, 200)
    end

    test "no given/family name creates a user with a nil name", %{conn: conn, key: key} do
      token = apple_token(key, "test-kid", %{})

      conn = post(conn, ~p"/api/auth/native/apple", %{identity_token: token, nonce: "raw-nonce-1"})

      assert json_response(conn, 200)["success"] == true
      assert Repo.get_by!(User, provider_uid: "apple-sub-1").name == nil
    end

    test "a blank given name and nil family name create a user with a nil name",
         %{conn: conn, key: key} do
      token = apple_token(key, "test-kid", %{})

      conn =
        post(conn, ~p"/api/auth/native/apple", %{
          identity_token: token,
          nonce: "raw-nonce-1",
          given_name: "  ",
          family_name: nil
        })

      assert json_response(conn, 200)["success"] == true
      assert Repo.get_by!(User, provider_uid: "apple-sub-1").name == nil
    end

    test "an Apple sign-in for a Google user's email signs in that user", %{conn: conn, key: key} do
      google_user = insert(:user, email: "alice@example.com", provider: "google", provider_uid: "google-sub-alice")
      token = apple_token(key, "test-kid", %{})

      conn = post(conn, ~p"/api/auth/native/apple", %{identity_token: token, nonce: "raw-nonce-1"})

      assert json_response(conn, 200)["user"]["id"] == google_user.id
      assert Repo.aggregate(User, :count) == 1
      assert Repo.get!(User, google_user.id).provider_uid == "google-sub-alice"
    end

    test "a Google sign-in for an Apple user's email signs in that user", %{conn: conn, key: key} do
      token = apple_token(key, "test-kid", %{})
      apple = post(conn, ~p"/api/auth/native/apple", %{identity_token: token, nonce: "raw-nonce-1"})
      apple_id = json_response(apple, 200)["user"]["id"]

      stub_google(%{@tokeninfo | "email" => "alice@example.com", "sub" => "google-sub-x"})
      google = post(build_conn(), ~p"/api/auth/native/google", %{id_token: "tok"})

      assert json_response(google, 200)["user"]["id"] == apple_id
      assert Repo.aggregate(User, :count) == 1
    end

    test "resolves pending invites on Apple sign-in", %{conn: conn, key: key} do
      membership = insert(:membership, email: "alice@example.com", user: nil)
      token = apple_token(key, "test-kid", %{})

      post(conn, ~p"/api/auth/native/apple", %{identity_token: token, nonce: "raw-nonce-1"})

      user = Repo.get_by!(User, provider_uid: "apple-sub-1")
      assert Repo.get!(Membership, membership.id).user_id == user.id
    end

    test "forged, foreign, expired or replayed tokens return 401 and create no user",
         %{key: key} do
      cases = [
        {apple_token(new_signing_key(), "test-kid", %{}), "raw-nonce-1", "invalid_token"},
        {apple_token(key, "test-kid", %{aud: "com.attacker.App"}), "raw-nonce-1", "invalid_audience"},
        {apple_token(key, "test-kid", %{iss: "https://evil.example.com"}), "raw-nonce-1", "invalid_issuer"},
        {apple_token(key, "test-kid", %{exp: System.os_time(:second) - 60}), "raw-nonce-1", "token_expired"},
        {apple_token(key, "test-kid", %{}), "wrong", "invalid_nonce"}
      ]

      for {token, nonce, reason} <- cases do
        conn = post(build_conn(), ~p"/api/auth/native/apple", %{identity_token: token, nonce: nonce})

        assert json_response(conn, 401) == %{
                 "success" => false,
                 "error" => "Invalid token",
                 "reason" => reason
               }

        refute get_session(conn, :user_id)
        assert Repo.aggregate(User, :count) == 0
      end
    end

    test "a missing or non-string identity_token or nonce returns 400", %{key: key} do
      token = apple_token(key, "test-kid", %{})

      for params <- [
            %{nonce: "raw-nonce-1"},
            %{identity_token: token},
            %{identity_token: %{"x" => 1}, nonce: "raw-nonce-1"}
          ] do
        conn = post(build_conn(), ~p"/api/auth/native/apple", params)

        assert json_response(conn, 400) == %{
                 "success" => false,
                 "error" => "Missing identity_token parameter"
               }

        refute get_session(conn, :user_id)
      end
    end
  end

  describe "GET /api/auth/native/me" do
    test "returns a bearer token so a restored session can call /api/all", %{conn: conn} do
      user = insert(:user, name: "Ada Lovelace", email: "ada@example.com")

      conn = conn |> log_in_user(user) |> get(~p"/api/auth/native/me")

      # RLY-86 restores the session cookie from the Keychain but the raw bearer is
      # never persisted (it is unrecoverable by design), so a restored launch would
      # otherwise hold a cookie and no token — the inbox broken exactly as on a
      # cold sign-in. The verify round-trip is where the app gets a fresh one.
      assert %{"success" => true, "token" => token} = json_response(conn, 200)
      assert String.starts_with?(token, "relayu_")

      authed =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/all/feed")

      assert json_response(authed, 200)
    end

    test "returns the signed-in user", %{conn: conn} do
      user = insert(:user, name: "Ada Lovelace", email: "ada@example.com")

      conn = conn |> log_in_user(user) |> get(~p"/api/auth/native/me")

      # `token` is asserted by its own test above; it is unrecoverable and differs
      # per call, so match the stable shape rather than the whole body.
      assert %{
               "success" => true,
               "user" => %{"id" => id, "name" => "Ada Lovelace", "email" => "ada@example.com"}
             } = json_response(conn, 200)

      assert id == user.id
    end

    test "with no session returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/auth/native/me")

      assert json_response(conn, 401) == %{"success" => false, "error" => "Not signed in"}
    end

    test "with a session whose user is gone returns 401", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(user_id: -1)
        |> get(~p"/api/auth/native/me")

      assert json_response(conn, 401) == %{"success" => false, "error" => "Not signed in"}
    end

    test "with a session stamped past the 7-day window returns 401 and mints no token", %{conn: conn} do
      user = insert(:user)
      expired = System.system_time(:second) - (60 * 60 * 24 * 7 + 60)

      conn =
        conn
        |> Plug.Test.init_test_session(user_id: user.id, session_refreshed_at: expired)
        |> get(~p"/api/auth/native/me")

      # Without this check, a replayed cookie older than the 7-day window would
      # still mint a fresh, longer-lived bearer token for /api/all — defeating
      # the whole point of the window (RLY-127).
      assert json_response(conn, 401) == %{"success" => false, "error" => "Not signed in"}
      refute Repo.get_by(Schemas.UserApiToken, user_id: user.id)
    end

    test "returns the avatar_url so the photo survives an app restart", %{conn: conn} do
      user = insert(:user, avatar_url: "https://example.com/ada.png")

      conn = conn |> log_in_user(user) |> get(~p"/api/auth/native/me")

      assert %{"success" => true, "user" => %{"avatar_url" => "https://example.com/ada.png"}} =
               json_response(conn, 200)
    end

    test "avatar_url is null-safe for a user without one", %{conn: conn} do
      user = insert(:user, avatar_url: nil)

      conn = conn |> log_in_user(user) |> get(~p"/api/auth/native/me")

      assert %{"success" => true, "user" => %{"avatar_url" => nil}} = json_response(conn, 200)
    end

    test "the user JSON cannot drift from what sign-in returned", %{conn: conn} do
      stub_google(@tokeninfo)
      signed_in = post(conn, ~p"/api/auth/native/google", %{id_token: "tok"})
      user = Repo.get_by!(User, provider_uid: "google-sub-1")

      me = build_conn() |> log_in_user(user) |> get(~p"/api/auth/native/me")

      assert json_response(me, 200)["user"] == json_response(signed_in, 200)["user"]
    end

    test "re-stamps the session so the native window slides on app launch", %{conn: conn} do
      user = insert(:user)
      stale = System.system_time(:second) - 60 * 60 * 24 * 3

      conn =
        conn
        |> Plug.Test.init_test_session(user_id: user.id, session_refreshed_at: stale)
        |> get(~p"/api/auth/native/me")

      assert %{"success" => true} = json_response(conn, 200)
      assert get_session(conn, :session_refreshed_at) > stale
    end

    test "does not re-stamp a session it rejects", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(user_id: -1)
        |> get(~p"/api/auth/native/me")

      assert json_response(conn, 401)
      refute get_session(conn, :session_refreshed_at)
    end
  end

  describe "feedback_url on the success body (RE397)" do
    @public_board "https://relayboard.fly.dev/board/relay/public"

    test "GET /me carries an assigned feedback_url at the top level, not inside user", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> assign(:feedback_url, @public_board)
        |> log_in_user(user)
        |> get(~p"/api/auth/native/me")

      body = json_response(conn, 200)
      assert body["feedback_url"] == @public_board
      refute Map.has_key?(body["user"], "feedback_url")
    end

    test "GET /me carries feedback_url as null when unset", %{conn: conn} do
      user = insert(:user)

      body = conn |> log_in_user(user) |> get(~p"/api/auth/native/me") |> json_response(200)

      assert Map.has_key?(body, "feedback_url")
      assert body["feedback_url"] == nil
    end

    test "POST /google carries an assigned feedback_url", %{conn: conn} do
      stub_google(@tokeninfo)

      body =
        conn
        |> assign(:feedback_url, @public_board)
        |> post(~p"/api/auth/native/google", %{id_token: "tok"})
        |> json_response(200)

      assert body["feedback_url"] == @public_board
    end

    test "POST /google carries feedback_url as null when unset", %{conn: conn} do
      stub_google(@tokeninfo)

      body = conn |> post(~p"/api/auth/native/google", %{id_token: "tok"}) |> json_response(200)

      assert Map.has_key?(body, "feedback_url")
      assert body["feedback_url"] == nil
    end

    test "POST /apple carries an assigned feedback_url", %{conn: conn} do
      key = signing_key()
      stub_jwks(key, "test-kid")
      token = apple_token(key, "test-kid", %{})

      body =
        conn
        |> assign(:feedback_url, "https://example.com/ideas")
        |> post(~p"/api/auth/native/apple", %{identity_token: token, nonce: "raw-nonce-1"})
        |> json_response(200)

      assert body["feedback_url"] == "https://example.com/ideas"
    end

    test "a 401 body stays lean and carries no feedback_url", %{conn: conn} do
      body =
        conn
        |> assign(:feedback_url, @public_board)
        |> get(~p"/api/auth/native/me")
        |> json_response(401)

      assert body == %{"success" => false, "error" => "Not signed in"}
      refute Map.has_key?(body, "feedback_url")
    end
  end
end
