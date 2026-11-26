defmodule Hamaca.Accounts.DeletionTest do
  use Hamaca.DataCase, async: true

  import Hamaca.AppleRevokeFixtures

  alias Hamaca.Accounts
  alias Hamaca.ApiKeys
  alias Hamaca.Billing
  alias Hamaca.Billing.Payments.Stripe
  alias Schemas.Board
  alias Schemas.CardOwner
  alias Schemas.DeviceToken
  alias Schemas.Membership
  alias Schemas.OAuthGrant
  alias Schemas.SetupMachine
  alias Schemas.UsageVisit
  alias Schemas.User
  alias Schemas.UserApiToken
  alias Schemas.Vote

  defp slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp member!(board, user, joined) do
    insert(:membership, board: board, user: user, email: user.email, inserted_at: joined)
  end

  defp invite!(board), do: insert(:membership, board: board, user: nil, email: "invitee-#{board.id}@example.com")

  # U owns "Alpha" (U joined first, then Ana, then Ken) plus a pending invite.
  defp alpha(u) do
    ana = insert(:user, name: "Ana")
    ken = insert(:user, name: "Ken")
    alpha = insert(:board, owner: u, name: "Alpha", slug: slug("alpha"))
    member!(alpha, u, ~U[2026-01-01 09:00:00Z])
    member!(alpha, ana, ~U[2026-03-01 09:00:00Z])
    member!(alpha, ken, ~U[2026-06-01 09:00:00Z])
    invite!(alpha)
    %{alpha: alpha, ana: ana, ken: ken}
  end

  defp solo(u) do
    solo = insert(:board, owner: u, name: "Solo", slug: slug("solo"))
    member!(solo, u, ~U[2026-01-01 09:00:00Z])
    invite!(solo)
    solo
  end

  # Bob's board, U a non-owner member of it.
  defp bobs(u) do
    bob = insert(:user, name: "Bob")
    bobs = insert(:board, owner: bob, name: "Bobs", slug: slug("bobs"))
    member!(bobs, bob, ~U[2026-01-01 09:00:00Z])
    member!(bobs, u, ~U[2026-02-01 09:00:00Z])
    %{bobs: bobs, bob: bob}
  end

  defp machine!(board, user, attrs) do
    Repo.insert!(struct!(%SetupMachine{board_id: board.id, user_id: user.id}, attrs))
  end

  defp count(schema, user_id) do
    Repo.aggregate(from(r in schema, where: r.user_id == ^user_id), :count)
  end

  describe "deletion_preview/1" do
    test "a shared owned board lists every resolved member and the others as candidates, longest-serving first" do
      u = insert(:user)
      %{alpha: alpha, ana: ana, ken: ken} = alpha(u)

      assert %{shared_boards: [shared]} = Accounts.deletion_preview(u)
      assert shared.slug == alpha.slug
      assert shared.name == "Alpha"
      assert shared.member_count == 3
      assert Enum.map(shared.candidates, & &1.user_id) == [ana.id, ken.id]

      assert hd(shared.candidates) == %{
               user_id: ana.id,
               name: "Ana",
               avatar_url: ana.avatar_url,
               member_since: ~D[2026-03-01]
             }
    end

    test "a board whose only other row is a pending invite is solo" do
      u = insert(:user)
      solo = solo(u)

      assert %{shared_boards: [], solo_boards: [%{slug: slug, name: "Solo"}]} = Accounts.deletion_preview(u)
      assert slug == solo.slug
    end

    test "a user with nothing to hand over gets the empty preview" do
      u = insert(:user)

      assert Accounts.deletion_preview(u) == %{
               shared_boards: [],
               solo_boards: [],
               plan_ends: false,
               runners: [],
               apple_reauth_required: false
             }
    end

    test "plan_ends is true for an active plan when billing is on" do
      Process.put(:billing_enabled, true)
      u = insert(:user)
      insert(:billing_account, user: u, paid_through: Date.add(Date.utc_today(), 10))

      assert Accounts.deletion_preview(u).plan_ends == true
    end

    test "plan_ends is false on Free when billing is on" do
      Process.put(:billing_enabled, true)
      u = insert(:user)
      insert(:billing_account, user: u)

      assert Accounts.deletion_preview(u).plan_ends == false
    end

    test "runners name the live-keyed machines on surviving boards only" do
      u = insert(:user)
      %{alpha: alpha} = alpha(u)
      solo = solo(u)
      %{bobs: bobs} = bobs(u)

      machine!(bobs, u, api_key_id: insert(:api_key, board: bobs).id, runner_name: "macbook-pro")
      machine!(alpha, u, api_key_id: insert(:api_key, board: alpha).id, runner_name: nil, host: "ci-box")
      machine!(solo, u, api_key_id: insert(:api_key, board: solo).id, runner_name: "solo-runner")
      machine!(alpha, u, api_key_id: nil, runner_name: "revoked-runner")

      assert Accounts.deletion_preview(u).runners == ["macbook-pro", "ci-box"]
    end

    test "an Apple account must re-authenticate" do
      u = insert(:user, provider: "apple")
      assert Accounts.deletion_preview(u).apple_reauth_required == true
    end
  end

  describe "delete_account/2 refusals" do
    defp assert_untouched(u, alpha, memberships) do
      reloaded = Repo.reload!(u)
      assert reloaded.deleted_at == nil
      assert reloaded.email == u.email
      assert Repo.reload!(alpha).owner_id == u.id
      assert count(Membership, u.id) == memberships
    end

    test "a shared board left unassigned is invalid_transfers and nothing changes" do
      u = insert(:user)
      %{alpha: alpha} = alpha(u)

      assert Accounts.delete_account(u, transfers: %{}) == {:error, :invalid_transfers}
      assert_untouched(u, alpha, 1)
    end

    test "a transfer to a non-member, to the user, or naming a foreign or solo slug is invalid_transfers" do
      u = insert(:user)
      %{alpha: alpha, ana: ana} = alpha(u)
      solo = solo(u)
      outsider = insert(:user)
      foreign = insert(:board, slug: slug("foreign"))

      for transfers <- [
            %{alpha.slug => outsider.id},
            %{alpha.slug => u.id},
            %{alpha.slug => ana.id, foreign.slug => ana.id},
            %{alpha.slug => ana.id, solo.slug => ana.id}
          ] do
        assert Accounts.delete_account(u, transfers: transfers) == {:error, :invalid_transfers}
        assert_untouched(u, alpha, 2)
        assert Repo.get(Board, solo.id)
      end
    end
  end

  describe "delete_account/2" do
    test "transfers shared boards, deletes solo ones, removes personal rows and tombstones the user" do
      u = insert(:user)
      %{alpha: alpha, ana: ana} = alpha(u)
      solo = solo(u)
      bobs(u)

      stage = insert(:stage, board: alpha)
      card = insert(:card, stage: stage)
      comment = insert(:comment, card: card, user: u)
      insert(:activity, card: card, user: u)
      vote = Repo.insert!(%Vote{card_id: card.id, user_id: u.id})
      insert(:card_owner, card: card, user: u)
      {:ok, _} = Accounts.create_user_api_token(u)
      {:ok, _} = Accounts.create_user_api_token(u)
      insert(:device_token, user: u)
      now = DateTime.truncate(DateTime.utc_now(), :second)
      Repo.insert!(%UsageVisit{user_id: u.id, started_at: now, last_at: now, seconds: 60})
      insert(:billing_account, user: u)
      insert(:oauth_grant, user: u)
      key = insert(:api_key, board: alpha)
      machine = machine!(alpha, u, api_key_id: key.id, runner_name: "laptop")

      assert Accounts.delete_account(u, transfers: %{alpha.slug => ana.id}) == :ok

      assert Repo.reload!(alpha).owner_id == ana.id
      assert Repo.reload(card)
      assert Repo.get(Board, solo.id) == nil

      tombstone = Repo.reload!(u)
      assert tombstone.name == "Deleted user"
      assert tombstone.avatar_url == nil
      assert tombstone.email == "deleted+#{u.id}@users.invalid"
      assert tombstone.provider_uid == nil
      assert tombstone.deleted_at

      assert Repo.preload(Repo.reload!(comment), :user).user.name == "Deleted user"
      assert Repo.reload(vote)

      for schema <- [Membership, CardOwner, UserApiToken, DeviceToken, UsageVisit, OAuthGrant] do
        assert count(schema, u.id) == 0, "#{inspect(schema)} rows remain"
      end

      assert Billing.get_account(u) == nil
      assert Repo.reload(key) == nil
      assert Repo.reload!(machine).api_key_id == nil
    end

    test "revokes the user's runner keys on boards they don't own, leaving others' keys" do
      u = insert(:user)
      %{alpha: alpha, ana: ana} = alpha(u)
      %{bobs: bobs} = bobs(u)

      {:ok, %{api_key: u_key, token: u_token}} = ApiKeys.create_key(bobs, u)
      machine!(bobs, u, api_key_id: u_key.id, runner_name: "laptop")
      {:ok, %{token: ana_token}} = ApiKeys.create_key(alpha, ana)

      assert :ok = Accounts.delete_account(u, transfers: %{alpha.slug => ana.id})

      assert ApiKeys.authenticate_key(u_token) == :error
      assert {:ok, _key} = ApiKeys.authenticate_key(ana_token)
    end

    test "broadcasts the new owner on transferred boards and the removal on every surviving board" do
      u = insert(:user)
      %{alpha: alpha, ana: ana} = alpha(u)
      %{bobs: bobs} = bobs(u)
      alpha_id = alpha.id
      ana_id = ana.id
      u_id = u.id

      Hamaca.Events.subscribe(alpha.id)
      Hamaca.Events.subscribe(bobs.id)

      assert :ok = Accounts.delete_account(u, transfers: %{alpha.slug => ana.id})

      assert_receive {:board_updated, %Board{id: ^alpha_id, owner_id: ^ana_id}}
      assert_receive {:member_removed, ^u_id}
      assert_receive {:member_removed, ^u_id}
    end

    test "a failed Stripe customer delete never rolls the deletion back" do
      Process.put(:billing_payments, Stripe)
      test = self()

      Req.Test.stub(Stripe, fn conn ->
        send(test, {:stripe_request, conn.method, conn.request_path})
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "boom"}})
      end)

      u = insert(:user)
      insert(:billing_account, user: u, stripe_customer_id: "cus_123")

      assert ExUnit.CaptureLog.capture_log(fn -> assert Accounts.delete_account(u) == :ok end) =~ "cus_123"

      assert Repo.reload!(u).deleted_at
      assert_received {:stripe_request, "DELETE", "/v1/customers/cus_123"}
    end

    test "signing in again with the old identity makes a fresh account" do
      u = insert(:user)
      card = insert(:card)
      comment = insert(:comment, card: card, user: u)

      assert :ok = Accounts.delete_account(u)

      assert {:ok, %User{} = new_user} =
               Accounts.upsert_user_from_provider(%{
                 provider: "google",
                 provider_uid: u.provider_uid,
                 email: u.email,
                 name: "Ann",
                 avatar_url: nil
               })

      assert new_user.id != u.id
      assert Repo.aggregate(from(b in Board, where: b.owner_id == ^new_user.id), :count) == 0
      assert Repo.preload(Repo.reload!(comment), :user).user.name == "Deleted user"
    end
  end

  describe "delete_account/2 for an Apple account" do
    # Apple failures log on purpose; capture it (shown only on a failure).
    @describetag :capture_log

    setup do
      put_apple_signin_config()
      %{a: insert(:user, provider: "apple", provider_uid: "apple-sub-1")}
    end

    # A's row, memberships, user API tokens and owned boards are as they were.
    defp assert_apple_untouched(a, boards, memberships, tokens) do
      reloaded = Repo.reload!(a)
      assert reloaded.deleted_at == nil
      assert reloaded.email == a.email
      assert reloaded.provider_uid == "apple-sub-1"
      assert count(Membership, a.id) == memberships
      assert count(UserApiToken, a.id) == tokens
      for board <- boards, do: assert(Repo.reload!(board).owner_id == a.id)
    end

    test "no authorization code is apple_reauth_required and nothing changes", %{a: a} do
      solo = solo(a)
      stub_apple_ok("apple-sub-1")

      assert Accounts.delete_account(a, transfers: %{}) == {:error, :apple_reauth_required}
      assert_apple_untouched(a, [solo], 1, 0)
      refute_received {:apple_request, _path, _form}
    end

    test "a blank authorization code is apple_reauth_required", %{a: a} do
      stub_apple_ok("apple-sub-1")

      assert Accounts.delete_account(a, apple_authorization_code: "  ") == {:error, :apple_reauth_required}
      refute_received {:apple_request, _path, _form}
    end

    test "a valid authorization code revokes the Apple grant once and deletes the account", %{a: a} do
      stub_apple_ok("apple-sub-1")

      assert Accounts.delete_account(a, apple_authorization_code: "code-1") == :ok

      assert Repo.reload!(a).deleted_at
      assert_received {:apple_request, "/auth/token", %{"code" => "code-1"}}
      assert_received {:apple_request, "/auth/revoke", _form}
      refute_received {:apple_request, "/auth/revoke", _form}
    end

    test "a refused exchange is apple_revoke_failed and nothing changes", %{a: a} do
      solo = solo(a)
      %{bobs: _bobs} = bobs(a)
      {:ok, _} = Accounts.create_user_api_token(a)
      stub_apple(%{"/auth/token" => {400, %{"error" => "invalid_grant"}}})

      assert Accounts.delete_account(a, apple_authorization_code: "code-1") == {:error, :apple_revoke_failed}
      assert_apple_untouched(a, [solo], 2, 1)
    end

    test "a code belonging to another Apple account is apple_mismatch and nothing changes", %{a: a} do
      solo = solo(a)
      {:ok, _} = Accounts.create_user_api_token(a)
      stub_apple_ok("someone-else")

      assert Accounts.delete_account(a, apple_authorization_code: "code-1") == {:error, :apple_mismatch}
      assert_apple_untouched(a, [solo], 1, 1)
      refute_received {:apple_request, "/auth/revoke", _form}
    end

    test "invalid transfers win over Apple and no Apple request is made", %{a: a} do
      %{alpha: alpha} = alpha(a)
      stub_apple_ok("apple-sub-1")

      assert Accounts.delete_account(a, transfers: %{}, apple_authorization_code: "code-1") ==
               {:error, :invalid_transfers}

      assert_apple_untouched(a, [alpha], 1, 0)
      refute_received {:apple_request, _path, _form}
    end

    test "allow_without_apple_revoke deletes with no code and no Apple request", %{a: a} do
      stub_apple_ok("apple-sub-1")

      assert Accounts.delete_account(a, allow_without_apple_revoke: true) == :ok
      assert Repo.reload!(a).deleted_at
      refute_received {:apple_request, _path, _form}
    end

    test "a Google account ignores the authorization code and makes no Apple request" do
      g = insert(:user, provider: "google")
      stub_apple_ok("apple-sub-1")

      assert Accounts.delete_account(g, apple_authorization_code: "ignored") == :ok
      assert Repo.reload!(g).deleted_at
      refute_received {:apple_request, _path, _form}
    end
  end
end
