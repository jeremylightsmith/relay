defmodule Storybook.CoreComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("back"), do: [icon: {:fa, "circle-left", :thin}]
  def entry("board_card"), do: [icon: {:fa, "note-sticky", :thin}]
  def entry("button"), do: [icon: {:fa, "rectangle-ad", :thin}]
  def entry("error"), do: [icon: {:fa, "circle-exclamation", :thin}]
  def entry("flash"), do: [icon: {:fa, "bolt", :thin}]
  def entry("header"), do: [icon: {:fa, "heading", :thin}]
  def entry("icon"), do: [icon: {:fa, "icons", :thin}]
  def entry("input"), do: [icon: {:fa, "input-text", :thin}]
  def entry("list"), do: [icon: {:fa, "list", :thin}]
  def entry("owner_avatars"), do: [icon: {:fa, "user-group", :thin}]
  def entry("owner_pill"), do: [icon: {:fa, "tag", :thin}]
  def entry("section_label"), do: [icon: {:fa, "heading", :thin}]
  def entry("stage_column"), do: [icon: {:fa, "table-columns", :thin}]
  def entry("table"), do: [icon: {:fa, "table", :thin}]
end
