defmodule Hamaca.Billing.Webhook do
  @moduledoc """
  Stripe webhook signature verification (RE460): pure — the caller supplies the secret and the
  clock.

  Stripe signs `"<t>.<raw body>"` with HMAC-SHA256 under the endpoint's signing secret and sends
  `Stripe-Signature: t=<unix seconds>,v1=<hex>[,v1=<hex>…]` (several `v1`s while a secret is
  being rolled). An event verifies when any `v1` matches (constant-time) and `t` is within
  `tolerance_s/0` of now — which is what makes a replayed request go stale.
  """

  @tolerance_s 300

  @doc "How far, in seconds, a signature's timestamp may be from now."
  @spec tolerance_s() :: 300
  def tolerance_s, do: @tolerance_s

  @doc "The decoded event when `signature_header` signs `raw_body` under `secret`, recently."
  @spec verify(binary(), String.t() | nil, String.t(), integer()) :: {:ok, map()} | {:error, :invalid_signature}
  def verify(raw_body, signature_header, secret, now_unix)
      when is_binary(raw_body) and is_binary(signature_header) and is_binary(secret) and secret != "" do
    with {:ok, ts, signatures} <- parse(signature_header),
         true <- abs(now_unix - ts) <= @tolerance_s,
         expected = expected(secret, ts, raw_body),
         true <- Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)),
         {:ok, %{} = event} <- Jason.decode(raw_body) do
      {:ok, event}
    else
      _invalid -> {:error, :invalid_signature}
    end
  end

  def verify(_raw_body, _signature_header, _secret, _now_unix), do: {:error, :invalid_signature}

  defp parse(header) do
    pairs =
      for part <- String.split(header, ","),
          [key, value] <- [String.split(String.trim(part), "=", parts: 2)],
          do: {key, value}

    with {"t", t} <- List.keyfind(pairs, "t", 0),
         {ts, ""} <- Integer.parse(t),
         [_ | _] = signatures <- for({"v1", v1} <- pairs, do: v1) do
      {:ok, ts, signatures}
    end
  end

  defp expected(secret, ts, raw_body),
    do: :hmac |> :crypto.mac(:sha256, secret, "#{ts}.#{raw_body}") |> Base.encode16(case: :lower)
end
