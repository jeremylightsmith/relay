defmodule Storybook.FlowShapeComponents.BoardOrderStrip do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowShapeComponents.board_order_strip/1
  def render_source, do: :function

  # RE432 — a Shape problem's `columns`: the flow's stage (`:self`), the column that breaks the
  # rule (`:offending`), and the neighbours either side.
  defp column(stage_id, name, type, mark \\ nil), do: %{stage_id: stage_id, name: name, type: type, mark: mark}

  def variations do
    [
      %Variation{
        id: :no_upstream,
        description: "The flow's stage is first — a ? stands for the missing column before it",
        attributes: %{
          id: "strip-no-upstream",
          columns: [column(1, "Triage", :work, :self), column(2, "Backlog", :queue), column(3, "Spec", :planning)]
        }
      },
      %Variation{
        id: :offending,
        description: "The column before is a review lane — dashed amber",
        attributes: %{
          id: "strip-offending",
          columns: [
            column(1, "Spec", :planning),
            column(2, "Spec · Review", :review, :offending),
            column(3, "Plan", :planning, :self),
            column(4, "Plan · Done", :done),
            column(5, "Code", :work)
          ]
        }
      },
      %Variation{
        id: :no_downstream,
        description: "The flow's stage is last — a ? stands for the missing column after it",
        attributes: %{
          id: "strip-no-downstream",
          columns: [column(1, "Review", :review), column(2, "Deploy · Done", :done), column(3, "Retro", :work, :self)]
        }
      }
    ]
  end
end
