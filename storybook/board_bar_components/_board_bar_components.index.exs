defmodule Storybook.BoardBarComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("board_switcher_menu"), do: [icon: {:fa, "chevron-down", :thin}]
  def entry("board_more_menu"), do: [icon: {:fa, "ellipsis", :thin}]
end
