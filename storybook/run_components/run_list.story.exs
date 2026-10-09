defmodule Storybook.RunComponents.RunList do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.run_list/1
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

  # `flow: %{stage: …}` is how RunDetail resolves `stage_name` (RE426).
  defp detail(stage, run_attrs, nes) do
    run =
      Map.merge(
        %{current_node: nil, flow_version: nil, flow: %{stage: %{name: stage}}},
        Map.put(run_attrs, :node_executions, nes)
      )

    Relay.Runs.run_detail(run, nil)
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp earlier_runs do
    [
      %{
        detail:
          detail("Code", %{status: :failed, flow_key: "code", started_at: ago(4000), finished_at: ago(3000)}, [
            ne("implement", 1, :succeeded, %{cost: Decimal.new("1.28")}),
            ne("quality_review", 1, :failed, %{detail: "brittle assert", cost: Decimal.new("1.00")})
          ]),
        number: 2
      },
      %{
        detail:
          detail("Spec", %{status: :done, flow_key: "spec", started_at: ago(90_000), finished_at: ago(86_400)}, [
            ne("brainstorm", 1, :succeeded, %{cost: Decimal.new("0.90")})
          ]),
        number: 1
      }
    ]
  end

  def variations do
    [
      %Variation{
        id: :running_latest,
        description: "Latest run going; earlier Code and Spec runs collapsed",
        attributes: %{
          entries: [
            %{
              detail:
                detail("Code", %{status: :running, flow_key: "code", current_node: "implement", started_at: ago(291)}, [
                  ne("branch", 1, :succeeded, %{duration_s: 8, cost: Decimal.new("0.02")}),
                  ne("implement", 1, nil, %{duration_s: nil})
                ]),
              number: 3
            }
            | earlier_runs()
          ],
          task_progress: %{done: 1, total: 4}
        },
        slots: [
          """
          <:latest_body>
            <span style="font-size:12px;">View in flow metrics →</span>
          </:latest_body>
          """
        ]
      },
      %Variation{
        id: :done_latest,
        description: "Latest run finished: stats row above its timeline",
        attributes: %{
          entries: [
            %{
              detail:
                detail("Code", %{status: :done, flow_key: "code", started_at: ago(900), finished_at: ago(240)}, [
                  ne("implement", 1, :succeeded, %{duration_s: 300, cost: Decimal.new("2.90")}),
                  ne("merge", 1, :succeeded, %{duration_s: 91, cost: Decimal.new("1.80")})
                ]),
              number: 3
            }
            | earlier_runs()
          ]
        }
      },
      %Variation{
        id: :parked_latest,
        description: "Latest run parked on a human answer",
        attributes: %{
          entries: [
            %{
              detail:
                detail("Spec", %{status: :parked, flow_key: "spec", current_node: "brainstorm", started_at: ago(600)}, [
                  ne("brainstorm", 1, :needs_input, %{duration_s: 120})
                ]),
              number: 3
            }
            | earlier_runs()
          ]
        }
      }
    ]
  end
end
