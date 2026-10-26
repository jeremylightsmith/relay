defmodule Storybook.FreeBoardComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("free_board_dialog"), do: [icon: {:fa, "lock-open", :thin}]
  def entry("make_editable_confirm"), do: [icon: {:fa, "circle-check", :thin}]
end
