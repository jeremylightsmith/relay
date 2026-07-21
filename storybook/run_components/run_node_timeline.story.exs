defmodule Storybook.RunComponents.RunNodeTimeline do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.run_node_timeline/1
  def render_source, do: :function

  defp run(attrs) do
    Map.merge(
      %{status: :running, flow_key: "code", current_node: "implement", finished_at: nil},
      attrs
    )
  end

  defp ne(node_key, attempt, outcome, attrs) do
    {duration_s, attrs} = Map.pop(attrs, :duration_s, 42)
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

  defp detail(run_attrs, nes), do: Relay.Runs.run_detail(Map.put(run(run_attrs), :node_executions, nes), nil)

  def variations do
    [
      %Variation{
        id: :mid_flight_review_loop,
        description: "review-failed loop — a fresh implement session, never \"session resumed\"",
        attributes: %{
          detail:
            detail(%{status: :running}, [
              ne("branch", 1, :succeeded, %{duration_s: 8, cost: Decimal.new("0.00")}),
              ne("implement", 1, :succeeded, %{duration_s: 160, cost: Decimal.new("0.90")}),
              ne("spec_review", 1, :succeeded, %{duration_s: 31, cost: Decimal.new("0.20")}),
              ne("quality_review", 1, :failed, %{
                duration_s: 48,
                cost: Decimal.new("0.35"),
                detail: "assert on CSV bytes"
              }),
              ne("implement", 2, nil, %{duration_s: nil})
            ])
        }
      },
      %Variation{
        id: :needs_input_reentry,
        description: "needs-input re-entry — the only state that says \"session resumed\"",
        attributes: %{
          detail:
            detail(%{status: :running, flow_key: "spec", current_node: "brainstorm"}, [
              ne("brainstorm", 1, :needs_input, %{duration_s: 190, cost: Decimal.new("0.15")}),
              ne("brainstorm", 2, nil, %{duration_s: nil})
            ])
        }
      },
      %Variation{
        id: :cancelled,
        attributes: %{
          detail:
            detail(%{status: :cancelled}, [
              ne("branch", 1, :succeeded, %{duration_s: 8, cost: Decimal.new("0.00")}),
              ne("implement", 1, nil, %{duration_s: 72, cost: Decimal.new("0.40")})
            ])
        }
      },
      %Variation{
        id: :circuit,
        attributes: %{
          detail:
            detail(%{status: :failed, current_node: "quality_review", finished_at: DateTime.utc_now()}, [
              ne("implement", 1, :succeeded, %{duration_s: 160, cost: Decimal.new("0.90")}),
              ne("quality_review", 1, :failed, %{duration_s: 48, cost: Decimal.new("0.35"), detail: "same finding"}),
              ne("implement", 2, :succeeded, %{duration_s: 130, cost: Decimal.new("0.72")}),
              ne("quality_review", 2, :failed, %{duration_s: 41, cost: Decimal.new("0.30"), detail: "same finding"}),
              ne("implement", 3, :succeeded, %{duration_s: 118, cost: Decimal.new("0.66")}),
              ne("quality_review", 3, :failed, %{
                duration_s: 44,
                cost: Decimal.new("0.31"),
                detail: "same finding, 3rd time"
              })
            ])
        }
      }
    ]
  end
end
