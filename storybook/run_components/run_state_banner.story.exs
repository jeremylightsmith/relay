defmodule Storybook.RunComponents.RunStateBanner do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.run_state_banner/1
  def render_source, do: :function

  defp ne(node_key, attempt, outcome, attrs) do
    Map.merge(%{node_key: node_key, attempt: attempt, outcome: outcome, detail: nil, cost: nil}, attrs)
  end

  def variations do
    [
      %Variation{
        id: :reentry,
        attributes: %{
          variant: :reentry,
          card: %{
            rejection: %{
              note:
                "The CSV should stream row by row, not buffer the whole board in memory — this will OOM on large boards. Also add a header row.",
              rejected_by: "Dana",
              from_stage_name: "Review",
              rejected_at: DateTime.add(DateTime.utc_now(), -180, :second)
            },
            branch: nil
          }
        }
      },
      %Variation{
        id: :revoked,
        attributes: %{
          variant: :revoked,
          run: %{current_node: "implement"},
          card: %{branch: "relay/RLY-150", rejection: nil},
          claimer: "Jeremy"
        }
      },
      %Variation{
        id: :circuit,
        attributes: %{
          variant: :circuit,
          run: %{status: :failed},
          card: nil,
          node_executions: [
            ne("quality_review", 1, :failed, %{detail: "same finding"}),
            ne("quality_review", 2, :failed, %{detail: "same finding"}),
            ne("quality_review", 3, :failed, %{detail: "same finding, 3rd time"})
          ],
          totals: %{duration_s: 552, cost: Decimal.new("2.28"), attempts: 3}
        }
      },
      # The other failure modes (RLY-179): no invented breaker, just the engine's reason.
      %Variation{
        id: :failed,
        attributes: %{
          variant: :failed,
          run: %{
            status: :failed,
            failure_detail:
              "The flow has nowhere to go after `fixit` reported `failed`. (no_route_for_outcome: fixit → failed)"
          },
          card: nil,
          node_executions: [ne("fixit", 1, :failed, %{detail: "Could not fix the failing spec: 2 assertions still red."})],
          totals: %{duration_s: 91, cost: Decimal.new("0.41"), attempts: 1}
        }
      },
      %Variation{
        id: :parked,
        attributes: %{
          variant: :parked,
          run: %{
            status: :parked,
            flow_key: "spec",
            current_node: "brainstorm",
            started_at: DateTime.add(DateTime.utc_now(), -720, :second)
          }
        },
        slots: [
          "<div>stepper renders here</div>"
        ]
      }
    ]
  end
end
