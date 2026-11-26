defmodule Hamaca.AppleRevokeFixtures do
  @moduledoc """
  RE509 test fixtures for revoking Sign in with Apple tokens at account deletion: an ES256
  (P-256) signing key put as the process's Apple signing config, a `Req.Test` stub standing in
  for Apple's `/auth/token` and `/auth/revoke`, and `id_token`s carrying a chosen `sub`. Shared
  by the `Hamaca.Accounts.AppleRevoker.Apple` and `Hamaca.Accounts.Deletion` tests, so no real
  Apple contact happens in the suite. Boundary checks are off — test-only support.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  @stub Hamaca.Accounts.AppleRevoker.Apple

  @doc """
  Generates a P-256 key and `Process.put`s the Apple signing config every scenario starts
  from: team `TEAM123`, key id `KEY123`, the key's PEM and client id `app.hamaca.Hamaca`.
  Returns the key, whose public half verifies the client secret.
  """
  @spec put_apple_signin_config() :: JOSE.JWK.t()
  def put_apple_signin_config do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    {_meta, pem} = JOSE.JWK.to_pem(jwk)

    Process.put(:apple_team_id, "TEAM123")
    Process.put(:apple_signin_key_id, "KEY123")
    Process.put(:apple_signin_private_key, pem)
    Process.put(:apple_signin_client_id, "app.hamaca.Hamaca")
    jwk
  end

  @doc "A compact JWT standing in for Apple's `id_token`, with `sub` (read unverified, by peeking)."
  @spec id_token(String.t()) :: String.t()
  def id_token(sub) do
    {_meta, token} =
      {:ec, "P-256"}
      |> JOSE.JWK.generate_key()
      |> JOSE.JWT.sign(%{"alg" => "ES256"}, %{"iss" => "https://appleid.apple.com", "sub" => sub})
      |> JOSE.JWS.compact()

    token
  end

  @doc "A successful `/auth/token` body for `sub`; `overrides` replace keys, `:delete` drops one."
  @spec token_body(String.t(), map()) :: map()
  def token_body(sub, overrides \\ %{}) do
    defaults = %{"refresh_token" => "r1", "access_token" => "a1", "id_token" => id_token(sub)}

    Enum.reduce(overrides, defaults, fn
      {key, :delete}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  @doc """
  Stubs Apple: each request sends `{:apple_request, path, form}` to the calling test process
  and is answered from `responses`, a map of path → `{status, json_body}`. A path not in it
  answers 404.
  """
  @spec stub_apple(%{optional(String.t()) => {pos_integer(), map()}}) :: :ok
  def stub_apple(responses) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:apple_request, conn.request_path, URI.decode_query(body)})
      {status, json} = Map.get(responses, conn.request_path, {404, %{"error" => "not_found"}})
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(json)
    end)
  end

  @doc "Stubs Apple so the token exchange for `sub` and the revoke both succeed."
  @spec stub_apple_ok(String.t()) :: :ok
  def stub_apple_ok(sub), do: stub_apple(%{"/auth/token" => {200, token_body(sub)}, "/auth/revoke" => {200, %{}}})
end
