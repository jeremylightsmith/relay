defmodule Storybook.FlowSettingsComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("flow_band"), do: [icon: {:fa, "diagram-project", :thin}]
  def entry("copy_flow_panel"), do: [icon: {:fa, "copy", :thin}]
  def entry("add_flow_panel"), do: [icon: {:fa, "plus", :thin}]
  def entry("stage_neighbours"), do: [icon: {:fa, "arrow-right-arrow-left", :thin}]
end
