defmodule Storybook.Components.CoreComponents.CompactCardRow do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.compact_card_row/1
  def render_source, do: :function

  def template do
    """
    <ul class="w-[360px] border-t border-base-300">
      <.psb-variation/>
    </ul>
    """
  end

  def variations do
    [
      %Variation{
        id: :done,
        description: "RE377 — a :ready card at the terminal stage: green Done dot",
        attributes: %{id: "story-compact-row-done", ref: "RE376", title: "Ship the pager", status: :ready, done: true}
      },
      %Variation{
        id: :working_ai,
        description: "An agent is working the card: violet dot",
        attributes: %{
          id: "story-compact-row-working",
          ref: "RE377",
          title: "Collapsed stage stays a page",
          status: :working,
          active_owner: :ai
        }
      },
      %Variation{
        id: :needs_input,
        description: "Blocked on a human: amber dot",
        attributes: %{
          id: "story-compact-row-needs-input",
          ref: "RE378",
          title: "Pick the chip glyph",
          status: :needs_input,
          active_owner: :human
        }
      },
      %Variation{
        id: :human_baton,
        description: "A human holds the baton, nothing running: blue dot",
        attributes: %{
          id: "story-compact-row-human",
          ref: "RE379",
          title: "Review the mockup",
          status: :ready,
          active_owner: :human
        }
      },
      %Variation{
        id: :long_title_truncates,
        description: "A long title truncates onto one ellipsised line — the row never wraps",
        attributes: %{
          id: "story-compact-row-long",
          ref: "RE380",
          title:
            "A very long card title that must never wrap onto a second line in the compact " <>
              "row list of a collapsed stage page on a phone-width screen",
          status: :ready,
          active_owner: :ai
        }
      }
    ]
  end
end
