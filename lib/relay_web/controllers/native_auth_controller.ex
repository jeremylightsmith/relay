defmodule RelayWeb.NativeAuthController do
  @moduledoc """
  Native (Flutter) sign-in: exchanges a provider ID token (Google, or an Apple
  identity token plus its raw nonce) for a Phoenix session and returns JSON. The response carries the `Set-Cookie: _relay_key=…`
  header the native shell injects into its embedded webviews. This IS the login,
  so it is unauthenticated (runs under the `:native_auth` pipeline, which fetches
  the session so the cookie can be written).
  """

  use RelayWeb, :controller

  alias Relay.Accounts
  alias Relay.Accounts.AppleTokenValidator
  alias Relay.Accounts.GoogleTokenValidator
  alias RelayWeb.Auth

  def google(conn, %{"id_token" => id_token}) do
    sign_in(conn, GoogleTokenValidator.validate_token(id_token), [])
  end

  def google(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{success: false, error: "Missing id_token parameter"})
  end

  @doc """
  Sign in with Apple (RE106). Takes the identity token and the **raw** nonce whose
  SHA-256 the app handed Apple. Apple sends the user's name only on the first
  authorization, and only to the app, so the app forwards `given_name` /
  `family_name`; the joined name is used only when a new user is created.
  """
  def apple(conn, %{"identity_token" => identity_token, "nonce" => nonce} = params)
      when is_binary(identity_token) and is_binary(nonce) do
    sign_in(conn, AppleTokenValidator.validate_token(identity_token, nonce),
      name: display_name(params["given_name"], params["family_name"])
    )
  end

  def apple(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{success: false, error: "Missing identity_token parameter"})
  end

  # The post-validation tail shared by every provider, so their responses cannot drift.
  defp sign_in(conn, validated, upsert_opts) do
    with {:ok, claims} <- validated,
         {:ok, user} <- Accounts.upsert_user_from_provider(claims, upsert_opts),
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

  defp display_name(given, family) do
    case String.trim("#{name_part(given)} #{name_part(family)}") do
      "" -> nil
      name -> name
    end
  end

  defp name_part(part) when is_binary(part), do: part
  defp name_part(_part), do: ""

  @doc """
  Session verify for the native shell. The app restores its persisted `_relay_key`
  cookie on launch and calls this to learn whether it is still good (RLY-86 §5) —
  a round-trip that turns a stale credential into a clean sign-out instead of a
  mysterious 401 deep inside a webview.
  """
  def me(conn, _params) do
    session = get_session(conn)

    # A cookie stamped past the 7-day window must not mint a token here — this is
    # the only server-side check that ever runs for a replayed native cookie, and
    # `mint_token/1` hands back a bearer that outlives the session it came from
    # (RLY-127). Checked before user lookup so an expired cookie takes the same
    # clean-sign-out 401 path as a missing/gone session.
    with true <- fresh_session?(session),
         user when not is_nil(user) <- fetch_user(session["user_id"]),
         {:ok, token} <- mint_token(user) do
      # The native shell's launch-time verify is its only touch point, so this is
      # where its 7-day window slides forward (RLY-127). Without it a native
      # session would quietly age out while the shell still believed it was
      # signed in, and the embedded webview would bounce to sign-in.
      conn
      |> Auth.refresh_session()
      |> json(%{success: true, user: user_json(user), token: token})
    else
      {:error, _} ->
        conn |> put_status(:internal_server_error) |> json(%{success: false, error: "Could not mint a token"})

      _not_signed_in ->
        conn |> put_status(:unauthorized) |> json(%{success: false, error: "Not signed in"})
    end
  end

  defp fresh_session?(session), do: not Auth.session_expired?(session)

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

  # Shared by sign-in and me/2 so the responses cannot drift.
  defp user_json(user), do: %{id: user.id, name: user.name, email: user.email, avatar_url: user.avatar_url}

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
