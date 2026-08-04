defmodule Storybook.Components.CoreComponents.MetaLabel do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.meta_label/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :default, slots: ["agent"]},
      %Variation{id: :ai_tone, attributes: %{tone: "text-secondary"}, slots: ["AI"]},
      %Variation{id: :human_tone, attributes: %{tone: "text-primary"}, slots: ["human"]}
    ]
  end
end
