defmodule Storybook.Components.CoreComponents.CopyButton do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.copy_button/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :default,
        attributes: %{id: "copy-button-story-default", text: "bin/relay execute"}
      },
      %Variation{
        id: :branch_name,
        description: "The drawer rail's branch row — copies the full name, however long.",
        attributes: %{
          id: "copy-button-story-branch",
          text: "re-324-fix-long-links-including-prs-and-this-is-a-very-long-branch-name",
          label: "Copy branch name"
        }
      }
    ]
  end
end
