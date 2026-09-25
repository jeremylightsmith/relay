defmodule Storybook.ValueStream.BatonLegend do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.ValueStreamComponents.baton_legend/1
  def render_source, do: :function

  def variations, do: [%Variation{id: :default, attributes: %{}}]
end
