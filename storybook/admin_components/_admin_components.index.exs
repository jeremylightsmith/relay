defmodule Storybook.AdminComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("user_tabs"), do: [icon: {:fa, "folder-tree", :thin}]
  def entry("plan_badge"), do: [icon: {:fa, "tag", :thin}]
  def entry("outcome_badge"), do: [icon: {:fa, "receipt", :thin}]
  def entry("usage_strip"), do: [icon: {:fa, "grip-lines", :thin}]
  def entry("stacked_bars"), do: [icon: {:fa, "chart-column", :thin}]
end
