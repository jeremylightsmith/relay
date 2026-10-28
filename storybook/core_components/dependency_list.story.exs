defmodule Storybook.Components.CoreComponents.DependencyList do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.CoreComponents.dependency_list/1
  def render_source, do: :function

  # RE474 — the linked stories' `href`: a named capture renders where an anonymous fn would not.
  def card_href(ref), do: "/board/demo?card=" <> ref

  def variations do
    [
      %Variation{
        id: :blocked_by,
        attributes: %{
          id: "story-blocked-by",
          removable: true,
          cards: [
            %{ref: "RE12", title: "Ship the migration", satisfied?: false},
            %{ref: "RE13", title: "Wire the scheduler gate", satisfied?: true}
          ]
        }
      },
      %Variation{
        id: :blocks_read_only,
        attributes: %{
          id: "story-blocks",
          cards: [%{ref: "RE94", title: "Depends on this landing first"}]
        }
      },
      %Variation{id: :empty, attributes: %{id: "story-empty", cards: []}},
      %Variation{
        id: :linked_compact,
        description: "Web rail: each chip links to its card; ✕ sits outside the link",
        attributes: %{
          id: "story-linked",
          removable: true,
          href: &__MODULE__.card_href/1,
          cards: [
            %{ref: "RE12", title: "Ship the migration", satisfied?: false},
            %{ref: "RE13", title: "Wire the scheduler gate", satisfied?: true}
          ]
        }
      },
      %Variation{
        id: :touch_blocked_by,
        description: "Embedded Properties tab: 44px rows, one open and one satisfied blocker",
        attributes: %{
          id: "story-touch-blocked-by",
          variant: :touch,
          removable: true,
          href: &__MODULE__.card_href/1,
          cards: [
            %{ref: "RE490", title: "Sync queue for comments", satisfied?: false},
            %{ref: "RE471", title: "Board switch shows embedded", satisfied?: true}
          ]
        }
      },
      %Variation{
        id: :touch_blocks,
        description: "Embedded Properties tab: the read-only Blocks rows",
        attributes: %{
          id: "story-touch-blocks",
          variant: :touch,
          direction: :blocks,
          href: &__MODULE__.card_href/1,
          cards: [%{ref: "RE495", title: "Draft badge on the board card"}]
        }
      }
    ]
  end
end
