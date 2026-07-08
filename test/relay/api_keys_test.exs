defmodule Relay.ApiKeysTest do
  use Relay.DataCase, async: true

  alias Relay.ApiKeys
  alias Schemas.ApiKey

  describe "create_key/2" do
    test "creates the board's key and returns the raw token exactly once" do
      board = insert(:board)
      user = insert(:user)

      assert {:ok, %{api_key: %ApiKey{} = key, token: token}} = ApiKeys.create_key(board, user)

      assert token =~ ~r/^relay_[0-9a-f]{12}_[0-9a-f]{64}$/
      ["relay", prefix, secret] = String.split(token, "_", parts: 3)
      assert key.board_id == board.id
      assert key.created_by_id == user.id
      assert key.name == "Board API key"
      assert key.token_prefix == prefix
      assert key.last_four == String.slice(secret, -4, 4)
      assert key.last_used_at == nil
    end

    test "stores only a SHA-256 hash — the raw secret is never persisted" do
      {:ok, %{api_key: key, token: token}} = ApiKeys.create_key(insert(:board), insert(:user))
      ["relay", _prefix, secret] = String.split(token, "_", parts: 3)

      reloaded = Repo.get!(ApiKey, key.id)
      assert reloaded.token_hash == Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
      refute inspect(Map.from_struct(reloaded)) =~ secret
    end

    test "errors when the board already has a key (single-key invariant)" do
      board = insert(:board)
      user = insert(:user)
      {:ok, _created} = ApiKeys.create_key(board, user)

      assert {:error, :already_exists} = ApiKeys.create_key(board, user)
      assert Repo.aggregate(ApiKey, :count) == 1
    end
  end

  describe "get_key/1" do
    test "returns the board's key, or nil when none exists" do
      board = insert(:board)
      assert ApiKeys.get_key(board) == nil

      {:ok, %{api_key: key}} = ApiKeys.create_key(board, insert(:user))

      assert ApiKeys.get_key(board).id == key.id
      assert ApiKeys.get_key(insert(:board)) == nil
    end
  end

  describe "authenticate/1" do
    test "returns the key's board for a valid raw token and bumps last_used_at" do
      board = insert(:board)
      {:ok, %{token: token}} = ApiKeys.create_key(board, insert(:user))

      assert {:ok, authed_board} = ApiKeys.authenticate(token)
      assert authed_board.id == board.id
      assert %DateTime{} = ApiKeys.get_key(board).last_used_at
    end

    test "rejects a token with a known prefix but the wrong secret" do
      board = insert(:board)
      {:ok, %{api_key: key}} = ApiKeys.create_key(board, insert(:user))

      forged = "relay_#{key.token_prefix}_#{String.duplicate("0", 64)}"
      assert :error = ApiKeys.authenticate(forged)
      assert ApiKeys.get_key(board).last_used_at == nil
    end

    test "rejects unknown prefixes and malformed tokens" do
      assert :error = ApiKeys.authenticate("relay_deadbeef0000_" <> String.duplicate("a", 64))
      assert :error = ApiKeys.authenticate("not-a-token")
      assert :error = ApiKeys.authenticate("relay_missingsecret")
      assert :error = ApiKeys.authenticate("")
    end

    test "rejects a revoked key's token" do
      {:ok, %{api_key: key, token: token}} = ApiKeys.create_key(insert(:board), insert(:user))
      {:ok, _revoked} = ApiKeys.revoke(key)

      assert :error = ApiKeys.authenticate(token)
    end
  end

  describe "regenerate/1" do
    test "replaces the secret on the same row; the old token stops authenticating" do
      board = insert(:board)
      {:ok, %{api_key: key, token: old_token}} = ApiKeys.create_key(board, insert(:user))

      assert {:ok, %{api_key: new_key, token: new_token}} = ApiKeys.regenerate(key)

      assert new_key.id == key.id
      refute new_token == old_token
      refute new_key.token_prefix == key.token_prefix
      assert :error = ApiKeys.authenticate(old_token)
      assert {:ok, authed_board} = ApiKeys.authenticate(new_token)
      assert authed_board.id == board.id
      assert Repo.aggregate(ApiKey, :count) == 1
    end

    test "resets last_used_at" do
      {:ok, %{api_key: key, token: token}} = ApiKeys.create_key(insert(:board), insert(:user))
      {:ok, _board} = ApiKeys.authenticate(token)
      key = Repo.get!(ApiKey, key.id)
      assert key.last_used_at

      {:ok, %{api_key: new_key}} = ApiKeys.regenerate(key)
      assert new_key.last_used_at == nil
    end
  end

  describe "revoke/1" do
    test "deletes the key" do
      board = insert(:board)
      {:ok, %{api_key: key}} = ApiKeys.create_key(board, insert(:user))

      assert {:ok, %ApiKey{}} = ApiKeys.revoke(key)
      assert ApiKeys.get_key(board) == nil
      assert Repo.aggregate(ApiKey, :count) == 0
    end
  end
end
