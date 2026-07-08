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
    %{
      id: stage.id,
      name: stage.name,
      category: stage.category,
      owner: stage.owner,
      position: stage.position,
      approval_gate: stage.approval_gate,
      reject_to_stage_id: stage.reject_to_stage_id
    }
  end

  def index(%{board: board, cards: cards}) do
    %{data: Enum.map(cards, &data(board, &1))}
  end

  def show(%{board: board, card: card, timeline: timeline}) do
    %{
      data:
        board
        |> data(card)
        |> Map.put(:description, card.description)
        |> Map.put(:timeline, Enum.map(timeline, &entry/1))
    }
  end

  def comment(%{comment: comment}) do
    %{data: entry(comment)}
  end

  defp entry(%Schemas.Comment{} = c) do
    %{kind: "comment", body: c.body, author: author(c), inserted_at: c.inserted_at}
  end

  defp entry(%Schemas.Activity{} = a) do
    %{kind: "activity", type: a.type, meta: a.meta, author: author(a), inserted_at: a.inserted_at}
  end

  defp author(%{actor_type: :agent}), do: %{type: "agent", name: "Relay AI"}
  defp author(%{actor_type: :user, user: user}), do: %{type: "user", id: user.id, name: user.name || user.email}

  defp owner(%Schemas.CardOwner{actor_type: :agent}), do: %{type: "agent", name: "Relay AI"}

  defp owner(%Schemas.CardOwner{actor_type: :user, user: user}) do
    %{type: "user", id: user.id, name: user.name || user.email}
  end
end
