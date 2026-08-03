defmodule Relay.Repo.Migrations.BackfillStoryMapReleases do
  use Ecto.Migration

  import Ecto.Query

  # RE265: `Boards.create_board/2` only seeds releases on board *create*, so every board that
  # already exists would open the story map with zero swimlanes. Backfill them, idempotently:
  # a board that already has any release is skipped entirely.
  #
  # Following the `backfill_board_keys_two_letters` precedent, the names and positions are
  # INLINED here (`release_names/0`, not a call into `Schemas.Release.seed_names/0`) so this
  # migration stays frozen against later code changes.
  # `backfill_story_map_releases_test.exs` pins the two lists together so they cannot diverge.
  def up do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    board_ids = repo().all(from(b in "boards", select: b.id))
    with_releases = repo().all(from(r in "releases", select: r.board_id, distinct: true))

    repo().insert_all("releases", rows(boards_to_seed(board_ids, with_releases), now))
  end

  # No-op on purpose: releases created after this migration are indistinguishable from the
  # ones it seeded, so a rollback must not destroy them.
  def down, do: :ok

  @doc """
  Frozen copy of the seeded swimlane names, in position order. Deliberately NOT a call into
  `Schemas.Release.seed_names/0`; the test pins the two together.
  """
  def release_names, do: ["MVP", "Fast follow", "Later"]

  @doc """
  Pure: the boards that still need seeding — every board with no release row. Public + pure so
  the idempotency rule is unit-testable without the migrator's Runner context (`repo/0`
  requires it).
  """
  def boards_to_seed(board_ids, board_ids_with_releases) do
    seeded = MapSet.new(board_ids_with_releases)

    Enum.reject(board_ids, &MapSet.member?(seeded, &1))
  end

  @doc "Pure: the `releases` rows to insert for `board_ids`, all stamped `now`."
  def rows(board_ids, now) do
    for board_id <- board_ids, {name, position} <- Enum.with_index(release_names(), 1) do
      %{board_id: board_id, name: name, position: position, inserted_at: now, updated_at: now}
    end
  end
end
