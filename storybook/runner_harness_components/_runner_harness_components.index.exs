defmodule Storybook.RunnerHarnessComponents do
  @moduledoc false
  use PhoenixStorybook.Index

  def folder_open?, do: true

  def entry("runner_harnesses"), do: [icon: {:fa, "gauge", :thin}]
end
