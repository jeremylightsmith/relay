defmodule Schemas.Comment do
  @moduledoc """
  A comment on a card, authored by an actor: a user (`actor_type: :user`
  + `user_id`) or the single Relay AI agent (`actor_type: :agent`, no
  `user_id` — renders as "Relay AI"). Only `body` is user input;
  `card_id`, `actor_type`, `user_id`, and `kind` are set programmatically,
  never cast from input.

  RE427 — a note may carry up to `max_images/0` images (`has_many :images`, ordered by the
  attachment's `position`); a note with images may have a blank body.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @max_images 6

  schema "comments" do
    field :actor_type, Ecto.Enum, values: [:user, :agent]
    field :body, :string
    field :kind, Ecto.Enum, values: [:comment, :question, :changes_requested], default: :comment

    belongs_to :card, Schemas.Card
    belongs_to :user, Schemas.User

    has_many :images, Schemas.Attachment, foreign_key: :comment_id, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @doc "The most images one note may carry (RE427)."
  @spec max_images() :: pos_integer()
  def max_images, do: @max_images

  @doc """
  Validates a comment whose actor fields are already set on the struct;
  only `:body` is cast from input. `image_count` (RE427) is how many images the note
  carries: with at least one the body may be blank, and more than `max_images/0` is an
  error on `:images`.
  """
  def changeset(comment, attrs, image_count \\ 0) do
    comment
    |> cast(attrs, [:body])
    |> validate_required(required_fields(image_count))
    |> validate_image_count(image_count)
    |> default_blank_body(image_count)
    |> validate_actor_user()
    |> foreign_key_constraint(:card_id)
    |> foreign_key_constraint(:user_id)
  end

  defp required_fields(0), do: [:card_id, :actor_type, :body]
  defp required_fields(_image_count), do: [:card_id, :actor_type]

  defp validate_image_count(changeset, image_count) when image_count > @max_images,
    do: add_error(changeset, :images, "can carry at most #{@max_images} images")

  defp validate_image_count(changeset, _image_count), do: changeset

  # An image-only note has no text, but `comments.body` is NOT NULL: store it as "".
  defp default_blank_body(changeset, 0), do: changeset

  defp default_blank_body(changeset, _image_count) do
    if get_field(changeset, :body), do: changeset, else: put_change(changeset, :body, "")
  end

  defp validate_actor_user(changeset) do
    case {get_field(changeset, :actor_type), get_field(changeset, :user_id)} do
      {:user, nil} -> add_error(changeset, :user_id, "can't be blank")
      {:agent, user_id} when not is_nil(user_id) -> add_error(changeset, :user_id, "must be empty for the AI agent")
      _other -> changeset
    end
  end
end
