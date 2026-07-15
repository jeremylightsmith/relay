defmodule RelayWeb.Api.DeviceController do
  @moduledoc """
  Device registration for push (RLY-81). Called natively by the Flutter shell
  (not through the embedded webview) under the `/api/all` scope, authenticated
  by the F2 native session cookie.

  `platform` in the request body is accepted and ignored: iOS is the only
  supported platform (Android/FCM is deferred — RLY-103), so it is never cast
  from input.
  """

  use RelayWeb, :controller

  alias Relay.Push

  def create(conn, %{"token" => token}) when is_binary(token) do
    case Push.register_device(conn.assigns.current_scope.user, token, :ios) do
      {:ok, _device} ->
        conn |> put_status(:created) |> json(%{ok: true})

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid device token"})
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "token is required"})
  end

  def delete(conn, %{"token" => token}) do
    :ok = Push.unregister_device(conn.assigns.current_scope.user, token)
    send_resp(conn, :no_content, "")
  end
end
