defmodule Hamaca.Accounts.AppleRevoker.Apple do
  @moduledoc """
  `Hamaca.Accounts.AppleRevoker` over Apple's REST API (RE509).

  Signs a short-lived ES256 client secret with the Sign in with Apple key, exchanges the
  authorization code at `POST /auth/token`, checks the returned `id_token`'s `sub` is the
  account's (peeked, not verified: it came straight from Apple over TLS in answer to our
  authenticated request), then revokes the refresh token — or the access token when Apple sent
  none — at `POST /auth/revoke`. Both calls are form-encoded; Apple rejects JSON bodies.

  Configured through `Hamaca.Config`: `:apple_team_id`, `:apple_signin_key_id`,
  `:apple_signin_private_key` (the `.p8` PEM; literal `\\n` sequences become newlines, so it
  fits a one-line secret) and `:apple_signin_client_id` (the first `:apple_client_ids` entry by
  default). Missing config **fails closed** — `{:error, :apple_revoke_failed}` with no HTTP
  call — as does every other failure, each logged. Tests inject a `Req.Test` stub via
  `:apple_revoke_req_options`, so no real Apple contact happens in the suite.

  Belongs to the `Hamaca.Accounts` boundary (no own `use Boundary`).
  """

  @behaviour Hamaca.Accounts.AppleRevoker

  require Logger

  @apple "https://appleid.apple.com"
  @client_secret_ttl_seconds 300

  @impl true
  def revoke(authorization_code, expected_sub) when is_binary(authorization_code) and is_binary(expected_sub) do
    with {:ok, config} <- config(),
         {:ok, client_secret} <- client_secret(config),
         {:ok, tokens} <- exchange(config.client_id, client_secret, authorization_code),
         :ok <- check_sub(tokens.id_token, expected_sub) do
      revoke_token(config.client_id, client_secret, tokens.revocable)
    end
  end

  defp config do
    config = %{
      team_id: setting(:apple_team_id),
      key_id: setting(:apple_signin_key_id),
      private_key: setting(:apple_signin_private_key),
      client_id: setting(:apple_signin_client_id) || present(List.first(Hamaca.Config.get(:apple_client_ids, [])))
    }

    case for({name, nil} <- config, do: name) do
      [] ->
        {:ok, config}

      missing ->
        Logger.error("Apple token revoke is not configured: missing #{Enum.map_join(missing, ", ", &inspect/1)}")
        {:error, :apple_revoke_failed}
    end
  end

  # `nil`, `false` (Hamaca.Config's "explicitly unset") and blank all read as missing.
  defp setting(key), do: present(Hamaca.Config.get(key))

  defp present(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp present(_value), do: nil

  defp client_secret(config) do
    now = System.os_time(:second)

    claims = %{
      "iss" => config.team_id,
      "iat" => now,
      "exp" => now + @client_secret_ttl_seconds,
      "aud" => @apple,
      "sub" => config.client_id
    }

    {_meta, secret} =
      config.private_key
      |> String.replace("\\n", "\n")
      |> JOSE.JWK.from_pem()
      |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => config.key_id}, claims)
      |> JOSE.JWS.compact()

    {:ok, secret}
  rescue
    error ->
      Logger.error("Apple token revoke: the Sign in with Apple private key is unusable: #{Exception.message(error)}")
      {:error, :apple_revoke_failed}
  end

  defp exchange(client_id, client_secret, code) do
    form = [client_id: client_id, client_secret: client_secret, code: code, grant_type: "authorization_code"]

    with {:ok, body} <- post("/auth/token", form) do
      case body do
        %{"id_token" => id_token, "refresh_token" => token} when is_binary(id_token) and is_binary(token) ->
          {:ok, %{id_token: id_token, revocable: {token, "refresh_token"}}}

        %{"id_token" => id_token, "access_token" => token} when is_binary(id_token) and is_binary(token) ->
          {:ok, %{id_token: id_token, revocable: {token, "access_token"}}}

        _body ->
          Logger.error("Apple token exchange returned no id_token or no token to revoke")
          {:error, :apple_revoke_failed}
      end
    end
  end

  defp check_sub(id_token, expected_sub) do
    case JOSE.JWT.peek_payload(id_token) do
      %JOSE.JWT{fields: %{"sub" => ^expected_sub}} ->
        :ok

      _jwt ->
        Logger.error("Apple token revoke: the authorization code belongs to another Apple account")
        {:error, :apple_mismatch}
    end
  rescue
    error ->
      Logger.error("Apple token revoke: unreadable id_token: #{Exception.message(error)}")
      {:error, :apple_revoke_failed}
  end

  defp revoke_token(client_id, client_secret, {token, token_type_hint}) do
    form = [client_id: client_id, client_secret: client_secret, token: token, token_type_hint: token_type_hint]

    with {:ok, _body} <- post("/auth/revoke", form), do: :ok
  end

  defp post(path, form) do
    case Req.post(req(), url: path, form: form) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Apple #{path} failed: #{status} #{inspect(body)}")
        {:error, :apple_revoke_failed}

      {:error, reason} ->
        Logger.error("Apple #{path} request error: #{inspect(reason)}")
        {:error, :apple_revoke_failed}
    end
  end

  defp req do
    [base_url: @apple, retry: false]
    |> Keyword.merge(Application.get_env(:hamaca, :apple_revoke_req_options, []))
    |> Req.new()
  end
end
