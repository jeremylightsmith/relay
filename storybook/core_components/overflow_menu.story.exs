defmodule Storybook.Components.CoreComponents.OverflowMenu do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.CoreComponents.overflow_menu/1
  def render_source, do: :function

  # The ⋯ menu on a public-board idea (RE510, card mockup "Public board — ⋯ Report…", state 1).
  # Focus the button to open it.
  def variations do
    [
      %Variation{
        id: :report_idea,
        description: "A public idea's ⋯ menu with its one Report item",
        attributes: %{id: "story-overflow-menu"},
        slots: [
          """
          <li><button type="button" role="menuitem" class="gap-2"><span aria-hidden="true">⚑</span>Report this idea</button></li>
          """
        ]
      }
    ]
  end
end
