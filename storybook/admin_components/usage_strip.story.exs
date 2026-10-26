defmodule Storybook.AdminComponents.UsageStrip do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.AdminComponents.usage_strip/1
  def render_source, do: :function

  # RE475, card mockups "Usage tab — people (blue) + their agents (violet)" (the table's `:sm`
  # Last 14 days strip) and "User panel — visits, time, agent runs, shipped" (the panel's `:lg`).
  @mixed [:none, :none, :human, :both, :none, :agent, :agent, :none, :human, :both, :human, :none, :agent, :both]

  def variations do
    [
      %Variation{
        id: :sm_mixed,
        description: "Table strip: visited, agents ran, both, neither",
        attributes: %{days: @mixed, size: :sm}
      },
      %Variation{
        id: :lg_mixed,
        description: "Panel strip",
        attributes: %{days: @mixed, size: :lg}
      },
      %Variation{
        id: :all_none,
        description: "A user with no activity",
        attributes: %{days: List.duplicate(:none, Hamaca.Usage.strip_days()), size: :sm}
      }
    ]
  end
end
