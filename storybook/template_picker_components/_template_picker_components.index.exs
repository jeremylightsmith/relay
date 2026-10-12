defmodule Storybook.TemplatePickerComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("template_picker"), do: [icon: {:fa, "table-columns", :thin}]
end
