defmodule Storybook.StoryMapComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("story_map_card"), do: [icon: {:fa, "note-sticky", :thin}]
  def entry("inline_name_input"), do: [icon: {:fa, "i-cursor", :thin}]
  def entry("story_map_cell"), do: [icon: {:fa, "table-cells", :thin}]
end
