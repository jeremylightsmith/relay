defmodule Storybook.ExampleBoardComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("example_badges"), do: [icon: {:fa, "lock", :thin}]
  def entry("example_banner"), do: [icon: {:fa, "flag", :thin}]
  def entry("example_intro"), do: [icon: {:fa, "circle-info", :thin}]
  def entry("wip_explainer"), do: [icon: {:fa, "gauge", :thin}]
  def entry("example_flow"), do: [icon: {:fa, "diagram-project", :thin}]
  def entry("node_panel"), do: [icon: {:fa, "rectangle-list", :thin}]
  def entry("example_card_detail"), do: [icon: {:fa, "window-maximize", :thin}]
end
