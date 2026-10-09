defmodule Storybook.FlowShapeComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("shape_callout"), do: [icon: {:fa, "triangle-exclamation", :thin}]
  def entry("board_order_strip"), do: [icon: {:fa, "arrow-right-long", :thin}]
  def entry("paused_flow_banners"), do: [icon: {:fa, "circle-pause", :thin}]
end
