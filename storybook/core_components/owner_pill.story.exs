defmodule Storybook.Components.CoreComponents.OwnerPill do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.owner_pill/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :human, attributes: %{owner: :human}},
      %Variation{id: :ai, attributes: %{owner: :ai}}
    ]
  end
end
