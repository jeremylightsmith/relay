defmodule Storybook.FlowShapeComponents.ShapeCallout do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias Relay.Flows.Shape

  def function, do: &RelayWeb.FlowShapeComponents.shape_callout/1
  def render_source, do: :function

  # RE432, card mockup "B — broken-shape callouts on the paused stage rows (all four problems)".
  # Every problem is built by the domain (`Relay.Flows.Shape.problems/2` over in-memory stages),
  # so the WHAT / WHY / fix wording is the real sentence.
  defp problem(stages, stage_id, key, enabled \\ true) do
    [problem] = Shape.problems(stages, [%{key: key, stage_id: stage_id, enabled: enabled}])
    problem
  end

  defp stage(id, name, type, parent_id \\ nil), do: %{id: id, name: name, type: type, parent_id: parent_id}

  defp no_upstream,
    do: problem([stage(1, "Triage", :work), stage(2, "Backlog", :queue), stage(3, "Spec", :planning)], 1, "triage")

  defp upstream_review(enabled \\ true) do
    stages = [
      stage(1, "Spec", :planning),
      stage(2, "Spec · Review", :review, 1),
      stage(3, "Plan", :planning),
      stage(4, "Plan · Done", :done, 3),
      stage(5, "Code", :work)
    ]

    problem(stages, 3, "plan", enabled)
  end

  defp upstream_working do
    stages = [stage(1, "Plan · Done", :done), stage(2, "Code", :work), stage(3, "Deploy", :work), stage(4, "Done", :done)]
    problem(stages, 3, "deploy")
  end

  defp no_downstream,
    do: problem([stage(1, "Review", :review), stage(2, "Deploy · Done", :done), stage(3, "Retro", :work)], 3, "retro")

  def variations do
    [
      %Variation{
        id: :no_upstream,
        description: "Paused — the flow's stage is the first column: nothing to pull from",
        attributes: %{id: "callout-no-upstream", problem: no_upstream()}
      },
      %Variation{
        id: :upstream_review,
        description: "Paused — the column before is a review lane (a push, not a pull)",
        attributes: %{id: "callout-upstream-review", problem: upstream_review()}
      },
      %Variation{
        id: :upstream_working,
        description: "Paused — the column before is another flow's working stage",
        attributes: %{id: "callout-upstream-working", problem: upstream_working()}
      },
      %Variation{
        id: :no_downstream,
        description: "Paused — the flow's stage is the last column: nowhere to land",
        attributes: %{id: "callout-no-downstream", problem: no_downstream()}
      },
      %Variation{
        id: :disabled,
        description: "A disabled flow's problem — the quieter dashed variant; it pauses when turned on",
        attributes: %{id: "callout-disabled", problem: upstream_review(false)}
      },
      %Variation{
        id: :read_only,
        description: "An archived board — no FIX buttons",
        attributes: %{id: "callout-read-only", problem: upstream_review(), read_only?: true}
      },
      %Variation{
        id: :refusal,
        description: "A fix that was refused — the sentence shows inside the callout",
        attributes: %{
          id: "callout-refusal",
          problem: upstream_review(),
          error: Relay.Boards.stage_refusal_message(:invalid_anchor)
        }
      }
    ]
  end
end
