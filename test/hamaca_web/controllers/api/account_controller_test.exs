defmodule HamacaWeb.Api.AccountControllerTest do
  use HamacaWeb.ConnCase, async: true

  import Hamaca.AppleRevokeFixtures

  alias Hamaca.Accounts
  alias Hamaca.Repo
  alias Schemas.Board

  # Every `error.code` a test below drove through `DELETE /api/all/account`. Scenario 9 pins
  # that this is exactly `Accounts.deletion_errors/0`, so a new atom fails CI until it is mapped
  # and driven here.
  @driven_codes ~w(confirm_required invalid_transfers apple_reauth_required apple_revoke_failed apple_mismatch)

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, conn: authed(conn, user), user: user}
  end

  defp authed(conn, user) do
    {:ok, %{token: token}} = Accounts.create_user_api_token(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp member!(board, user, joined) do
    insert(:membership, board: board, user: user, email: user.email, inserted_at: joined)
  end

  # U owns "Alpha" (slug alpha-<n>) with Ana, who joined on 2026-03-01.
  defp alpha(user) do
    ana = insert(:user, name: "Ana Ruiz")
    alpha = insert(:board, owner: user, name: "Alpha", slug: unique_slug("alpha"))
    member!(alpha, user, ~U[2026-01-01 09:00:00Z])
    member!(alpha, ana, ~U[2026-03-01 10:00:00Z])
    %{alpha: alpha, ana: ana}
  end

  defp solo(user) do
    solo = insert(:board, owner: user, name: "Solo", slug: unique_slug("solo"))
    member!(solo, user, ~U[2026-01-01 09:00:00Z])
    solo
  end

  defp preview(conn), do: conn |> get(~p"/api/all/account/deletion") |> json_response(200) |> Map.fetch!("data")

  defp delete_error(conn, params, status) do
    conn |> delete(~p"/api/all/account", params) |> json_response(status) |> Map.fetch!("error")
  end

  describe "GET /api/all/account/deletion" do
    test "returns the deletion preview", %{conn: conn, user: user} do
      %{alpha: alpha, ana: ana} = alpha(user)

      data = conn |> get(~p"/api/all/account/deletion") |> json_response(200) |> Map.fetch!("data")

      assert data["shared_boards"] == [
               %{
                 "slug" => alpha.slug,
                 "name" => "Alpha",
                 "member_count" => 2,
                 "candidates" => [
                   %{
                     "user_id" => ana.id,
                     "name" => ana.name,
                     "avatar_url" => ana.avatar_url,
                     "member_since" => "2026-03-01"
                   }
                 ]
               }
             ]

      assert data["solo_boards"] == []
      assert data["plan_ends"] == false
      assert data["runners"] == []
      assert data["apple_reauth_required"] == false
    end
  end

  describe "without a user token" do
    test "GET /api/all/account/deletion is 401 unauthorized" do
      error = build_conn() |> get(~p"/api/all/account/deletion") |> json_response(401) |> Map.fetch!("error")
      assert error["code"] == "unauthorized"
    end

    test "DELETE /api/all/account is 401 unauthorized" do
      error = build_conn() |> delete(~p"/api/all/account", %{"confirm" => "DELETE"}) |> json_response(401)
      assert error["error"]["code"] == "unauthorized"
    end
  end

  describe "DELETE /api/all/account refusals" do
    test "a shared board with no transfer is invalid_transfers and changes nothing", %{conn: conn, user: user} do
      alpha(user)
      before = preview(conn)

      error = delete_error(conn, %{"confirm" => "DELETE"}, 422)

      assert error["code"] == "invalid_transfers"
      assert error["message"] == "Choose a new owner for every shared board."
      assert preview(conn) == before
    end

    test "a lowercase confirm is confirm_required", %{conn: conn} do
      error = delete_error(conn, %{"confirm" => "delete"}, 422)

      assert error["code"] == "confirm_required"
      assert error["message"] == "Type DELETE to confirm."
      assert preview(conn)
    end

    test "a missing confirm is confirm_required", %{conn: conn, user: user} do
      solo(user)

      error = delete_error(conn, %{}, 422)

      assert error["code"] == "confirm_required"
      assert preview(conn)
      assert Accounts.get_user(user.id)
    end

    test "a string user id in transfers is invalid_transfers", %{conn: conn, user: user} do
      %{alpha: alpha, ana: ana} = alpha(user)

      error = delete_error(conn, %{"confirm" => "DELETE", "transfers" => %{alpha.slug => "#{ana.id}"}}, 422)

      assert error["code"] == "invalid_transfers"
      assert Repo.get!(Board, alpha.id).owner_id == user.id
    end

    test "a list for transfers is invalid_transfers", %{conn: conn, user: user} do
      %{ana: ana} = alpha(user)

      error = delete_error(conn, %{"confirm" => "DELETE", "transfers" => [ana.id]}, 422)

      assert error["code"] == "invalid_transfers"
      assert Accounts.get_user(user.id)
    end
  end

  describe "DELETE /api/all/account for an Apple account" do
    # Apple failures log on purpose; capture it (shown only on a failure).
    @describetag :capture_log

    setup %{conn: conn} do
      put_apple_signin_config()
      apple = insert(:user, provider: "apple", provider_uid: "apple-sub-1")
      solo(apple)
      %{apple: apple, conn: conn |> delete_req_header("authorization") |> authed(apple)}
    end

    test "no authorization code is apple_reauth_required and the account stays", %{conn: conn, apple: apple} do
      error = delete_error(conn, %{"confirm" => "DELETE"}, 422)

      assert error["code"] == "apple_reauth_required"
      assert error["message"] == "Sign in with Apple again to delete this account."
      assert Accounts.get_user(apple.id)
    end

    test "a refused Apple exchange is 502 apple_revoke_failed", %{conn: conn, apple: apple} do
      stub_apple(%{"/auth/token" => {400, %{"error" => "invalid_grant"}}})

      error = delete_error(conn, %{"confirm" => "DELETE", "apple_authorization_code" => "code-1"}, 502)

      assert error["code"] == "apple_revoke_failed"
      assert error["message"] == "Couldn't reach Apple. Nothing was deleted."
      assert Accounts.get_user(apple.id)
    end

    test "a code for another Apple ID is 403 apple_mismatch", %{conn: conn, apple: apple} do
      stub_apple_ok("someone-else")

      error = delete_error(conn, %{"confirm" => "DELETE", "apple_authorization_code" => "code-1"}, 403)

      assert error["code"] == "apple_mismatch"
      assert error["message"] == "That Apple ID doesn't match this account."
      assert Accounts.get_user(apple.id)
    end
  end

  describe "DELETE /api/all/account success" do
    test "transfers the shared board, deletes the solo one and signs the token out", %{conn: conn, user: user} do
      %{alpha: alpha, ana: ana} = alpha(user)
      solo = solo(user)
      {:ok, _second} = Accounts.create_user_api_token(user)

      resp = delete(conn, ~p"/api/all/account", %{"confirm" => "DELETE", "transfers" => %{alpha.slug => ana.id}})

      assert resp.status == 204
      assert resp.resp_body == ""
      assert Repo.get!(Board, alpha.id).owner_id == ana.id
      refute Repo.get(Board, solo.id)
      assert conn |> get(~p"/api/all/account/deletion") |> json_response(401)
      assert Accounts.get_user(user.id) == nil
    end
  end

  test "every deletion error code is driven through the endpoint above" do
    assert MapSet.new(@driven_codes) == MapSet.new(Accounts.deletion_errors(), &Atom.to_string/1)
  end
end
