defmodule Storybook.Components.CoreComponents.PageHeading do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.page_heading/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :default, slots: ["Stages"]},
      %Variation{id: :with_margin, attributes: %{class: "mb-1.5"}, slots: ["Flow settings"]}
    ]
  end
end
