defmodule Storybook.StoryMapComponents.StoryMapCell do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.StoryMapComponents.story_map_cell/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :empty_with_add, attributes: attrs(%{})},
      %Variation{
        id: :cards_with_add,
        attributes: attrs(%{cards: [card(101, "Add SSO"), card(102, "Reset password")]})
      },
      %Variation{
        id: :composer_open,
        attributes:
          attrs(%{
            cards: [card(101, "Add SSO")],
            composing: true,
            compose_form: Phoenix.Component.to_form(%{"title" => ""}, as: :card)
          })
      }
    ]
  end

  defp attrs(overrides) do
    Map.merge(
      %{
        column: %{
          key: "t:10",
          activity: %Schemas.StoryActivity{id: 1, board_id: 1, name: "Onboard & access", position: 1},
          task: %Schemas.StoryTask{id: 10, board_id: 1, story_activity_id: 1, name: "Sign in", position: 1},
          no_task?: false,
          bare?: false,
          draft?: false,
          last_of_activity?: true
        },
        lane: %{key: "r:100", release: %Schemas.Release{id: 100, board_id: 1, name: "MVP", position: 1}, count: 0},
        cards: [],
        board: %Schemas.Board{id: 1, key: "RLY", slug: "my-board", name: "My board"},
        stages: stages(),
        stalled_ids: MapSet.new(),
        column_index: 0,
        lane_index: 0
      },
      overrides
    )
  end

  # Three stages so Relay.Cards.done?/2 sees a real terminal column — a card parked in the
  # only stage would otherwise derive as Done and every variation would render green.
  defp stages do
    [
      %Schemas.Stage{id: 1, board_id: 1, name: "Spec", position: 1, category: :planning, type: :planning},
      %Schemas.Stage{id: 2, board_id: 1, name: "Code", position: 2, category: :in_progress, type: :work},
      %Schemas.Stage{id: 3, board_id: 1, name: "Done", position: 3, category: :complete, type: :done}
    ]
  end

  defp card(id, title) do
    %Schemas.Card{
      id: id,
      board_id: 1,
      ref_number: id,
      title: title,
      stage_id: 2,
      status: :ready,
      owners: [],
      sub_tasks: []
    }
  end
end
