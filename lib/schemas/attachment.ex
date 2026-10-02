defmodule Schemas.Attachment do
  @moduledoc """
  Metadata for one file attached to a card (RLY-13): an image, or (RE370) a self-contained
  HTML mockup. The **bytes** live in object storage under `storage_key`; only metadata is
  persisted here. The `binary_id` primary key doubles as the public URL slug
  (`/attachments/<id>` — `path/1`). `card_id`, `byte_size`, and `storage_key` are set
  programmatically, never cast from input; only `filename` and `content_type` originate from
  the caller.

  This module is the ONE definition of two facts every layer needs: the HTML content type
  (`html_type/0`, `html?/1` — the controller's sandboxed serving branch and `Relay.Cards`'
  mockup validation both ask here) and where an attachment is served (`path/1`,
  `id_from_path/1`, `path?/1` — domain-side so `Relay.Cards` can parse a mockup url without
  calling the web layer; `RelayWeb.attachment_path/1` delegates here) — plus where a board API
  key downloads it (`api_path/1`, RE373).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @image_types ~w(image/png image/jpeg image/webp image/gif)
  @html_type "text/html"
  @allowed_types @image_types ++ [@html_type]
  @max_bytes 5_242_880
  @path_prefix "/attachments/"
  @api_path_prefix "/api/attachments/"

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
  are already set on the struct/attrs programmatically. Accepts the image types and (RE370)
  `text/html`; rejects every other content type and bytes over 5 MB.
  """
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:filename, :content_type, :byte_size, :storage_key])
    |> validate_required([:card_id, :filename, :content_type, :byte_size, :storage_key])
    |> validate_inclusion(:content_type, @allowed_types, message: "must be one of: #{Enum.join(@allowed_types, ", ")}")
    |> validate_number(:byte_size,
      less_than_or_equal_to: @max_bytes,
      message: "must be at most #{@max_bytes} bytes"
    )
    |> foreign_key_constraint(:card_id)
  end

  @doc "The HTML content type (RE370) — the one spelling of it."
  def html_type, do: @html_type

  @doc """
  Whether an attachment (or a bare content type) is HTML, and so must be served under the
  sandbox CSP rather than as an image (RE370).
  """
  def html?(%__MODULE__{content_type: content_type}), do: html?(content_type)
  def html?(content_type), do: content_type == @html_type

  @doc """
  RE322 — the path an attachment is served from (`AttachmentController.show`). The router's
  `get "/attachments/:id"` is the only other spelling (a route can't call a function);
  `RelayWeb.AttachmentPathTest` pins the two together.
  """
  def path(id), do: @path_prefix <> to_string(id)

  @doc """
  RE373 — the path a board API key downloads an attachment's raw bytes from
  (`RelayWeb.Api.AttachmentController.show`). The router's bearer-authed
  `get "/attachments/:id"` inside `scope "/api"` is the only other spelling;
  `RelayWeb.AttachmentPathTest` pins the two together, and `./relay` mirrors the prefix under
  `runner_contract.json`'s `mockups.download_path`.
  """
  def api_path(id), do: @api_path_prefix <> to_string(id)

  @doc """
  The id in a path `path/1` builds — the prefix plus a non-empty, single-segment id — as
  `{:ok, id}`; `:error` for a bare `/attachments/`, a nested path, or a non-string.
  """
  def id_from_path(@path_prefix <> id) when id != "" do
    if String.contains?(id, "/"), do: :error, else: {:ok, id}
  end

  def id_from_path(_path), do: :error

  @doc "Whether `path` is a path `path/1` builds."
  def path?(path), do: match?({:ok, _id}, id_from_path(path))
end
