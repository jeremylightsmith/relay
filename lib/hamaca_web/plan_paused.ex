defmodule HamacaWeb.PlanPaused do
  @moduledoc """
  RE460, RE469 — the one owner of the `plan_paused` refusal: a board whose owner is held, or that
  is read-only on Free (`Hamaca.Billing.board_paused?/1`), answers **402** with this code and message on every board-key
  `/api/*` request (`HamacaWeb.Plugs.RequireActivePlan`) and on the `/api/all` writes
  (`HamacaWeb.Api.FallbackController`). `./relay` mirrors the code as `PLAN_PAUSED_CODE`, pinned by
  `test/fixtures/runner_contract.json`'s `claim_refused.plan_paused`.
  """

  import Plug.Conn

  @code "plan_paused"
  @message "This board is read-only: its owner's plan is paused or on Free. See /account/billing."

  @doc "The refusal's error code."
  @spec code() :: String.t()
  def code, do: @code

  @doc "The refusal's message."
  @spec message() :: String.t()
  def message, do: @message

  @doc ~s(Sends the 402 `{"error": {"code", "message"}}` refusal as JSON and halts.)
  @spec send_refusal(Plug.Conn.t()) :: Plug.Conn.t()
  def send_refusal(conn) do
    body = Jason.encode!(%{error: %{code: code(), message: message()}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(402, body)
    |> halt()
  end
end
