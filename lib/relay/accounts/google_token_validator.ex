defmodule Relay.Accounts.GoogleTokenValidator do
  @moduledoc """
  Validates a Google ID token from native sign-in and returns normalized
  provider claims for `Relay.Accounts.upsert_user_from_provider/1`.

  Calls Google's `tokeninfo` endpoint with `Req` (the app's first `Req` use).
  Tests inject a `Req.Test` stub via `:google_tokeninfo_req_options`, so no
  real Google contact happens in the suite. Stricter than the `../rotation`
  template: an audience outside the configured allowlist is rejected, and
  `email_verified` is required (email is our identity signal).

  Belongs to the `Relay.Accounts` boundary (no own `use Boundary`); it is
  exported from Accounts so `RelayWeb` may call it.
  """

  require Logger

  @issuers ["accounts.google.com", "https://accounts.google.com"]

  @doc """
  Validates `id_token`. Returns `{:ok, claims}` with a
  `%{provider:, provider_uid:, email:, name:, avatar_url:}` map, or
  `{:error, reason}` where reason is one of `:invalid_token`,
  `:invalid_audience`, `:invalid_issuer`, `:email_unverified`, `:network_error`.
  """
  def validate_token(id_token) when is_binary(id_token) do
    with {:ok, info} <- fetch_token_info(id_token),
         :ok <- verify_audience(info),
         :ok <- verify_issuer(info),
         :ok <- verify_email_verified(info) do
      {:ok,
       %{
         provider: "google",
         provider_uid: info["sub"],
         email: info["email"],
         name: info["name"],
         avatar_url: info["picture"]
       }}
    end
  end

  defp fetch_token_info(id_token) do
    case Req.get(req(), url: "/tokeninfo", params: [id_token: id_token]) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Google tokeninfo failed: #{status} #{inspect(body)}")
        {:error, :invalid_token}

      {:error, reason} ->
        Logger.error("Google tokeninfo request error: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  defp req do
    [base_url: "https://oauth2.googleapis.com", retry: false]
    |> Keyword.merge(Application.get_env(:relay, :google_tokeninfo_req_options, []))
    |> Req.new()
  end

  defp verify_audience(%{"aud" => aud}) do
    if aud in allowed_audiences(), do: :ok, else: {:error, :invalid_audience}
  end

  defp verify_audience(_), do: {:error, :invalid_audience}

  defp allowed_audiences do
    Enum.reject(
      [Application.get_env(:relay, :google_client_id), Application.get_env(:relay, :google_ios_client_id)],
      &is_nil/1
    )
  end

  defp verify_issuer(%{"iss" => iss}) when iss in @issuers, do: :ok
  defp verify_issuer(_), do: {:error, :invalid_issuer}

  defp verify_email_verified(%{"email_verified" => verified}) when verified in [true, "true"], do: :ok

  defp verify_email_verified(_), do: {:error, :email_unverified}
end
