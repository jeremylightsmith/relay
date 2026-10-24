defmodule Storybook.AdminComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("user_tabs"), do: [icon: {:fa, "folder-tree", :thin}]
end
