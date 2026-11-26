defmodule HamacaWeb.Api.AccountController do
  @moduledoc """
  The native app's Delete account surface (RE509): the deletion preview the confirm page
  renders (`GET /api/all/account/deletion`) and the deletion itself (`DELETE /api/all/account`).
  Authenticated by `HamacaWeb.ApiUserAuth` (user bearer token). Account is its own resource,
  so it lives outside `HamacaWeb.Api.AllController`.

  Every refusal changes nothing and renders `{"error": {"code", "message"}}` locally from
  `status_and_message/1` — one clause per atom in `Hamaca.Accounts.deletion_errors/0`, the
  `code` being the atom's name — rather than through `HamacaWeb.Api.FallbackController`.
  """

  use HamacaWeb, :controller

  alias Hamaca.Accounts
  alias HamacaWeb.Api.AccountJSON
  alias HamacaWeb.Api.ErrorJSON

  @confirmation "DELETE"

  def deletion(conn, _params) do
    preview = Accounts.deletion_preview(conn.assigns.current_user)

    conn
    |> put_view(json: AccountJSON)
    |> render(:deletion, preview: preview)
  end

  def delete(conn, params) do
    with :ok <- confirmed(params),
         {:ok, transfers} <- transfers_param(params),
         :ok <-
           Accounts.delete_account(conn.assigns.current_user,
             transfers: transfers,
             apple_authorization_code: params["apple_authorization_code"]
           ) do
      send_resp(conn, :no_content, "")
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp confirmed(%{"confirm" => @confirmation}), do: :ok
  defp confirmed(_params), do: {:error, :confirm_required}

  # A map of slug → integer user id. JSON integers arrive as integers; anything else (a string
  # id, a list) is refused here, before the context, and never coerced.
  defp transfers_param(params) do
    transfers = Map.get(params, "transfers", %{})

    if is_map(transfers) and Enum.all?(transfers, &transfer?/1),
      do: {:ok, transfers},
      else: {:error, :invalid_transfers}
  end

  defp transfer?({slug, user_id}), do: is_binary(slug) and is_integer(user_id)

  defp refuse(conn, reason) do
    {status, message} = status_and_message(reason)

    conn
    |> put_status(status)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: Atom.to_string(reason), message: message)
  end

  @spec status_and_message(Accounts.Deletion.error()) :: {Plug.Conn.status(), String.t()}
  defp status_and_message(:confirm_required), do: {:unprocessable_entity, "Type DELETE to confirm."}

  defp status_and_message(:invalid_transfers), do: {:unprocessable_entity, "Choose a new owner for every shared board."}

  defp status_and_message(:apple_reauth_required),
    do: {:unprocessable_entity, "Sign in with Apple again to delete this account."}

  defp status_and_message(:apple_mismatch), do: {:forbidden, "That Apple ID doesn't match this account."}
  defp status_and_message(:apple_revoke_failed), do: {:bad_gateway, "Couldn't reach Apple. Nothing was deleted."}
end
