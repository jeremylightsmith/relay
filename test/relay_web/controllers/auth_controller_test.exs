defmodule RelayWeb.AuthControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Billing
  alias Relay.Members
  alias Relay.Repo
  alias Schemas.Membership
  alias Schemas.User

  @unverified_flash "Your Google account's email address isn't verified. Verify it with Google, then sign in again."

  defp google_auth(userinfo \\ %{"email_verified" => true}) do
    %Ueberauth.Auth{
      provider: :google,
      uid: "google-uid-123",
      info: %Ueberauth.Auth.Info{
        email: "ada@example.com",
        name: "Ada Lovelace",
        image: "https://example.com/ada.png"
      },
      extra: %Ueberauth.Auth.Extra{raw_info: %{user: userinfo}}
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

  describe "GET /auth/google/callback email verification (RE343)" do
    for {label, userinfo} <- [
          {"email_verified false", %{"email_verified" => false}},
          {"email_verified \"false\"", %{"email_verified" => "false"}},
          {"a missing email_verified claim", %{}}
        ] do
      test "with #{label} refuses sign-in and leaves pending invites unbound", %{conn: conn} do
        board = insert(:board)
        {:ok, invite} = Members.invite(board, "ada@example.com")

        conn =
          conn
          |> assign(:ueberauth_auth, google_auth(unquote(Macro.escape(userinfo))))
          |> get(~p"/auth/google/callback")

        assert redirected_to(conn) == ~p"/"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) == @unverified_flash
        refute get_session(conn, :user_id)
        # The board factory builds an owner user, so check this identity, not the total count.
        refute Repo.get_by(User, provider_uid: "google-uid-123")
        refute Repo.get_by(User, email: "ada@example.com")
        assert Repo.get!(Membership, invite.id).user_id == nil
      end
    end

    for verified <- [true, "true"] do
      test "with email_verified #{inspect(verified)} signs in and resolves the pending invite",
           %{conn: conn} do
        board = insert(:board)
        {:ok, invite} = Members.invite(board, "ada@example.com")

        conn =
          conn
          |> assign(:ueberauth_auth, google_auth(%{"email_verified" => unquote(verified)}))
          |> get(~p"/auth/google/callback")

        user = Repo.get_by!(User, provider_uid: "google-uid-123")
        assert get_session(conn, :user_id) == user.id
        assert redirected_to(conn) == ~p"/board"
        assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Signed in as ada@example.com"
        assert Repo.get!(Membership, invite.id).user_id == user.id
      end
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

  describe "GET /auth/google/callback with a sign-up code" do
    setup do
      Process.put(:billing_enabled, true)
      %{relayconf: insert(:promo_code, code: "RELAYCONF", percent_off: 50, months: 3)}
    end

    defp sign_up(conn, code, path \\ ~p"/auth/google/callback") do
      conn
      |> Plug.Test.init_test_session(signup_promo_code: code)
      |> assign(:ueberauth_auth, google_auth())
      |> get(path)
    end

    test "a new user's account holds the code (scenario 10)", %{conn: conn, relayconf: relayconf} do
      conn = sign_up(conn, "relayconf")

      account = Billing.get_account(Repo.get_by!(User, provider_uid: "google-uid-123"))
      assert account.promo_code_id == relayconf.id
      assert account.promo_months_left == 3
      assert redirected_to(conn) == ~p"/board"
    end

    test "an unknown code never fails sign-up (scenario 11)", %{conn: conn} do
      conn = sign_up(conn, "NOPE")

      assert redirected_to(conn) == ~p"/board"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Signed in as ada@example.com"
      assert Billing.get_account(Repo.get_by!(User, provider_uid: "google-uid-123")).promo_code_id == nil
    end

    test "an existing user redeems nothing (scenario 12)", %{conn: conn} do
      existing = insert(:user, provider_uid: "google-uid-123", email: "ada@example.com")
      {:ok, _account} = Billing.ensure_trial(existing, Date.utc_today())

      sign_up(conn, "RELAYCONF")

      assert Billing.get_account(existing).promo_code_id == nil
    end

    test "the OAuth ?code= is never read as a promo code (scenario 13)", %{conn: conn, relayconf: relayconf} do
      insert(:promo_code, code: "GOOGLE-OAUTH-CODE")

      sign_up(conn, "RELAYCONF", ~p"/auth/google/callback?code=google-oauth-code")

      assert Billing.get_account(Repo.get_by!(User, provider_uid: "google-uid-123")).promo_code_id == relayconf.id
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
