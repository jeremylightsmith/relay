defmodule Storybook.RunComponents.RunHistory do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.run_history/1
  def render_source, do: :function

  defp ne(node_key, attempt, outcome, attrs \\ %{}) do
    Map.merge(%{node_key: node_key, attempt: attempt, outcome: outcome, detail: nil, cost: nil}, attrs)
  end

  def variations do
    [
      %Variation{
        id: :three_prior_runs,
        attributes: %{
          runs: [
            %{
              run: %{status: :done, flow_version: 1, finished_at: DateTime.add(DateTime.utc_now(), -3000, :second)},
              number: 1,
              node_executions: [ne("implement", 1, :succeeded), ne("merge", 1, :succeeded)],
              totals: %{duration_s: 1860, nodes: 2, attempts: 2, cost: Decimal.new("4.10")}
            },
            %{
              run: %{status: :failed, flow_version: 1, finished_at: DateTime.add(DateTime.utc_now(), -1500, :second)},
              number: 2,
              node_executions: [
                ne("implement", 1, :succeeded),
                ne("quality_review", 1, :failed, %{detail: "brittle assert"})
              ],
              totals: %{duration_s: 550, nodes: 2, attempts: 2, cost: Decimal.new("2.28")}
            },
            %{
              run: %{status: :done, flow_version: 1, finished_at: DateTime.add(DateTime.utc_now(), -170, :second)},
              number: 3,
              node_executions: [
                ne("implement", 1, :succeeded),
                ne("quality_review", 1, :succeeded),
                ne("merge", 1, :succeeded)
              ],
              totals: %{duration_s: 1820, nodes: 3, attempts: 3, cost: Decimal.new("6.20")}
            }
          ]
        }
      }
    ]
  end
end
