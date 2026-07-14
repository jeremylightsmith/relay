defmodule Schemas.UserApiToken do
  @moduledoc """
  A user-scoped bearer token for the native app's JSON calls (RLY-80). Mirrors
  `Schemas.ApiKey`, but a user may hold several (one per signed-in device), so
  there is no unique index on `user_id`. The raw token is
  `relayu_<token_prefix>_<secret>`: `token_prefix` is a public random id stored in
  the clear (lookup), the secret only as a SHA-256 hash in `token_hash`
  (`last_four` supports a masked display). `context` names the client that minted
  it ("mobile"). All fields are set programmatically by `Relay.Accounts`, never
  cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "user_api_tokens" do
    field :context, :string
    field :token_prefix, :string
    field :token_hash, :string
    field :last_four, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, Schemas.User

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built token row (nothing is cast from input)."
  def changeset(user_api_token) do
    user_api_token
    |> change()
    |> validate_required([:user_id, :context, :token_prefix, :token_hash, :last_four])
    |> unique_constraint(:token_prefix)
    |> foreign_key_constraint(:user_id)
  end
end
