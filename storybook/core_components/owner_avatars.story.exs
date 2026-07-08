defmodule Storybook.Components.CoreComponents.OwnerAvatars do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.owner_avatars/1
  def render_source, do: :function

  # `owners` are the card's loaded owner rows (`actor_type` + optional `:user`);
  # `active_owner` is who holds the baton (derived by
  # `Relay.Cards.active_owner_type/1`). The cluster rings the active owner and
  # grays/overlaps paused humans behind an active AI.
  def variations do
    [
      %Variation{
        id: :single_human,
        attributes: %{
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}],
          active_owner: :human
        }
      },
      %Variation{
        id: :two_humans,
        attributes: %{
          owners: [
            %{actor_type: :user, user: %{name: "Dana Kim"}},
            %{actor_type: :user, user: %{name: "Morgan Lee"}}
          ],
          active_owner: :human
        }
      },
      %Variation{
        id: :ai_active_one_paused_human,
        attributes: %{
          owners: [
            %{actor_type: :user, user: %{name: "Dana Kim"}},
            %{actor_type: :agent}
          ],
          active_owner: :ai
        }
      },
      %Variation{
        id: :ai_active_two_paused_humans,
        attributes: %{
          owners: [
            %{actor_type: :user, user: %{name: "Dana Kim"}},
            %{actor_type: :user, user: %{name: "Morgan Lee"}},
            %{actor_type: :agent}
          ],
          active_owner: :ai
        }
      },
      %Variation{
        id: :ai_only,
        attributes: %{
          owners: [%{actor_type: :agent}],
          active_owner: :ai
        }
      },
      %Variation{
        id: :unowned,
        attributes: %{owners: [], active_owner: nil}
      }
    ]
  end
end
