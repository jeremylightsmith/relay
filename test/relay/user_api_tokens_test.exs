defmodule Relay.UserApiTokensTest do
  use Relay.DataCase, async: true

  alias Relay.Accounts
  alias Schemas.UserApiToken

  test "create_user_api_token returns a raw token that authenticates the user" do
    user = insert(:user)

    assert {:ok, %{user_api_token: %UserApiToken{} = record, token: token}} =
             Accounts.create_user_api_token(user)

    assert String.starts_with?(token, "relayu_")
    assert record.context == "mobile"
    assert {:ok, authenticated} = Accounts.authenticate_user_api_token(token)
    assert authenticated.id == user.id
  end

  test "the raw secret is never persisted" do
    {:ok, %{user_api_token: record, token: token}} = Accounts.create_user_api_token(insert(:user))
    ["relayu", prefix, secret] = String.split(token, "_", parts: 3)

    assert record.token_prefix == prefix
    refute record.token_hash == secret
    assert record.last_four == String.slice(secret, -4, 4)
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
end
