defmodule Storybook.Components.CoreComponents.DoneWeekMarker do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.CoreComponents.done_week_marker/1
  def render_source, do: :function

  def template do
    """
    <div class="w-[240px] flex flex-col gap-2">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :this_week,
        description:
          "RE504 — the Done column's first marker (card mockup \"A — load 4 weeks at a time\"): " <>
            "This week, its range, a hairline and the week's card count; flush, no top margin",
        attributes: %{
          id: "story-week-this",
          title: "This week",
          range: "Nov 2 – 8",
          count: 3,
          first: true,
          "data-week-start": "2026-11-02"
        }
      },
      %Variation{
        id: :last_week,
        description: "A later marker: Last week keeps its range and gets 6px of top margin",
        attributes: %{
          id: "story-week-last",
          title: "Last week",
          range: "Oct 26 – Nov 1",
          count: 2,
          "data-week-start": "2026-10-26"
        }
      },
      %Variation{
        id: :older_week,
        description: "An older week is titled by its range alone (no range element)",
        attributes: %{id: "story-week-older", title: "Oct 12 – 18", count: 1, "data-week-start": "2026-10-12"}
      },
      %Variation{
        id: :pager_row,
        description: "as=\"li\": the same marker as a pager compact-row list item",
        template: """
        <ul class="border-t border-base-300">
          <.psb-variation/>
        </ul>
        """,
        attributes: %{
          id: "story-week-pager",
          as: "li",
          title: "This week",
          range: "Nov 2 – 8",
          count: 3,
          first: true,
          "data-week-start": "2026-11-02"
        }
      }
    ]
  end
end
