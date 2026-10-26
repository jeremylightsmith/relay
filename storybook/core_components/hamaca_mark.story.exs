defmodule Storybook.Components.CoreComponents.HamacaMark do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.CoreComponents.hamaca_mark/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :nav, attributes: %{class: "h-[22px]"}},
      %Variation{id: :hero, attributes: %{class: "h-[52px]"}},
      %Variation{
        id: :on_neutral,
        description: "The cut-through seams read on the fixed-dark neutral band",
        attributes: %{class: "h-[52px]"},
        template: """
        <div class="rounded-xl p-6" style="background:var(--color-neutral);">
          <.psb-variation/>
        </div>
        """
      }
    ]
  end
end
