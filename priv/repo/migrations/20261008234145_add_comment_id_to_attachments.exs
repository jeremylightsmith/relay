defmodule Relay.Repo.Migrations.AddCommentIdToAttachments do
  use Ecto.Migration

  # RE427 — images on Notes: a note image is an ordinary card attachment linked to the comment
  # that carries it. `comment_id` is nullable (an upload is unlinked until its note posts, and
  # unposted uploads simply stay unlinked); deleting the comment unlinks rather than deletes the
  # bytes' metadata. `position` is the image's index within its note — set from the posted id
  # list, because `inserted_at` is second-precision and ids are random UUIDs, so neither orders
  # two images uploaded in the same second. Written only through Relay.Activity.add_comment/2.
  def change do
    alter table(:attachments) do
      add :comment_id, references(:comments, on_delete: :nilify_all)
      add :position, :integer
    end

    create index(:attachments, [:comment_id])
  end
end
