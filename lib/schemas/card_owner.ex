defmodule Schemas.CardOwner do
  @moduledoc """
  One owner of a card — the "actor" concept: either a user
  (`actor_type: :user` + `user_id`) or the single Relay AI agent
  (`actor_type: :agent`, no `user_id`). A card has many owners; the active
  owner is derived by `Relay.Cards.active_owner_type/1`, never stored.
  All fields are set programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "card_owners" do
    field :actor_type, Ecto.Enum, values: [:user, :agent]

    belongs_to :card, Schemas.Card
    belongs_to :user, Schemas.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a programmatically-built owner row: `card_id` and `actor_type`
  are required; `user_id` is required iff the actor is a `:user` and must
  be absent for the `:agent`.
  """
  def changeset(card_owner) do
    card_owner
    |> change()
    |> validate_required([:card_id, :actor_type])
    |> validate_actor_user()
    |> foreign_key_constraint(:card_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:card_id, :actor_type, :user_id], name: :card_owners_user_owner_index)
    |> unique_constraint([:card_id, :actor_type], name: :card_owners_agent_owner_index)
  end

  defp validate_actor_user(changeset) do
    case {get_field(changeset, :actor_type), get_field(changeset, :user_id)} do
      {:user, nil} -> add_error(changeset, :user_id, "can't be blank")
      {:agent, user_id} when not is_nil(user_id) -> add_error(changeset, :user_id, "must be empty for the AI agent")
      _other -> changeset
    end
  end
end
