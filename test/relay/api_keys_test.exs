defmodule Relay.ApiKeysTest do
  use Relay.DataCase, async: true

  alias Relay.ApiKeys
  alias Schemas.ApiKey

  describe "create_key/3" do
    test "creates the board's key and returns the raw token exactly once" do
      board = insert(:board)
      user = insert(:user)

      assert {:ok, %{api_key: %ApiKey{} = key, token: token}} = ApiKeys.create_key(board, user)

      assert token =~ ~r/^relay_[0-9a-f]{12}_[0-9a-f]{64}$/
      ["relay", prefix, secret] = String.split(token, "_", parts: 3)
      assert key.board_id == board.id
      assert key.created_by_id == user.id
      assert key.name == "Key 1"
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

    test "a board can hold several keys, each authenticating to that board" do
      board = insert(:board)
      user = insert(:user)

      {:ok, %{api_key: a, token: token_a}} = ApiKeys.create_key(board, user, "Laptop")
      {:ok, %{api_key: b, token: token_b}} = ApiKeys.create_key(board, user, "Mac mini")

      refute a.id == b.id
      assert Repo.aggregate(ApiKey, :count) == 2
      assert {:ok, %{id: id_a}} = ApiKeys.authenticate(token_a)
      assert {:ok, %{id: id_b}} = ApiKeys.authenticate(token_b)
      assert id_a == board.id
      assert id_b == board.id
    end

    test "revoking one key leaves the board's other keys working" do
      board = insert(:board)
      user = insert(:user)
      {:ok, %{api_key: a, token: token_a}} = ApiKeys.create_key(board, user)
      {:ok, %{token: token_b}} = ApiKeys.create_key(board, user)

      {:ok, _revoked} = ApiKeys.revoke(a)

      assert :error = ApiKeys.authenticate(token_a)
      assert {:ok, _board} = ApiKeys.authenticate(token_b)
    end

    test "keeps a custom name, trimmed" do
      {:ok, %{api_key: key}} = ApiKeys.create_key(insert(:board), insert(:user), "  Mac mini  ")
      assert key.name == "Mac mini"
    end

    test "a nil, blank, or whitespace-only name falls back to Key N (board's count + 1)" do
      board = insert(:board)
      user = insert(:user)
      # another board's keys don't count toward this board's N
      {:ok, _other} = ApiKeys.create_key(insert(:board), user)

      {:ok, %{api_key: first}} = ApiKeys.create_key(board, user)
      {:ok, %{api_key: second}} = ApiKeys.create_key(board, user, "")
      {:ok, %{api_key: third}} = ApiKeys.create_key(board, user, "   ")

      assert first.name == "Key 1"
      assert second.name == "Key 2"
      assert third.name == "Key 3"
    end

    test "a name over the max length is an error changeset and inserts nothing" do
      too_long = String.duplicate("x", ApiKey.name_max_length() + 1)

      assert {:error, %Ecto.Changeset{} = changeset} =
               ApiKeys.create_key(insert(:board), insert(:user), too_long)

      assert %{name: [_msg]} = errors_on(changeset)
      assert Repo.aggregate(ApiKey, :count) == 0
    end
  end

  describe "list_keys/1" do
    test "returns the board's keys oldest first, and only that board's" do
      board = insert(:board)
      assert ApiKeys.list_keys(board) == []

      user = insert(:user)
      {:ok, %{api_key: a}} = ApiKeys.create_key(board, user, "A")
      {:ok, %{api_key: b}} = ApiKeys.create_key(board, user, "B")
      {:ok, _other} = ApiKeys.create_key(insert(:board), user, "Other")

      assert Enum.map(ApiKeys.list_keys(board), & &1.id) == [a.id, b.id]
    end
  end

  describe "get_key!/2" do
    test "fetches a key scoped to its board (string or integer id)" do
      board = insert(:board)
      {:ok, %{api_key: key}} = ApiKeys.create_key(board, insert(:user))

      assert ApiKeys.get_key!(board, key.id).id == key.id
      assert ApiKeys.get_key!(board, to_string(key.id)).id == key.id
    end

    test "raises for another board's key" do
      {:ok, %{api_key: foreign}} = ApiKeys.create_key(insert(:board), insert(:user))

      assert_raise Ecto.NoResultsError, fn -> ApiKeys.get_key!(insert(:board), foreign.id) end
    end
  end

  describe "rename/2" do
    test "renames the key (trimmed) and leaves its token working" do
      board = insert(:board)
      {:ok, %{api_key: key, token: token}} = ApiKeys.create_key(board, insert(:user))

      assert {:ok, renamed} = ApiKeys.rename(key, "  Laptop ")
      assert renamed.name == "Laptop"
      assert Repo.get!(ApiKey, key.id).name == "Laptop"
      assert {:ok, _board} = ApiKeys.authenticate(token)
    end

    test "rejects a blank or too-long name" do
      {:ok, %{api_key: key}} = ApiKeys.create_key(insert(:board), insert(:user), "Keep")

      assert {:error, %Ecto.Changeset{} = blank} = ApiKeys.rename(key, "   ")
      assert %{name: ["can't be blank"]} = errors_on(blank)

      too_long = String.duplicate("x", ApiKey.name_max_length() + 1)
      assert {:error, %Ecto.Changeset{} = long} = ApiKeys.rename(key, too_long)
      assert %{name: [_msg]} = errors_on(long)

      assert Repo.get!(ApiKey, key.id).name == "Keep"
    end
  end

  describe "authenticate/1" do
    test "returns the key's board for a valid raw token and bumps last_used_at" do
      board = insert(:board)
      {:ok, %{token: token}} = ApiKeys.create_key(board, insert(:user))

      assert {:ok, authed_board} = ApiKeys.authenticate(token)
      assert authed_board.id == board.id
      assert %DateTime{} = only_key(board).last_used_at
    end

    test "rejects a token with a known prefix but the wrong secret" do
      board = insert(:board)
      {:ok, %{api_key: key}} = ApiKeys.create_key(board, insert(:user))

      forged = "relay_#{key.token_prefix}_#{String.duplicate("0", 64)}"
      assert :error = ApiKeys.authenticate(forged)
      assert only_key(board).last_used_at == nil
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

  describe "authenticate/1 last_used_at throttling" do
    test "writes last_used_at when it was never set" do
      board = insert(:board)
      {:ok, %{token: token}} = ApiKeys.create_key(board, insert(:user))

      assert {:ok, _board} = ApiKeys.authenticate(token)
      assert %DateTime{} = only_key(board).last_used_at
    end

    test "skips the write when last_used_at is recent" do
      board = insert(:board)
      {:ok, %{api_key: key, token: token}} = ApiKeys.create_key(board, insert(:user))

      # 5s ago: inside the 60s throttle window, but far enough from "now" that
      # this can't accidentally match an unthrottled write's timestamp.
      recent = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:second)
      key |> Ecto.Changeset.change(last_used_at: recent) |> Repo.update!()

      assert {:ok, _board} = ApiKeys.authenticate(token)
      assert only_key(board).last_used_at == recent
    end

    test "writes last_used_at when the stored value is stale" do
      board = insert(:board)
      {:ok, %{api_key: key, token: token}} = ApiKeys.create_key(board, insert(:user))

      stale =
        DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      key |> Ecto.Changeset.change(last_used_at: stale) |> Repo.update!()

      assert {:ok, _board} = ApiKeys.authenticate(token)
      assert DateTime.after?(only_key(board).last_used_at, stale)
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
      assert ApiKeys.list_keys(board) == []
      assert Repo.aggregate(ApiKey, :count) == 0
    end
  end

  defp only_key(board) do
    [key] = ApiKeys.list_keys(board)
    key
  end
end
