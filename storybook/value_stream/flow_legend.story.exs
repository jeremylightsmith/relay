defmodule Storybook.ValueStream.FlowLegend do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.ValueStreamComponents.flow_legend/1
  def render_source, do: :function

  def variations, do: [%Variation{id: :code_flow, attributes: %{runs: 128}}]
end
