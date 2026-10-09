defmodule Storybook.FlowSettingsComponents.FlowBand do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowSettingsComponents.flow_band/1
  def render_source, do: :function

  # A stage row's foot on Board Settings → Stages (RE431, card mockup "A — stage row owns its
  # flow"). Flows are literal structs: the band only reads key / enabled / version / nodes / id.
  defp flow(overrides) do
    struct(
      Schemas.Flow,
      Map.merge(
        %{id: 1, key: "code", enabled: true, version: 4, nodes: Enum.map(1..7, &%{key: "n#{&1}"})},
        overrides
      )
    )
  end

  defp row(flow, customized? \\ false), do: %{flow: flow, customized?: customized?, resettable?: customized?}

  # A domain-built `:upstream_review` problem for flow `plan` on stage 16 (RE432).
  defp paused_problem do
    stages = [
      %{id: 15, name: "Spec", type: :planning, parent_id: nil},
      %{id: 17, name: "Spec · Review", type: :review, parent_id: 15},
      %{id: 16, name: "Plan", type: :planning, parent_id: nil},
      %{id: 18, name: "Plan · Done", type: :done, parent_id: 16}
    ]

    [problem] = Relay.Flows.Shape.problems(stages, [%{key: "plan", stage_id: 16, enabled: true}])
    problem
  end

  @code %{id: 11, name: "Code", type: :work}
  @both %{pulls_from: "Plan · Done", lands_on: "Review"}

  def variations do
    [
      %Variation{
        id: :on,
        description: "A flow that is on",
        attributes: %{
          stage: @code,
          row: row(flow(%{})),
          neighbours: @both,
          slug: "acme",
          copy_targets: [%{id: 13, name: "Deploy"}]
        }
      },
      %Variation{
        id: :off_customized,
        description: "Off and customized — Reset shows in the menu, Delete is enabled",
        attributes: %{
          stage: %{id: 12, name: "Plan", type: :planning},
          row:
            row(flow(%{id: 2, key: "plan", enabled: false, version: 6, nodes: Enum.map(1..5, &%{key: "n#{&1}"})}), true),
          neighbours: %{pulls_from: "Spec · Done", lands_on: "Plan · Done"},
          slug: "acme"
        }
      },
      %Variation{
        id: :no_flow,
        description: "A work stage without a flow — + Add flow",
        attributes: %{stage: %{id: 13, name: "Deploy", type: :work}, neighbours: @both, slug: "acme"}
      },
      %Variation{
        id: :queue,
        description: "A queue stage — cards rest here",
        attributes: %{stage: %{id: 14, name: "Next up", type: :queue}, neighbours: @both, slug: "acme"}
      },
      %Variation{
        id: :missing_neighbour,
        description: "The board's first stage — nothing to pull from, so the toggle is disabled",
        attributes: %{
          stage: %{id: 15, name: "Spec", type: :planning},
          row: row(flow(%{id: 3, key: "spec", enabled: false, version: 1})),
          neighbours: %{pulls_from: nil, lands_on: "Spec · Review"},
          slug: "acme"
        }
      },
      %Variation{
        id: :paused,
        description: "RE432 — on but paused by a broken shape: PAUSED badge, amber chip, dashed pickup",
        attributes: %{
          stage: %{id: 16, name: "Plan", type: :planning},
          row: row(flow(%{id: 4, key: "plan", version: 6, problem: paused_problem()})),
          neighbours: %{pulls_from: "Spec · Review", lands_on: "Plan · Done"},
          slug: "acme"
        }
      }
    ]
  end
end
