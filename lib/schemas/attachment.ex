defmodule Schemas.Attachment do
  @moduledoc """
  Metadata for one file attached to a card (RLY-13): an image, or (RE370) a self-contained
  HTML mockup. The **bytes** live in object storage under `storage_key`; only metadata is
  persisted here. The `binary_id` primary key doubles as the public URL slug
  (`/attachments/<id>` — `path/1`). `card_id`, `byte_size`, and `storage_key` are set
  programmatically, never cast from input; only `filename` and `content_type` originate from
  the caller.

  RE427 — an image may belong to a Note: `comment_id` + `position` link it to the comment that
  carries it (set only by `Relay.Activity.add_comment/2`; nil while unlinked).

  This module is the ONE definition of the facts every layer needs: the HTML content type
  (`html_type/0`, `html?/1` — the controller's sandboxed serving branch asks here), the image
  types (`image_types/0`) and their display names (`image_type_names/0`, RE427), the size cap
  (`max_bytes/0`, RE427), the mockup types (`mockup_types/0`, RE390 — what `Relay.Cards`'
  mockup validation accepts: HTML or an image; `./relay` mirrors it under
  `runner_contract.json`'s `mockups.content_types`), and where an attachment is served (`path/1`,
  `id_from_path/1`, `path?/1` — domain-side so `Relay.Cards` can parse a mockup url without
  calling the web layer; `RelayWeb.attachment_path/1` delegates here) — plus where a board API
  key downloads it (`api_path/1`, RE373).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @image_types ~w(image/png image/jpeg image/webp image/gif)
  @image_type_names ~w(PNG JPEG WebP GIF)
  @html_type "text/html"
  @mockup_types @image_types ++ [@html_type]
  @allowed_types @mockup_types
  @max_bytes 5_242_880
  @path_prefix "/attachments/"
  @api_path_prefix "/api/attachments/"

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "attachments" do
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :storage_key, :string

    # RE427 — set when the attachment is a note image: the comment that carries it and its
    # index within that note. Both nil for an unlinked upload or a mockup; never cast.
    field :position, :integer

    belongs_to :card, Schemas.Card
    belongs_to :comment, Schemas.Comment

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

  @doc "The image content types an attachment may have (RE390)."
  @spec image_types() :: [String.t()]
  def image_types, do: @image_types

  @doc "The display names of `image_types/0`, in the same order (RE427) — what the UI and its errors say."
  @spec image_type_names() :: [String.t()]
  def image_type_names, do: @image_type_names

  @doc "The largest attachment, in bytes (RE427 — the one spelling of the 5 MB cap)."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The content types a card mockup may be (RE390): an image or self-contained HTML."
  @spec mockup_types() :: [String.t()]
  def mockup_types, do: @mockup_types

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
