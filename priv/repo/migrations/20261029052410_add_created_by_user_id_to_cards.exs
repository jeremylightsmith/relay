defmodule Hamaca.Repo.Migrations.AddCreatedByUserIdToCards do
  @moduledoc """
  RE500 — `cards.created_by_user_id` records the card's **requester**: the user who created it
  (nil for an agent-created card). `up` adds the column and its index, then backfills it from
  each card's earliest `:created` activity row written by a user. Plain SQL, so it never depends
  on app modules that may change.
  """
  use Ecto.Migration

  def up do
    alter table(:cards) do
      add :created_by_user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:cards, [:created_by_user_id])

    flush()

    updated = backfill(repo())
    IO.puts("add_created_by_user_id_to_cards: backfilled #{updated} card(s)")
  end

  def down do
    drop index(:cards, [:created_by_user_id])

    alter table(:cards) do
      remove :created_by_user_id
    end
  end

  @doc """
  Stamps `created_by_user_id` on every card that has none, from its earliest `:created`
  activity row when that row was written by a (still existing) user. Never overwrites a set
  value. Returns the number of cards updated.
  """
  def backfill(repo) do
    %{num_rows: updated} = repo.query!(backfill_sql())
    updated
  end

  # Ecto stores enums as strings. The earliest :created row decides (min(id)), and only when it
  # is a user row whose user still exists — an agent row or a deleted user leaves the card nil.
  defp backfill_sql do
    """
    WITH first_created AS (
      SELECT card_id, min(id) AS id
      FROM activities
      WHERE type = 'created'
      GROUP BY card_id
    )
    UPDATE cards AS c
    SET created_by_user_id = a.user_id
    FROM first_created AS f
    JOIN activities AS a ON a.id = f.id
    WHERE f.card_id = c.id
      AND a.actor_type = 'user'
      AND a.user_id IS NOT NULL
      AND c.created_by_user_id IS NULL
    """
  end
end
