defmodule Storybook.Components.CoreComponents.Avatar do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  # A 1×1 blue PNG, inlined so the photo state renders without a network fetch.
  @photo "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

  def function, do: &RelayWeb.CoreComponents.avatar/1
  def render_source, do: :function

  # The one avatar (RLY-90): photo when we have one, initials otherwise,
  # the violet dot mark for the AI. tint=:identity hashes the email; tint=:role
  # is the fixed human-blue.
  def variations do
    [
      %Variation{
        id: :photo,
        attributes: %{src: @photo, name: "Dana Kim", email: "dana@acme.co", size: 44}
      },
      %Variation{
        id: :initials_from_name,
        attributes: %{name: "Ada Lovelace", email: "ada@acme.co", size: 44}
      },
      %Variation{
        id: :initials_from_email,
        attributes: %{email: "dana.kim@acme.co", size: 44}
      },
      %Variation{id: :ai_mark, attributes: %{actor: :ai, size: 22}},
      %Variation{
        id: :role_tint,
        attributes: %{name: "Dana Kim", tint: :role, size: 22}
      },
      %Variation{
        id: :ringed,
        attributes: %{name: "Dana Kim", tint: :role, ring: "var(--color-primary)", size: 22}
      },
      %Variation{
        id: :grayed,
        attributes: %{name: "Dana Kim", tint: :role, grayed: true, size: 22}
      },
      %VariationGroup{
        id: :sizes_in_use,
        description: "22 owner cluster / reassign · 24 member stack · 28 timeline / top bar · 34 board settings",
        variations:
          for size <- [22, 24, 28, 34] do
            %Variation{
              id: :"size_#{size}",
              attributes: %{name: "Dana Kim", email: "dana@acme.co", size: size}
            }
          end
      }
    ]
  end
end
