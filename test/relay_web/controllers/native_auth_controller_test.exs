defmodule RelayWeb.NativeAuthControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Accounts.GoogleTokenValidator
  alias Relay.Repo
  alias Schemas.Membership
  alias Schemas.User

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
      # An existing user already owns this email; the new google sub collides on the
      # unique email constraint, so the upsert changeset fails.
      insert(:user, email: "ada@example.com", provider_uid: "someone-else")
      stub_google(@tokeninfo)

      conn = post(conn, ~p"/api/auth/native/google", %{id_token: "tok"})

      assert %{"success" => false, "details" => %{"email" => _}} = json_response(conn, 422)
      refute get_session(conn, :user_id)
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
  end
end
