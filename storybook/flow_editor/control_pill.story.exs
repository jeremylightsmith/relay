defmodule Storybook.FlowEditor.ControlPill do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.FlowGraphComponents.control_pill/1
  def render_source, do: :function

  # RE439, card mockup "Editor — fan out / fan in as compact pills": a control node is a compact
  # accent pill — fork or join glyph, FAN OUT / FAN IN tag, name, sub-line. Rendered in flow here
  # (no left/top); on the canvas the graph positions it.
  def variations do
    [
      %Variation{
        id: :fan_out_max,
        description: "A fan-out with MAX PARALLEL set — the sub-line reads `max 3`",
        attributes: %{node: %{key: "review_panel", type: :fan_out, max_parallel: 3}}
      },
      %Variation{
        id: :fan_out_unset,
        description: "A fan-out with no MAX PARALLEL — every branch at once, so no sub-line",
        attributes: %{node: %{key: "review_panel", type: :fan_out, max_parallel: nil}}
      },
      %Variation{
        id: :fan_in,
        description: "A fan-in — it waits for every branch, so it always reads `all must succeed`",
        attributes: %{node: %{key: "review_join", type: :fan_in}}
      },
      %Variation{
        id: :fan_out_selected,
        description: "A selected fan-out carries the accent selection ring",
        attributes: %{node: %{key: "review_panel", type: :fan_out, max_parallel: 3}, selected?: true}
      }
    ]
  end
end
