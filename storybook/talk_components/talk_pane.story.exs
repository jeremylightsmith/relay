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
          event(%{id: 3, seq: 3, kind: :out, text: "It's waiting on the review gate."}),
          event(%{id: 4, seq: 4, kind: :out, text: "(a quieter aside)", dim: true}),
          event(%{id: 5, seq: 5, kind: :error, text: "claude exited: rate limited"})
        ]
      },
      attrs
    )
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
      }
    ]
  end
end
