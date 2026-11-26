defmodule Schemas.User do
  @moduledoc """
  A person who signed in. Identity is keyed on `provider_uid` first (the
  provider's stable `sub` claim — Google or Apple), then on the normalized
  verified `email` (see `Hamaca.Accounts.upsert_user_from_provider/2`).
  `provider` and `provider_uid` record the first provider the user signed in
  with; they are set programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :provider, :string
    field :provider_uid, :string
    field :setup_explanations_hidden, :boolean, default: false
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  # RE475 — the dev sign-in (`GET /dev/login`) and the seed script's accounts. Not real people, so
  # usage neither tracks nor counts them.
  @synthetic_providers ["dev", "seed"]

  @doc "The providers of synthetic (dev and seed) accounts — the ONE list usage skips and filters."
  @spec synthetic_providers() :: [String.t()]
  def synthetic_providers, do: @synthetic_providers

  @doc "True for a dev or seed account (`synthetic_providers/0`)."
  @spec synthetic?(t()) :: boolean()
  def synthetic?(%__MODULE__{provider: provider}), do: provider in @synthetic_providers

  @deleted_name "Deleted user"

  @doc "The display name a deleted account's comments, votes and ideas show — the ONE definition."
  @spec deleted_name() :: String.t()
  def deleted_name, do: @deleted_name

  @doc "True for a deleted account's tombstone (`deleted_at` set)."
  @spec deleted?(t()) :: boolean()
  def deleted?(%__MODULE__{deleted_at: deleted_at}), do: not is_nil(deleted_at)

  @doc """
  Tombstones `user` (RE509): the name becomes `deleted_name/0`, the avatar and `provider_uid` are
  cleared, the email becomes the unique, already-lowercase `deleted+<id>@users.invalid` (so the
  person can sign up again with the old address), and `deleted_at` is stamped. `provider` is kept.
  Set programmatically — nothing is cast.
  """
  @spec deletion_changeset(t()) :: Ecto.Changeset.t()
  def deletion_changeset(%__MODULE__{id: id} = user) do
    change(user,
      name: @deleted_name,
      avatar_url: nil,
      email: "deleted+#{id}@users.invalid",
      provider_uid: nil,
      deleted_at: DateTime.truncate(DateTime.utc_now(), :second)
    )
  end

  @doc """
  Changeset for profile fields coming from the OAuth provider. `:email` is
  normalized (trimmed/downcased) so every email in the system is canonical —
  `Hamaca.Members` matches invite rows against `user.email` verbatim and
  relies on this.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :avatar_url])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> unique_constraint(:email)
    |> unique_constraint(:provider_uid)
  end

  @doc """
  Changeset for the user's own preferences — today only `setup_explanations_hidden`, whether the
  board setup checklist (RE443) hides its *what this does* explanations. Kept apart from
  `changeset/2`, the OAuth profile path, which must never cast a preference.
  """
  def preferences_changeset(user, attrs) do
    user
    |> cast(attrs, [:setup_explanations_hidden])
    |> validate_required([:setup_explanations_hidden])
  end

  @doc """
  The one email normalization (trim + downcase); `nil` stays `nil`. The
  changeset applies it, and account lookups by email go through it so a
  differently-cased claim still matches the stored row.
  """
  @spec normalize_email(String.t() | nil) :: String.t() | nil
  def normalize_email(nil), do: nil
  def normalize_email(email), do: email |> String.trim() |> String.downcase()
end
