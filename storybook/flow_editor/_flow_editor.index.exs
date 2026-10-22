defmodule Storybook.FlowEditor do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("control_pill"), do: [icon: {:fa, "code-fork", :thin}]
  def entry("fan_out_inspector"), do: [icon: {:fa, "sitemap", :thin}]
  def entry("fan_in_inspector"), do: [icon: {:fa, "code-merge", :thin}]
  def entry("inline_prompt_tag"), do: [icon: {:fa, "tag", :thin}]
  def entry("prompt_preview"), do: [icon: {:fa, "file-lines", :thin}]
  def entry("prompt_sheet"), do: [icon: {:fa, "expand", :thin}]
end
