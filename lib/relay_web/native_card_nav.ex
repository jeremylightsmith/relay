defmodule RelayWeb.NativeCardNav do
  @moduledoc """
  RE400 — the web side of the native card host's `relayCardNav` bridge.

  The native shell opens `/cards/:ref?board=…&nav=prev,next` naming which neighbors it has; the
  drawer then renders its ‹ › chevrons in native mode, and a tap calls
  `window.flutter_inappwebview.callHandler(handler(), dir)` instead of patching. This module is
  the one web copy of the handler name and the direction tokens, and parses / re-emits `nav`.
  """

  @handler "relayCardNav"
  @directions ["prev", "next"]
  # "prev" => :prev?, "next" => :next? — the flag keys, derived at compile time from the tokens.
  @flags Map.new(@directions, &{&1, :"#{&1}?"})

  @type flags :: %{prev?: boolean(), next?: boolean()}

  @doc "The JS handler name the native shell registers."
  @spec handler() :: String.t()
  def handler, do: @handler

  @doc "The direction tokens, in their canonical `nav` order."
  @spec directions() :: [String.t()]
  def directions, do: @directions

  @doc """
  Reads `params["nav"]`: a comma-separated list of direction tokens. Unknown tokens are ignored;
  absent, non-binary, blank or token-less is `nil` (web mode).
  """
  @spec parse(map()) :: flags() | nil
  def parse(%{"nav" => nav}) when is_binary(nav) do
    tokens = nav |> String.split(",") |> Enum.map(&String.trim/1)

    if Enum.any?(tokens, &(&1 in @directions)) do
      Map.new(@directions, &{flag(&1), &1 in tokens})
    end
  end

  def parse(_params), do: nil

  @doc "The `nav` query param for `flags`, tokens in `directions/0` order; `[]` for nil."
  @spec to_param(flags() | nil) :: [{:nav, String.t()}]
  def to_param(nil), do: []

  def to_param(flags) do
    case Enum.filter(@directions, &Map.fetch!(flags, flag(&1))) do
      [] -> []
      dirs -> [nav: Enum.join(dirs, ",")]
    end
  end

  defp flag(direction), do: Map.fetch!(@flags, direction)
end
