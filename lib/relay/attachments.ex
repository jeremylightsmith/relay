defmodule Relay.Attachments do
  @moduledoc """
  The Attachments context (RLY-13): stores image bytes in object storage and
  keeps a metadata row per attachment. The metadata `id` (a `binary_id`) is
  the public URL slug served at `/attachments/<id>`. Bytes never touch
  Postgres. Validation (image-only content type, 5 MB cap) lives in the
  schema changeset. The storage adapter is chosen by config so tests stay
  hermetic (`Local`) and prod uses object storage (`S3`).
  """

  use Boundary, deps: [Relay.Boards, Relay.Repo, Schemas]

  alias Relay.Boards
  alias Relay.Repo
  alias Schemas.Attachment
  alias Schemas.Card
  alias Schemas.User

  @doc """
  Validates `attrs` (`:filename`, `:content_type`, `:bytes`), stores the
  bytes via the configured storage adapter under a generated key, inserts a
  metadata row, and returns `{:ok, attachment}` — or `{:error, changeset}`
  if the content type isn't an allowed image or the bytes exceed 5 MB.
  Bytes are only written to storage once the metadata passes validation.
  """
  def create_attachment(%Card{} = card, %{filename: filename, content_type: content_type, bytes: bytes})
      when is_binary(bytes) do
    storage_key = Ecto.UUID.generate()

    changeset =
      Attachment.changeset(%Attachment{card_id: card.id}, %{
        filename: filename,
        content_type: content_type,
        byte_size: byte_size(bytes),
        storage_key: storage_key
      })

    if changeset.valid? do
      with :ok <- storage().put(storage_key, bytes, content_type) do
        Repo.insert(changeset)
      end
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  @doc "The metadata row for `id`, or `nil` (also `nil` for an id that isn't a valid UUID)."
  def get_attachment(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Attachment, uuid)
      :error -> nil
    end
  end

  @doc """
  Membership-scoped: the metadata row for `id`, but only when `user` is a
  member of the board that owns the attachment's card. `nil` for an unknown
  id, a non-UUID id, or an id whose card belongs to a board `user` isn't a
  member of — same visibility boundary as every other board-scoped lookup
  (`Relay.Boards.get_board/2`).
  """
  def get_attachment(%User{} = user, id) when is_binary(id) do
    with %Attachment{} = attachment <- get_attachment(id),
         %Attachment{card: %Card{board: board}} <- Repo.preload(attachment, card: :board),
         %Schemas.Board{} <- Boards.get_board(user, board.slug) do
      attachment
    else
      _ -> nil
    end
  end

  @doc "Reads the stored bytes for `attachment` from the storage adapter."
  def fetch_bytes(%Attachment{storage_key: key}), do: storage().get(key)

  defp storage do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:storage, Relay.Attachments.Storage.Local)
  end
end
