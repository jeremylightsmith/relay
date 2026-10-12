defmodule Storybook.Components.CoreComponents.NoteModeToggle do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.note_mode_toggle/1
  def render_source, do: :function

  # RE358 — the Notes composer's Note | ↪ Steer now toggle, shown above the composer row only while
  # an agent node is working the card. It defaults to Note.
  def variations do
    [
      %Variation{
        id: :note,
        description: "Note mode (the default): the note reaches the agent at its next step.",
        attributes: %{id: "note-mode-toggle-story-note", mode: :note}
      },
      %Variation{
        id: :steer,
        description: "Steer now mode: the composer goes blue and sending stops and restarts the node.",
        attributes: %{id: "note-mode-toggle-story-steer", mode: :steer}
      }
    ]
  end
end
