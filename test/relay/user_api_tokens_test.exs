defmodule Relay.UserApiTokensTest do
  use Relay.DataCase, async: true

  alias Relay.Accounts
  alias Schemas.UserApiToken

  test "create_user_api_token returns a raw token that authenticates the user" do
    user = insert(:user)

    assert {:ok, %{user_api_token: %UserApiToken{} = record, token: token}} =
             Accounts.create_user_api_token(user)

    assert token =~ ~r/^relayu_[0-9a-f]{12}_[0-9a-f]{64}$/
    assert record.context == "mobile"
    assert {:ok, authenticated} = Accounts.authenticate_user_api_token(token)
    assert authenticated.id == user.id
  end

  test "stores only a SHA-256 hash — the raw secret is never persisted" do
    {:ok, %{user_api_token: record, token: token}} = Accounts.create_user_api_token(insert(:user))
    ["relayu", prefix, secret] = String.split(token, "_", parts: 3)

    reloaded = Repo.get!(UserApiToken, record.id)

    assert reloaded.token_prefix == prefix
    assert reloaded.token_hash == Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
    assert reloaded.last_four == String.slice(secret, -4, 4)
    refute inspect(Map.from_struct(reloaded)) =~ secret
  end

  test "a user may hold several tokens (one per device)" do
    user = insert(:user)
    {:ok, %{token: first}} = Accounts.create_user_api_token(user)
    {:ok, %{token: second}} = Accounts.create_user_api_token(user)

    refute first == second
    assert {:ok, _} = Accounts.authenticate_user_api_token(first)
    assert {:ok, _} = Accounts.authenticate_user_api_token(second)
  end

  test "malformed, unknown, and revoked tokens fail" do
    {:ok, %{user_api_token: record, token: token}} = Accounts.create_user_api_token(insert(:user))

    assert :error = Accounts.authenticate_user_api_token("garbage")
    assert :error = Accounts.authenticate_user_api_token("relayu_deadbeef_nope")

    assert {:ok, _} = Accounts.revoke_user_api_token(record)
    assert :error = Accounts.authenticate_user_api_token(token)
  end

  test "user tokens and board keys can never authenticate as each other" do
    user = insert(:user)
    {:ok, %{token: user_token}} = Accounts.create_user_api_token(user)
    {:ok, %{token: board_token}} = Relay.ApiKeys.create_key(insert(:board), user)

    assert :error = Accounts.authenticate_user_api_token(board_token)
    assert :error = Relay.ApiKeys.authenticate(user_token)
  end

  describe "authenticate_user_api_token/1 last_used_at throttling" do
    test "writes last_used_at when it was never set" do
      {:ok, %{user_api_token: record, token: token}} = Accounts.create_user_api_token(insert(:user))
      assert record.last_used_at == nil

      assert {:ok, _user} = Accounts.authenticate_user_api_token(token)
      assert %DateTime{} = Repo.get!(UserApiToken, record.id).last_used_at
    end

    test "skips the write when last_used_at is recent" do
      {:ok, %{user_api_token: record, token: token}} = Accounts.create_user_api_token(insert(:user))

      # 5s ago: inside the 60s throttle window, but far enough from "now" that
      # this can't accidentally match an unthrottled write's timestamp.
      recent = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:second)
      record |> Ecto.Changeset.change(last_used_at: recent) |> Repo.update!()

      assert {:ok, _user} = Accounts.authenticate_user_api_token(token)
      assert Repo.get!(UserApiToken, record.id).last_used_at == recent
    end

    test "writes last_used_at when the stored value is stale" do
      {:ok, %{user_api_token: record, token: token}} = Accounts.create_user_api_token(insert(:user))

      stale = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)
      record |> Ecto.Changeset.change(last_used_at: stale) |> Repo.update!()

      assert {:ok, _user} = Accounts.authenticate_user_api_token(token)
      assert DateTime.after?(Repo.get!(UserApiToken, record.id).last_used_at, stale)
    end
  end
end
