defmodule Storybook.Components.CoreComponents.MemberStack do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.member_stack/1
  def render_source, do: :function

  # The boards-home overlapping member avatar stack (RLY-32): up to `limit`
  # colored-initials circles, then a +N overflow chip. Invited members show
  # email-derived initials.
  def variations do
    [
      %Variation{
        id: :two_members,
        attributes: %{
          members: [
            %{email: "ada@example.com", user: %{name: "Ada Lovelace"}},
            %{email: "morgan@example.com", user: %{name: "Morgan Lee"}}
          ]
        }
      },
      %Variation{
        id: :with_invited,
        attributes: %{
          members: [
            %{email: "ada@example.com", user: %{name: "Ada Lovelace"}},
            %{email: "pending@example.com", user: nil}
          ]
        }
      },
      %Variation{
        id: :overflow,
        attributes: %{
          limit: 4,
          members: for(i <- 1..7, do: %{email: "member#{i}@example.com", user: %{name: "Member #{i}"}})
        }
      }
    ]
  end
end
