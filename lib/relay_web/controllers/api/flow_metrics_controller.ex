defmodule RelayWeb.Api.FlowMetricsController do
  @moduledoc """
  Read-only per-flow node metrics for agents/scripts (RLY-209).

  An optional `?card=<ref>` scopes every figure to one card's executions (RE235). One response
  shape serves both scopes — the extra keys are additive, so `bin/relay flow-stats`, which
  reads specific keys, is unaffected.
  """
  use RelayWeb, :controller

  alias Relay.Cards
  alias Relay.Flows
  alias Relay.Runs

  action_fallback RelayWeb.Api.FallbackController

  def metrics(conn, %{"key" => key} = params) do
    board = conn.assigns.current_board

    with {:ok, flow} <- fetch_flow(board, key),
         {:ok, card_ref, card_id} <- fetch_card(board, params["card"]) do
      scope = Runs.metric_scope(card_id)
      opts = [window: params["window"] || Runs.default_window(), card_id: card_id]

      json(conn, %{
        data: %{
          scope: to_string(scope),
          card: card_ref,
          summary: summary_json(Runs.flow_metrics_summary(flow, opts), scope),
          nodes: Enum.map(Runs.node_metrics_for_flow(flow, opts), &node_json(&1, scope))
        }
      })
    end
  end

  defp fetch_flow(board, key) do
    case Flows.get_flow(board, key) do
      nil -> {:error, :not_found}
      flow -> {:ok, flow}
    end
  end

  # The API is explicit for machines where the page degrades quietly for humans: an unknown,
  # unparseable or other-board ref is a 404, not a silent fall back to the aggregate.
  # `card_ids_by_ref/2` is board-scoped, so the other-board case is the same code path.
  defp fetch_card(_board, nil), do: {:ok, nil, nil}

  defp fetch_card(board, ref) do
    case board |> Cards.card_ids_by_ref([ref]) |> Map.get(ref) do
      nil -> {:error, :not_found}
      id -> {:ok, ref, id}
    end
  end

  defp summary_json(s, scope) do
    %{
      total_runs: s.total_runs,
      completed: s.completed,
      completed_pct: s.completed_pct,
      total_spend: decimal(s.total_spend),
      median_end_to_end: percentile(scope, s.median_end_to_end),
      total_end_to_end: s.total_end_to_end
    }
  end

  defp node_json(n, scope) do
    %{
      node_key: n.node_key,
      runs: n.runs,
      duration_p50: percentile(scope, n.duration_p50),
      duration_p95: percentile(scope, n.duration_p95),
      duration_total: n.duration_total,
      cost_p50: percentile(scope, decimal(n.cost_p50)),
      cost_p95: percentile(scope, decimal(n.cost_p95)),
      cost_total: decimal(n.cost_total),
      attempts_mean: n.attempts_mean,
      verdict_split: n.verdict_split,
      loop_laps: n.loop_laps
    }
  end

  # A percentile over one card's one-to-three executions is noise — card scope reports an
  # honest null rather than a number nobody should read (RE235).
  defp percentile(:card, _value), do: nil
  defp percentile(:flow, value), do: value

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)
end
