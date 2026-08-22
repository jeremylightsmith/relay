defmodule Storybook.CoreComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("avatar"), do: [icon: {:fa, "circle-user", :thin}]
  def entry("back"), do: [icon: {:fa, "circle-left", :thin}]
  def entry("board_card"), do: [icon: {:fa, "note-sticky", :thin}]
  def entry("board_view_tabs"), do: [icon: {:fa, "table-columns", :thin}]
  def entry("button"), do: [icon: {:fa, "rectangle-ad", :thin}]
  def entry("card_search"), do: [icon: {:fa, "magnifying-glass", :thin}]
  def entry("controls"), do: [icon: {:fa, "sliders", :thin}]
  def entry("dependency_list"), do: [icon: {:fa, "link", :thin}]
  def entry("error"), do: [icon: {:fa, "circle-exclamation", :thin}]
  def entry("flash"), do: [icon: {:fa, "bolt", :thin}]
  def entry("header"), do: [icon: {:fa, "heading", :thin}]
  def entry("icon"), do: [icon: {:fa, "icons", :thin}]
  def entry("image_lightbox"), do: [icon: {:fa, "magnifying-glass-plus", :thin}]
  def entry("input"), do: [icon: {:fa, "input-text", :thin}]
  def entry("list"), do: [icon: {:fa, "list", :thin}]
  def entry("member_stack"), do: [icon: {:fa, "people-group", :thin}]
  def entry("meta_label"), do: [icon: {:fa, "tag", :thin}]
  def entry("modal_scrim"), do: [icon: {:fa, "layer-group", :thin}]
  def entry("owner_avatars"), do: [icon: {:fa, "user-group", :thin}]
  def entry("owner_pill"), do: [icon: {:fa, "tag", :thin}]
  def entry("page_heading"), do: [icon: {:fa, "heading", :thin}]
  def entry("section_label"), do: [icon: {:fa, "heading", :thin}]
  def entry("stage_column"), do: [icon: {:fa, "table-columns", :thin}]
  def entry("table"), do: [icon: {:fa, "table", :thin}]
end
