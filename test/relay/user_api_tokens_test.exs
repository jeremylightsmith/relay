defmodule Relay.UserApiTokensTest do
  use Relay.DataCase, async: true

  import Ecto.Query

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

  test "rejects a token with a known prefix but the wrong secret" do
    user = insert(:user)
    {:ok, %{user_api_token: record}} = Accounts.create_user_api_token(user)

    forged = "relayu_#{record.token_prefix}_#{String.duplicate("0", 64)}"
    assert :error = Accounts.authenticate_user_api_token(forged)
    assert Repo.get!(UserApiToken, record.id).last_used_at == nil
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

  describe "minting does not accumulate rows without bound" do
    # The native app does not persist its bearer (it follows the session), so
    # BOTH sign-in and every session verify mint one — i.e. one row per app
    # launch, forever, and nothing prunes them. The raw token is unrecoverable
    # by design, so reusing an existing row is impossible; the only lever is to
    # drop the ones that can no longer be in use.
    test "keeps a bounded number of tokens per user and context" do
      user = insert(:user)

      for _ <- 1..(Accounts.max_user_api_tokens() + 5) do
        {:ok, _} = Accounts.create_user_api_token(user)
      end

      kept = Repo.all(from t in UserApiToken, where: t.user_id == ^user.id)
      assert length(kept) == Accounts.max_user_api_tokens()
    end

    test "the newest token still authenticates after pruning" do
      user = insert(:user)

      for _ <- 1..(Accounts.max_user_api_tokens() + 3) do
        {:ok, _} = Accounts.create_user_api_token(user)
      end

      {:ok, %{token: newest}} = Accounts.create_user_api_token(user)

      # Pruning must never evict the token we just handed the caller.
      assert {:ok, authenticated} = Accounts.authenticate_user_api_token(newest)
      assert authenticated.id == user.id
    end

    test "a recently-used sibling device is not evicted by another launch" do
      user = insert(:user)
      {:ok, %{token: device_a}} = Accounts.create_user_api_token(user)

      # Device A is live: authenticating touches last_used_at.
      {:ok, _} = Accounts.authenticate_user_api_token(device_a)

      # Device B launches repeatedly, minting a token each time.
      for _ <- 1..(Accounts.max_user_api_tokens() - 1) do
        {:ok, _} = Accounts.create_user_api_token(user)
      end

      assert {:ok, _} = Accounts.authenticate_user_api_token(device_a)
    end

    test "another user's tokens are untouched" do
      mine = insert(:user)
      theirs = insert(:user)
      {:ok, %{token: their_token}} = Accounts.create_user_api_token(theirs)

      for _ <- 1..(Accounts.max_user_api_tokens() + 2) do
        {:ok, _} = Accounts.create_user_api_token(mine)
      end

      assert {:ok, _} = Accounts.authenticate_user_api_token(their_token)
    end
  end
end
