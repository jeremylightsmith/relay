defmodule Hamaca.Repo.Migrations.AddDoneAtToCards do
  @moduledoc """
  RE504 — `cards.done_at` records when a card entered its board's terminal stage. `up` adds the
  column and its index, then backfills it. Plain SQL, so it never depends on app modules that may
  change.
  """
  use Ecto.Migration

  def up do
    alter table(:cards) do
      add :done_at, :utc_datetime
    end

    create index(:cards, [:stage_id, :done_at])

    flush()

    updated = backfill(repo())
    IO.puts("add_done_at_to_cards: backfilled #{updated} card(s)")
  end

  def down do
    drop index(:cards, [:stage_id, :done_at])

    alter table(:cards) do
      remove :done_at
    end
  end

  @doc """
  Stamps `done_at` on every card (archived included) sitting in its board's terminal stage that
  has none: the latest `:moved` activity into that stage, else the card's `updated_at`. Never
  overwrites a set value, so a second run changes nothing. Returns the number of cards updated.
  """
  def backfill(repo) do
    %{num_rows: updated} = repo.query!(backfill_sql())
    updated
  end

  # The terminal stage is the last top-level stage by position, per board — the same rule as
  # Hamaca.Boards.terminal_stage/1. Ecto stores enums as strings. `meta.to_stage_id` is a jsonb
  # integer (RE146), compared as text so a malformed value can never abort the migration; rows
  # from before RE146 carry no id, never match, and the card falls back to updated_at.
  defp backfill_sql do
    """
    WITH terminal AS (
      SELECT DISTINCT ON (board_id) id
      FROM stages
      WHERE parent_id IS NULL
      ORDER BY board_id, position DESC
    )
    UPDATE cards AS c
    SET done_at = coalesce(
      (
        SELECT max(a.inserted_at)
        FROM activities AS a
        WHERE a.card_id = c.id
          AND a.type = 'moved'
          AND a.meta->>'to_stage_id' = c.stage_id::text
      ),
      c.updated_at
    )
    FROM terminal AS t
    WHERE c.stage_id = t.id
      AND c.done_at IS NULL
    """
  end
end
