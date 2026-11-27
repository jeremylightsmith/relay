defmodule Hamaca.Repo.Migrations.CreateContentReportsAndModerationColumns do
  @moduledoc """
  RE510 — content reports (one person's report of a public idea or a member's comment), the
  `hidden_at` / `hidden_reason` pair on cards and comments, and a user's suspension.
  """

  use Ecto.Migration

  def change do
    create table(:content_reports) do
      add :reporter_id, references(:users, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :delete_all)
      add :comment_id, references(:comments, on_delete: :delete_all)
      add :reason, :string, null: false
      add :note, :text
      add :resolution, :string
      add :resolved_by_id, references(:users, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime
      add :prior_hidden_reason, :string
      add :suspended_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create constraint(:content_reports, :content_reports_one_target,
             check: "(card_id IS NOT NULL) <> (comment_id IS NOT NULL)"
           )

    create unique_index(:content_reports, [:reporter_id, :card_id],
             name: :content_reports_reporter_card,
             where: "card_id IS NOT NULL"
           )

    create unique_index(:content_reports, [:reporter_id, :comment_id],
             name: :content_reports_reporter_comment,
             where: "comment_id IS NOT NULL"
           )

    create index(:content_reports, [:card_id])
    create index(:content_reports, [:comment_id])

    create index(:content_reports, [:resolved_at],
             name: :content_reports_open,
             where: "resolved_at IS NULL"
           )

    alter table(:cards) do
      add :hidden_at, :utc_datetime
      add :hidden_reason, :string
    end

    alter table(:comments) do
      add :hidden_at, :utc_datetime
      add :hidden_reason, :string
    end

    alter table(:users) do
      add :suspended_at, :utc_datetime
      add :suspended_by_id, references(:users, on_delete: :nilify_all)
    end
  end
end
