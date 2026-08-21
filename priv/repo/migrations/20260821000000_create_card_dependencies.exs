defmodule Relay.Repo.Migrations.CreateCardDependencies do
  use Ecto.Migration

  # RE93 — one row per "this card is blocked by that card" edge, both ends on the SAME board
  # (refs are board-scoped, so a cross-board ref simply never resolves). Rows are insert/delete
  # only, never updated, so there is no updated_at. Cascading on both FKs means a hard-deleted
  # card takes its edges with it; the *soft* archive path is Relay.Cards.archive_card/2, which
  # deletes only the incoming rows (decision 2).
  def change do
    create table(:card_dependencies) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :depends_on_card_id, references(:cards, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:card_dependencies, [:card_id, :depends_on_card_id])
    # The reverse ("what does this card block?") lookup the drawer's Blocks rail runs.
    create index(:card_dependencies, [:depends_on_card_id])

    create constraint(:card_dependencies, :card_dependencies_no_self_reference,
             check: "card_id <> depends_on_card_id"
           )
  end
end
