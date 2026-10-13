defmodule Storybook.ExampleBoardComponents.ExampleBadges do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.ExampleBoardComponents.example_badges/1
  def render_source, do: :function

  # RE444: the example board header's `public` and `read-only` badges.
  def variations do
    [%Variation{id: :default, attributes: %{}}]
  end
end
