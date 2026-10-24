defmodule RelayWeb.RawBodyReader do
  @moduledoc """
  `Plug.Parsers`' `body_reader` (RE460): reads the body as usual and, for the Stripe webhook
  only (`/webhooks/stripe`), also keeps the raw bytes in `conn.private[:raw_body]` — Stripe signs
  the exact body, and the JSON parser would otherwise consume it. Every other path keeps nothing,
  so no request's body is held in memory twice.
  """

  @stripe_webhook_path "/webhooks/stripe"

  @doc "Reads the body (`Plug.Conn.read_body/2`), keeping it raw for the Stripe webhook."
  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok | :more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(%Plug.Conn{request_path: @stripe_webhook_path} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, chunk, conn} when status in [:ok, :more] ->
        {status, chunk, Plug.Conn.put_private(conn, :raw_body, (conn.private[:raw_body] || "") <> chunk)}

      error ->
        error
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)
end
