defmodule Storybook.TalkComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("talk_pane"), do: [icon: {:fa, "terminal", :thin}]
end
