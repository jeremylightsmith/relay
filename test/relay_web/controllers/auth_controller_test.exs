defmodule RelayWeb.AuthControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Repo
  alias Schemas.User

  defp google_auth do
    %Ueberauth.Auth{
      provider: :google,
      uid: "google-uid-123",
      info: %Ueberauth.Auth.Info{
        email: "ada@example.com",
        name: "Ada Lovelace",
        image: "https://example.com/ada.png"
      }
    }
  end

  describe "GET /auth/google (request phase)" do
    test "redirects to Google's consent screen", %{conn: conn} do
      conn = get(conn, ~p"/auth/google")
      assert redirected_to(conn) =~ "accounts.google.com"
    end
  end

  describe "GET /auth/google/callback" do
    test "with a successful auth upserts the user, starts a session, and redirects to the board",
         %{conn: conn} do
      conn =
        conn
        |> assign(:ueberauth_auth, google_auth())
        |> get(~p"/auth/google/callback")

      user = Repo.get_by!(User, provider_uid: "google-uid-123")
      assert user.email == "ada@example.com"
      assert get_session(conn, :user_id) == user.id
      assert redirected_to(conn) == ~p"/board"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Signed in"
    end

    test "reuses the existing user on a repeat sign-in", %{conn: conn} do
      existing = insert(:user, provider_uid: "google-uid-123", email: "ada@example.com")

      conn =
        conn
        |> assign(:ueberauth_auth, google_auth())
        |> get(~p"/auth/google/callback")

      assert get_session(conn, :user_id) == existing.id
      assert Repo.aggregate(User, :count) == 1
    end

    test "with a failure flashes an error and redirects to sign-in", %{conn: conn} do
      conn =
        conn
        |> assign(:ueberauth_failure, %Ueberauth.Failure{errors: []})
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "failed"
      refute get_session(conn, :user_id)
      assert Repo.aggregate(User, :count) == 0
    end
  end

  describe "GET /auth/google (request phase) with return_to" do
    test "stores a local return_to path in the session", %{conn: conn} do
      conn = get(conn, ~p"/auth/google?return_to=/board/acme/public")
      assert get_session(conn, :user_return_to) == "/board/acme/public"
    end

    test "rejects an external return_to (scheme+host)", %{conn: conn} do
      conn = get(conn, ~p"/auth/google?return_to=https://evil.com/steal")
      refute get_session(conn, :user_return_to)
    end

    test "rejects a protocol-relative return_to", %{conn: conn} do
      conn = get(conn, ~p"/auth/google?return_to=//evil.com/steal")
      refute get_session(conn, :user_return_to)
    end

    test "no return_to param leaves the session untouched", %{conn: conn} do
      conn = get(conn, ~p"/auth/google")
      refute get_session(conn, :user_return_to)
    end
  end

  describe "GET /auth/google/callback with a stored return_to" do
    test "redirects to the stored local path instead of the board", %{conn: conn} do
      conn =
        conn
        |> get(~p"/auth/google?return_to=/board/acme/public")
        |> recycle()
        |> assign(:ueberauth_auth, google_auth())
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == "/board/acme/public"
    end

    test "falls back to the board when no return_to was stored", %{conn: conn} do
      conn =
        conn
        |> assign(:ueberauth_auth, google_auth())
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == ~p"/board"
    end
  end

  describe "DELETE /logout" do
    test "clears the session and redirects to the sign-in page", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> log_in_user(user)
        |> delete(~p"/logout")

      refute get_session(conn, :user_id)
      assert redirected_to(conn) == ~p"/"
    end
  end
end
