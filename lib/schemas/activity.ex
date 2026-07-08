defmodule Schemas.Activity do
  @moduledoc """
  One entry in a card's activity log: what happened (`type`), free-form
  details (`meta`, a jsonb map with STRING keys — e.g.
  `%{"from_stage" => "Spec", "to_stage" => "Code"}`), and who did it —
  a user (`actor_type: :user` + `user_id`) or the Relay AI agent
  (`actor_type: :agent`, no `user_id`). All fields are set
  programmatically by `Relay.Activity.log/2`, never cast from input.
  `:commented` is reserved for future feeds/API use (MMF 09/16) —
  nothing emits it in MMF 07.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @types [:created, :moved, :status_changed, :owners_changed, :commented, :approved, :rejected]

  schema "activities" do
    field :type, Ecto.Enum, values: @types
    field :meta, :map, default: %{}
    field :actor_type, Ecto.Enum, values: [:user, :agent]

    belongs_to :card, Schemas.Card
    belongs_to :user, Schemas.User

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built activity entry."
  def changeset(activity) do
    activity
    |> change()
    |> validate_required([:card_id, :type, :actor_type])
    |> validate_actor_user()
    |> foreign_key_constraint(:card_id)
    |> foreign_key_constraint(:user_id)
  end

  defp validate_actor_user(changeset) do
    case {get_field(changeset, :actor_type), get_field(changeset, :user_id)} do
      {:user, nil} -> add_error(changeset, :user_id, "can't be blank")
      {:agent, user_id} when not is_nil(user_id) -> add_error(changeset, :user_id, "must be empty for the AI agent")
      _other -> changeset
    end
  end
end
