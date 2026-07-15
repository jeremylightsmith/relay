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
         {:ok, user} <- Accounts.upsert_user_from_provider(claims) do
      conn
      |> Auth.put_user_session(user)
      |> put_status(:ok)
      |> json(%{success: true, user: user_json(user)})
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
        json(conn, %{success: true, user: user_json(user)})
    end
  end

  defp fetch_user(nil), do: nil
  defp fetch_user(user_id), do: Accounts.get_user(user_id)

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
