defmodule Storybook.FlowEditor.InlinePromptTag do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowEditorComponents.inline_prompt_tag/1
  def render_source, do: :function

  # RE444: shared by the editor inspector and the example board's read-only node panel.
  def variations do
    [
      %Variation{
        id: :default,
        description: "Agent node with no subagent — runs its prompt as written",
        attributes: %{id: "inline-tag-demo"}
      }
    ]
  end
end
