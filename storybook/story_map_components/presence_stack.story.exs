defmodule Storybook.StoryMapComponents.PresenceStack do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.StoryMapComponents.presence_stack/1
  def render_source, do: :function

  @dana %{user_id: 1, name: "Dana Kim", email: "dana.kim@acme.co", avatar_url: nil}
  @mara %{user_id: 2, name: "Mara Lopez", email: "mara@acme.co", avatar_url: nil}
  @jules %{user_id: 3, name: "Jules Reyes", email: "jules@acme.co", avatar_url: nil}
  @sam %{user_id: 4, name: "Sam Okafor", email: "sam@acme.co", avatar_url: nil}
  @rin %{user_id: 5, name: "Rin Tanaka", email: "rin@acme.co", avatar_url: nil}

  defp crowd do
    [@dana, @mara, @jules, @sam, @rin] ++
      for i <- 6..8, do: %{user_id: i, name: "Person #{i}", email: "p#{i}@acme.co", avatar_url: nil}
  end

  def variations do
    [
      %Variation{
        id: :solo,
        description: "Alone on the map: renders nothing — your own avatar is noise.",
        attributes: %{people: [@dana], current_user_id: 1}
      },
      %Variation{
        id: :two_people,
        description: "You first, then the roster order.",
        attributes: %{people: [@dana, @mara], current_user_id: 1}
      },
      %Variation{
        id: :five_people,
        description: "The cap: five faces, no chip.",
        attributes: %{people: [@dana, @mara, @jules, @sam, @rin], current_user_id: 1}
      },
      %Variation{
        id: :overflow,
        description: "Eight present: five faces and a +3 chip.",
        attributes: %{people: crowd(), current_user_id: 1}
      }
    ]
  end
end
