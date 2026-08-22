defmodule Storybook.Components.CoreComponents.DependencyList do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.dependency_list/1
  def render_source, do: :function

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
      %Variation{id: :empty, attributes: %{id: "story-empty", cards: []}}
    ]
  end
end
