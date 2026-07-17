defmodule Storybook.RunComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("run_status_strip"), do: [icon: {:fa, "wave-pulse", :thin}]
  def entry("run_mini_graph"), do: [icon: {:fa, "chart-gantt", :thin}]
  def entry("run_node_timeline"), do: [icon: {:fa, "list-timeline", :thin}]
  def entry("run_state_banner"), do: [icon: {:fa, "flag", :thin}]
  def entry("run_history"), do: [icon: {:fa, "clock-rotate-left", :thin}]
end
