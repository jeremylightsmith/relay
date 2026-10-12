defmodule Storybook.FlowEditor do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("control_pill"), do: [icon: {:fa, "code-fork", :thin}]
  def entry("fan_out_inspector"), do: [icon: {:fa, "sitemap", :thin}]
  def entry("fan_in_inspector"), do: [icon: {:fa, "code-merge", :thin}]
end
