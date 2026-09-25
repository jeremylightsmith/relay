defmodule Storybook.ValueStream.LeadBar do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.ValueStreamComponents.lead_bar/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :averaged, attributes: %{baton: %{agent: 5_400, human: 46_800, nobody: 104_400}, total: "1.8d"}},
      %Variation{
        id: :agent_only,
        attributes: %{id: "vs-lead-bar-agent-only", baton: %{agent: 600, human: 0, nobody: 0}, total: "10m"}
      }
    ]
  end
end
