defmodule Storybook.FlowShapeComponents.PausedFlowBanners do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias Relay.Flows.Shape

  def function, do: &RelayWeb.FlowShapeComponents.paused_flow_banners/1
  def render_source, do: :function

  # RE432, card mockup "C — board banner per paused flow, with Fix in Stages". Each flow is a
  # literal struct whose `problem` is built by the domain (`Relay.Flows.Shape.problems/2` over
  # in-memory stages), so the WHY sentence is the real one.
  @stages [
    %{id: 1, name: "Spec", type: :planning, parent_id: nil},
    %{id: 2, name: "Plan", type: :planning, parent_id: nil},
    %{id: 3, name: "Code", type: :work, parent_id: nil},
    %{id: 4, name: "Review", type: :review, parent_id: nil},
    %{id: 5, name: "Deploy", type: :work, parent_id: nil},
    %{id: 6, name: "Done", type: :done, parent_id: nil}
  ]

  defp paused(key, stage_id) do
    [problem] = Shape.problems(@stages, [%{key: key, stage_id: stage_id, enabled: true}])
    struct(Schemas.Flow, %{key: key, stage_id: stage_id, enabled: true, problem: problem})
  end

  def variations do
    [
      %Variation{
        id: :single_editor,
        description: "One paused flow, seen by an editor — Fix in Stages → links to its stage row",
        attributes: %{id: "paused-flow-banners-editor", flows: [paused("deploy", 5)], slug: "acme", editor?: true}
      },
      %Variation{
        id: :single_non_editor,
        description: "An archived board — no Fix button, a line asking a board admin instead",
        attributes: %{id: "paused-flow-banners-reader", flows: [paused("deploy", 5)], slug: "acme", editor?: false}
      },
      %Variation{
        id: :two_flows,
        description: "Two paused flows — one banner each, stacked",
        attributes: %{
          id: "paused-flow-banners-two",
          flows: [paused("plan", 2), paused("deploy", 5)],
          slug: "acme",
          editor?: true
        }
      },
      %Variation{
        id: :collapsed_three,
        description: "Three or more paused flows collapse into one summary banner",
        attributes: %{
          id: "paused-flow-banners-three",
          flows: [paused("plan", 2), paused("code", 3), paused("deploy", 5)],
          slug: "acme",
          editor?: true
        }
      }
    ]
  end
end
