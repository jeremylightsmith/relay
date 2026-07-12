defmodule Schemas.Attachment do
  @moduledoc """
  Metadata for one image attached to a card (RLY-13). The image **bytes**
  live in object storage under `storage_key`; only metadata is persisted
  here. The `binary_id` primary key doubles as the public URL slug
  (`/attachments/<id>`). `card_id`, `byte_size`, and `storage_key` are set
  programmatically, never cast from input; only `filename` and
  `content_type` originate from the caller.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @image_types ~w(image/png image/jpeg image/webp image/gif)
  @max_bytes 5_242_880

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "attachments" do
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :storage_key, :string

    belongs_to :card, Schemas.Card

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates an attachment whose `card_id`, `byte_size`, and `storage_key`
  are already set on the struct/attrs programmatically. Rejects non-image
  content types and bytes over 5 MB.
  """
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:filename, :content_type, :byte_size, :storage_key])
    |> validate_required([:card_id, :filename, :content_type, :byte_size, :storage_key])
    |> validate_inclusion(:content_type, @image_types, message: "must be one of: #{Enum.join(@image_types, ", ")}")
    |> validate_number(:byte_size,
      less_than_or_equal_to: @max_bytes,
      message: "must be at most #{@max_bytes} bytes"
    )
    |> foreign_key_constraint(:card_id)
  end
end
