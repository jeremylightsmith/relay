defmodule RelayWeb.Api.CardJSON do
  @moduledoc "JSON representation of cards (shared across API controllers)."

  alias Relay.Cards

  @doc "The shared card shape. `board` supplies the ref + key."
  def data(board, card) do
    %{
      id: card.id,
      ref: Cards.ref(board, card),
      title: card.title,
      tag: card.tag,
      status: card.status,
      progress: card.progress,
      stage_id: card.stage_id,
      owners: Enum.map(card.owners, &owner/1),
      active_owner: Cards.active_owner_type(card)
    }
  end

  @doc "The shared stage shape."
  def stage(stage) do
    %{id: stage.id, name: stage.name, category: stage.category, owner: stage.owner, position: stage.position}
  end

  defp owner(%Schemas.CardOwner{actor_type: :agent}), do: %{type: "agent", name: "Relay AI"}

  defp owner(%Schemas.CardOwner{actor_type: :user, user: user}) do
    %{type: "user", id: user.id, name: user.name || user.email}
  end
end
