defmodule RelayWeb.Api.FlowMetricsController do
  @moduledoc "Read-only per-flow node metrics for agents/scripts (RLY-209)."
  use RelayWeb, :controller

  alias Relay.Flows
  alias Relay.Runs

  action_fallback RelayWeb.Api.FallbackController

  def metrics(conn, %{"key" => key} = params) do
    board = conn.assigns.current_board

    case Flows.get_flow(board, key) do
      nil ->
        {:error, :not_found}

      flow ->
        window = params["window"] || Runs.default_window()

        json(conn, %{
          data: %{
            summary: summary_json(Runs.flow_metrics_summary(flow, window: window)),
            nodes: Enum.map(Runs.node_metrics_for_flow(flow, window: window), &node_json/1)
          }
        })
    end
  end

  defp summary_json(s) do
    %{
      total_runs: s.total_runs,
      completed: s.completed,
      completed_pct: s.completed_pct,
      total_spend: decimal(s.total_spend),
      median_end_to_end: s.median_end_to_end
    }
  end

  defp node_json(n) do
    %{
      node_key: n.node_key,
      runs: n.runs,
      duration_p50: n.duration_p50,
      duration_p95: n.duration_p95,
      cost_p50: decimal(n.cost_p50),
      cost_p95: decimal(n.cost_p95),
      attempts_mean: n.attempts_mean,
      verdict_split: n.verdict_split,
      loop_laps: n.loop_laps
    }
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)
end
