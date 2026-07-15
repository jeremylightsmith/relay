defmodule RelayWeb.NativeAuthController do
  @moduledoc """
  Native (Flutter) sign-in: exchanges a provider ID token for a Phoenix
  session and returns JSON. The response carries the `Set-Cookie: _relay_key=…`
  header the native shell injects into its embedded webviews. This IS the login,
  so it is unauthenticated (runs under the `:native_auth` pipeline, which fetches
  the session so the cookie can be written).
  """

  use RelayWeb, :controller

  alias Relay.Accounts
  alias Relay.Accounts.GoogleTokenValidator
  alias RelayWeb.Auth

  def google(conn, %{"id_token" => id_token}) do
    with {:ok, claims} <- GoogleTokenValidator.validate_token(id_token),
         {:ok, user} <- Accounts.upsert_user_from_provider(claims),
         {:ok, token} <- mint_token(user) do
      conn
      |> Auth.put_user_session(user)
      |> put_status(:ok)
      |> json(%{success: true, user: user_json(user), token: token})
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{success: false, error: "Could not save user", details: translate_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{success: false, error: "Invalid token", reason: reason})
    end
  end

  def google(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{success: false, error: "Missing id_token parameter"})
  end

  @doc """
  Session verify for the native shell. The app restores its persisted `_relay_key`
  cookie on launch and calls this to learn whether it is still good (RLY-86 §5) —
  a round-trip that turns a stale credential into a clean sign-out instead of a
  mysterious 401 deep inside a webview.
  """
  def me(conn, _params) do
    case conn |> get_session(:user_id) |> fetch_user() do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{success: false, error: "Not signed in"})

      user ->
        case mint_token(user) do
          {:ok, token} ->
            json(conn, %{success: true, user: user_json(user), token: token})

          {:error, _} ->
            conn |> put_status(:internal_server_error) |> json(%{success: false, error: "Could not mint a token"})
        end
    end
  end

  defp fetch_user(nil), do: nil
  defp fetch_user(user_id), do: Accounts.get_user(user_id)

  # The bearer for the `/api/all/*` scope. Minted on both sign-in and session
  # verify: `/api/all/*` is bearer-only, the raw token is unrecoverable once
  # returned, and RLY-86 persists only the session cookie — so a restored launch
  # has to get a fresh one here or the inbox cannot load. Fresh token per call,
  # which is fine: a user may hold several (one per signed-in device).
  defp mint_token(user) do
    with {:ok, %{token: raw}} <- Accounts.create_user_api_token(user) do
      {:ok, raw}
    end
  end

  # Shared with google/2 so the two responses cannot drift.
  defp user_json(user), do: %{id: user.id, name: user.name, email: user.email}

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
