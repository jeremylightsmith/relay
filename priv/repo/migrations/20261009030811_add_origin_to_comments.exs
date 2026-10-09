defmodule Relay.Repo.Migrations.AddOriginToComments do
  use Ecto.Migration

  # RE428 — where an image note came from: an answer to a needs-input question (`origin
  # "answer"` + the 1-based `origin_question`) or a Request-changes rejection (`"rejection"`).
  # Both nullable: every existing comment, and every plain note, has no origin. The closed set
  # is Schemas.Comment.origins/0; both columns are written only by Relay.Activity.add_comment/2.
  def change do
    alter table(:comments) do
      add :origin, :string
      add :origin_question, :integer
    end
  end
end
