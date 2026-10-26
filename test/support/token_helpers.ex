defmodule RelayWeb.TokenHelpers do
  @moduledoc """
  Test helpers for signed tokens (`Phoenix.Token`). Boundary checks are disabled: test-only
  support code.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  @doc """
  `token` with its signature broken. Swaps the FIRST character of the signature segment (after
  the last `.`): every bit of it is significant, unlike the last base64url character, whose
  padding bits `Base.url_decode64/2` ignores — swapping that one leaves the signature valid one
  time in 16.
  """
  @spec tamper(String.t()) :: String.t()
  def tamper(token) do
    [signature | rest] = token |> String.split(".") |> Enum.reverse()
    {first, tail} = String.split_at(signature, 1)
    swapped = if first == "A", do: "B", else: "A"

    rest |> Enum.reverse([swapped <> tail]) |> Enum.join(".")
  end
end
