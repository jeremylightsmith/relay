defmodule Storybook.RunComponents.RunHistory do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.run_history/1
  def render_source, do: :function

  defp ne(node_key, attempt, outcome, attrs) do
    {duration_s, attrs} = Map.pop(attrs, :duration_s, 600)
    started_at = DateTime.utc_now()
    finished_at = duration_s && DateTime.add(started_at, duration_s, :second)

    Map.merge(
      %{
        id: System.unique_integer([:positive]),
        node_key: node_key,
        attempt: attempt,
        outcome: outcome,
        detail: nil,
        cost: nil,
        started_at: started_at,
        finished_at: finished_at
      },
      attrs
    )
  end

  defp detail(run_attrs, nes),
    do: Relay.Runs.run_detail(Map.merge(%{current_node: nil}, Map.put(run_attrs, :node_executions, nes)), nil)

  def variations do
    [
      %Variation{
        id: :three_prior_runs,
        attributes: %{
          runs: [
            %{
              detail:
                detail(
                  %{status: :done, flow_version: 1, finished_at: DateTime.add(DateTime.utc_now(), -3000, :second)},
                  [
                    ne("implement", 1, :succeeded, %{cost: Decimal.new("2.30")}),
                    ne("merge", 1, :succeeded, %{cost: Decimal.new("1.80")})
                  ]
                ),
              number: 1
            },
            %{
              detail:
                detail(
                  %{status: :failed, flow_version: 1, finished_at: DateTime.add(DateTime.utc_now(), -1500, :second)},
                  [
                    ne("implement", 1, :succeeded, %{cost: Decimal.new("1.28")}),
                    ne("quality_review", 1, :failed, %{detail: "brittle assert", cost: Decimal.new("1.00")})
                  ]
                ),
              number: 2
            },
            %{
              detail:
                detail(
                  %{status: :done, flow_version: 1, finished_at: DateTime.add(DateTime.utc_now(), -170, :second)},
                  [
                    ne("implement", 1, :succeeded, %{cost: Decimal.new("2.90")}),
                    ne("quality_review", 1, :succeeded, %{cost: Decimal.new("1.50")}),
                    ne("merge", 1, :succeeded, %{cost: Decimal.new("1.80")})
                  ]
                ),
              number: 3
            }
          ]
        }
      }
    ]
  end
end
