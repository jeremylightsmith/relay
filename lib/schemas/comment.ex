defmodule Schemas.Comment do
  @moduledoc """
  A comment on a card, authored by an actor: a user (`actor_type: :user`
  + `user_id`) or the single Relay AI agent (`actor_type: :agent`, no
  `user_id` — renders as "Relay AI"). Only `body` is user input;
  `card_id`, `actor_type`, `user_id`, and `kind` are set programmatically,
  never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "comments" do
    field :actor_type, Ecto.Enum, values: [:user, :agent]
    field :body, :string
    field :kind, Ecto.Enum, values: [:comment, :question, :changes_requested], default: :comment

    belongs_to :card, Schemas.Card
    belongs_to :user, Schemas.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a comment whose actor fields are already set on the struct;
  only `:body` is cast from input.
  """
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body])
    |> validate_required([:card_id, :actor_type, :body])
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
