defmodule Storybook.SetupComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("setup_checklist"), do: [icon: {:fa, "list-check", :thin}]
  def entry("setup_panel"), do: [icon: {:fa, "table-columns", :thin}]
end
