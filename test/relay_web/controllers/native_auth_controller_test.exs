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
      assert body_user == %{"id" => user.id, "name" => "Ada Lovelace", "email" => "ada@example.com"}
      assert get_session(conn, :user_id) == user.id
      assert Map.has_key?(conn.resp_cookies, "_relay_key")
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
end
