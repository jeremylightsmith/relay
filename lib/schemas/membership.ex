defmodule Schemas.Membership do
  @moduledoc """
  A person's membership on a board (RLY-32). There are no roles — a
  membership simply means "this user has full access to this board".

  `user_id` is **nullable**: a membership with `user_id == nil` is an
  *invited* row (a pre-authorization created from an email address); it
  resolves — `user_id` gets set — the first time that email signs in
  (`Relay.Members.resolve_invites_for_user/1`) or immediately when the
  email already belongs to a registered user. `email` is the normalized
  (downcased/trimmed) invite address. `board_id`/`user_id` are set
  programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "board_members" do
    field :email, :string

    belongs_to :board, Schemas.Board
    belongs_to :user, Schemas.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a programmatically-built membership: only `:email` is cast
  (normalized to trimmed/downcased); `board_id`/`user_id` must already be set
  on the struct. The `(board_id, email)` unique index surfaces as an `:email`
  error so `Relay.Members.invite/2` can translate it to `:already_member`.
  """
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:email])
    |> update_change(:email, &normalize/1)
    |> validate_required([:email])
    |> unique_constraint(:email, name: :board_members_board_id_email_index)
    |> foreign_key_constraint(:board_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "True when the membership is an unresolved invite (no user attached yet)."
  def invited?(%__MODULE__{user_id: nil}), do: true
  def invited?(%__MODULE__{}), do: false

  defp normalize(nil), do: nil
  defp normalize(email), do: email |> String.trim() |> String.downcase()
end
