defmodule Storybook.StoryMapComponents.StoryMapColumnHeader do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.StoryMapComponents.story_map_column_header/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :idle, attributes: attrs(%{})},
      %Variation{
        id: :renaming,
        attributes: attrs(%{edit: {:task, 10}, edit_name: "Sign in with SSO"})
      },
      %Variation{
        id: :delete_blocked,
        attributes: attrs(%{column: column(%{count: 3})})
      },
      %Variation{id: :no_task_placeholder, attributes: attrs(%{column: no_task_column()})},
      %Variation{id: :read_only, attributes: attrs(%{read_only: true})}
    ]
  end

  defp attrs(overrides) do
    Map.merge(
      %{
        column: column(%{}),
        index: 0,
        draft_name: "",
        edit: nil,
        edit_name: "",
        read_only: false
      },
      overrides
    )
  end

  defp column(overrides) do
    Map.merge(
      %{
        key: "t:10",
        activity: %Schemas.StoryActivity{id: 1, board_id: 1, name: "Onboard & access", position: 1},
        task: %Schemas.StoryTask{id: 10, board_id: 1, story_activity_id: 1, name: "Sign in", position: 1},
        no_task?: false,
        bare?: false,
        draft?: false,
        last_of_activity?: true,
        count: 0
      },
      overrides
    )
  end

  defp no_task_column do
    %{column(%{}) | key: "nt:1", task: nil, no_task?: true, bare?: false}
  end
end
