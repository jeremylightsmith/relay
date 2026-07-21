defmodule Storybook.RunComponents.RunStateBanner do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.run_state_banner/1
  def render_source, do: :function

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

  defp detail(run_attrs, nes), do: Relay.Runs.run_detail(Map.put(run_attrs, :node_executions, nes), nil)

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
          detail: detail(%{status: :cancelled, current_node: "implement"}, []),
          card: %{branch: "relay/RLY-150", rejection: nil},
          claimer: "Jeremy"
        }
      },
      %Variation{
        id: :circuit,
        attributes: %{
          variant: :circuit,
          card: nil,
          detail:
            detail(%{status: :failed, current_node: nil}, [
              ne("quality_review", 1, :failed, %{detail: "same finding", cost: Decimal.new("0.76")}),
              ne("quality_review", 2, :failed, %{detail: "same finding", cost: Decimal.new("0.76")}),
              ne("quality_review", 3, :failed, %{detail: "same finding, 3rd time", cost: Decimal.new("0.76")})
            ])
        }
      },
      # The other failure modes (RLY-179): no invented breaker, just the engine's reason.
      %Variation{
        id: :failed,
        attributes: %{
          variant: :failed,
          card: nil,
          detail:
            detail(
              %{
                status: :failed,
                current_node: nil,
                failure_detail:
                  "The flow has nowhere to go after `fixit` reported `failed`. (no_route_for_outcome: fixit → failed)"
              },
              [
                ne("fixit", 1, :failed, %{
                  detail: "Could not fix the failing spec: 2 assertions still red.",
                  cost: Decimal.new("0.41")
                })
              ]
            )
        }
      },
      %Variation{
        id: :parked,
        attributes: %{
          variant: :parked,
          detail:
            detail(
              %{
                status: :parked,
                flow_key: "spec",
                current_node: "brainstorm",
                started_at: DateTime.add(DateTime.utc_now(), -720, :second)
              },
              []
            )
        },
        slots: [
          "<div>stepper renders here</div>"
        ]
      }
    ]
  end
end
