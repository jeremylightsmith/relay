defmodule Storybook.TalkComponents.TalkPane do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.TalkComponents.talk_pane/1
  def render_source, do: :function

  defp event(attrs) do
    Map.merge(%{id: 1, seq: 1, kind: :out, text: "hello", dim: false}, attrs)
  end

  defp base(attrs) do
    Map.merge(
      %{
        id: "talk-pane",
        ref: "DE3",
        title: "Board search",
        seed_summary: "3 fields · no plan yet · 2 runs",
        seed_fields: [
          %{"label" => "description", "value" => "Search box for the board's card list."},
          %{"label" => "acceptance", "value" => "1. Typing filters instantly."},
          %{"label" => "notes", "value" => "2 notes from Jeremy"}
        ],
        seed_open?: false,
        busy?: false,
        events: [
          event(%{id: 1, seq: 1, kind: :user, text: "why is this stuck?"}),
          event(%{id: 2, seq: 2, kind: :tool, text: "Read · lib/relay.ex", dim: true}),
          event(%{
            id: 3,
            seq: 3,
            kind: :out,
            text:
              "It's waiting on the review gate.\n\nThe last run stopped at spec_review because:\n" <>
                "- the plan's Task 2 names a function the code doesn't define\n" <>
                "- two acceptance criteria have no covering task\n" <>
                "- the branch is 3 commits behind main"
          }),
          event(%{id: 4, seq: 4, kind: :out, text: "(a quieter aside)", dim: true}),
          event(%{id: 5, seq: 5, kind: :error, text: "claude exited: rate limited"})
        ]
      },
      attrs
    )
  end

  # RE301 — enough lines to overflow the 548px pane, so the scrollbar (and, in the real app, the
  # open-at-bottom hook) has something to do. Storybook does not load app.js, so the colocated
  # `.TalkAutoscroll` hook does not run here; the story shows the overflow and the newlines.
  defp long_transcript do
    backlog =
      for i <- 1..30 do
        event(%{id: 100 + i, seq: 100 + i, kind: :out, text: "backlog line #{i}", dim: rem(i, 3) == 0})
      end

    base(%{}).events ++ backlog
  end

  def variations do
    [
      %Variation{id: :idle, attributes: base(%{})},
      %Variation{id: :busy, attributes: base(%{id: "talk-pane-busy", busy?: true})},
      %Variation{
        id: :seed_collapsed,
        attributes: base(%{id: "talk-pane-seed-collapsed", events: [], seed_open?: false})
      },
      %Variation{
        id: :seed_expanded,
        attributes: base(%{id: "talk-pane-seed-expanded", events: [], seed_open?: true})
      },
      %Variation{
        id: :long_transcript,
        attributes: base(%{id: "talk-pane-long", events: long_transcript()})
      }
    ]
  end
end
