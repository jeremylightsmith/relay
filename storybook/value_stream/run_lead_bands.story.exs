defmodule Storybook.ValueStream.RunLeadBands do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias RelayWeb.ValueStreamFlowLayout, as: FlowLayout

  def function, do: &RelayWeb.ValueStreamComponents.run_lead_bands/1
  def render_source, do: :function

  def variations do
    summary = %{value_add: 2_040.0, checking: 3_300.0, rework: 1_980.0, wait: 660.0, process: 5_340.0, wall: 7_980.0}
    [%Variation{id: :code_flow, attributes: %{bands: FlowLayout.bands(summary)}}]
  end
end
