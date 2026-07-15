defmodule Schemas.DeviceToken do
  @moduledoc """
  One registered push device (RLY-81). `token` is the APNs device token (a hex
  string); it is **unique across the table**, because it identifies a device +
  app install rather than a user — registration upserts on it so a device that
  re-registers after an account switch re-points to the new user instead of
  duplicating. `platform` is `:ios` only (Android/FCM is deferred — RLY-103).
  `user_id` is set programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "device_tokens" do
    field :token, :string
    field :platform, Ecto.Enum, values: [:ios], default: :ios
    field :last_registered_at, :utc_datetime

    belongs_to :user, Schemas.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a programmatically-built device token: `:token`, `:platform`
  and `:last_registered_at` are cast; `user_id` must already be set on the
  struct.
  """
  def changeset(device_token, attrs) do
    device_token
    |> cast(attrs, [:token, :platform, :last_registered_at])
    |> validate_required([:token, :platform, :last_registered_at])
    |> validate_length(:token, min: 1, max: 200)
    |> unique_constraint(:token)
    |> foreign_key_constraint(:user_id)
  end
end
