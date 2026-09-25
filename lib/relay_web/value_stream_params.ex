defmodule RelayWeb.ValueStreamParams do
  @moduledoc """
  The URL state both value-stream levels share (RE347 level 1, RE349 level 2): `card`, `scope`
  and `window`, normalized by ONE set of rules and written back by ONE builder, so a drill from a
  level-1 flow box into level 2 and level 2's "← Card stream" link keep exactly the same params.
  `window` nil means Last N (`Relay.ValueStream.default_last/0`); otherwise it must be one of
  `Relay.Runs.metric_windows/0`. A scope only travels with a resolved card (Flow Metrics' rule,
  RE235).
  """
  use RelayWeb, :verified_routes

  alias Relay.Cards
  alias Relay.Runs
  alias Relay.ValueStream

  @doc "The board's card for `ref`, or nil (unknown or other-board refs degrade to the average)."
  def resolve_card(_board, nil), do: nil
  def resolve_card(board, ref), do: Cards.get_card_by_ref(board, ref)

  @doc "No card pins flow scope; with one, a `?scope=` naming a real scope wins, else This card."
  def normalize_scope(_param, nil), do: Runs.metric_scope(nil)

  def normalize_scope(param, card),
    do: Enum.find(Runs.metric_scopes(), Runs.metric_scope(card.id), &(to_string(&1) == param))

  @doc "nil = Last N; anything else must be a real metrics window."
  def normalize_window(window), do: if(window in Runs.metric_windows(), do: window)

  def blank_to_nil(nil), do: nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(value), do: value

  @doc "The query params for a view: `card`, then `scope` (only with a card), then `window`."
  def query(card_ref, scope, window) do
    []
    |> maybe_put("card", card_ref)
    |> maybe_put("scope", card_ref && to_string(scope))
    |> maybe_put("window", window)
  end

  @doc "Level 1's path."
  def stream_path(slug, []), do: ~p"/board/#{slug}/value-stream"
  def stream_path(slug, params), do: ~p"/board/#{slug}/value-stream?#{params}"

  @doc "Level 2's path for `flow_key`."
  def flow_path(slug, flow_key, []), do: ~p"/board/#{slug}/value-stream/#{flow_key}"
  def flow_path(slug, flow_key, params), do: ~p"/board/#{slug}/value-stream/#{flow_key}?#{params}"

  def maybe_put(list, _key, value) when value in [nil, false], do: list
  def maybe_put(list, key, value), do: list ++ [{key, value}]

  @doc "The scope control's `{value, label}` pairs."
  def scope_options, do: Enum.map(Runs.metric_scopes(), &{to_string(&1), scope_label(&1)})

  defp scope_label(:card), do: "This card"
  defp scope_label(:flow), do: "All cards"

  @doc "The window control's `{value, label}` pairs — `last` (Last N) first."
  def window_options,
    do: [{"last", "Last #{ValueStream.default_last()}"} | Enum.map(Runs.metric_windows(), &{&1, window_label(&1)})]

  defp window_label("all"), do: "All"
  defp window_label(window), do: window
end
