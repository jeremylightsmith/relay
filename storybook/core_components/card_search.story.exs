defmodule Storybook.Components.CoreComponents.CardSearch do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.card_search/1
  def render_source, do: :function

  defp row(ref, title, stage, archived \\ false) do
    %{ref: ref, title: title, stage: stage, archived: archived, path: "/board/demo?card=#{ref}"}
  end

  def variations do
    [
      %Variation{id: :empty, attributes: %{query: "", results: []}},
      %Variation{
        id: :with_results,
        attributes: %{
          query: "search",
          results: [
            row("RLY198", "Search for a card by ref or title", "Spec"),
            row("RLY12", "Search reindex job keeps failing", "Code"),
            row("RLY4", "Archive search results", "Done", true)
          ]
        }
      },
      %Variation{id: :no_match, attributes: %{query: "zzzznotarealcard", results: []}},
      %Variation{
        id: :at_limit,
        attributes: %{
          query: "widget",
          limit: 2,
          results: [row("RLY1", "Widget one", "Backlog"), row("RLY2", "Widget two", "Code")]
        }
      }
    ]
  end
end
