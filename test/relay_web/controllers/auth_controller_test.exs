defmodule RelayWeb.AuthControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Accounts.User
  alias Relay.Repo

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
    test "with a successful auth upserts the user, starts a session, and redirects home",
         %{conn: conn} do
      conn =
        conn
        |> assign(:ueberauth_auth, google_auth())
        |> get(~p"/auth/google/callback")

      user = Repo.get_by!(User, provider_uid: "google-uid-123")
      assert user.email == "ada@example.com"
      assert get_session(conn, :user_id) == user.id
      assert redirected_to(conn) == ~p"/home"
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
