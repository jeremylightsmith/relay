defmodule Storybook.StagePickerComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("stage_picker"), do: [icon: {:fa, "list-tree", :thin}]
end
