defmodule Storybook.Components.CoreComponents.SectionLabel do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.section_label/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :default, slots: ["Owners"]},
      %Variation{id: :accent, attributes: %{accent: "text-secondary"}, slots: ["AI Result"]}
    ]
  end
end
