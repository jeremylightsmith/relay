defmodule Storybook.AgentsSettingsComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("agents_table"), do: [icon: {:fa, "table-list", :thin}]
  def entry("agent_form"), do: [icon: {:fa, "pen-to-square", :thin}]
  def entry("harness_card"), do: [icon: {:fa, "terminal", :thin}]
  def entry("harness_form"), do: [icon: {:fa, "sliders", :thin}]
end
