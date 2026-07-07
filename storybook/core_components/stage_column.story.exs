defmodule Storybook.Components.CoreComponents.StageColumn do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.stage_column/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :empty_human,
        attributes: %{id: "story-stage-backlog", name: "Backlog", owner: :human}
      },
      %Variation{
        id: :empty_ai,
        attributes: %{id: "story-stage-plan", name: "Plan", owner: :ai}
      },
      %Variation{
        id: :with_content,
        attributes: %{id: "story-stage-code", name: "Code", owner: :ai},
        slots: [
          ~s(<div class="card bg-base-100 p-3 text-sm shadow-sm">A future card</div>)
        ]
      }
    ]
  end
end
