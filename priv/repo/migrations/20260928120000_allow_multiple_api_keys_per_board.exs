defmodule Relay.Repo.Migrations.AllowMultipleApiKeysPerBoard do
  use Ecto.Migration

  # RE361: a board may hold any number of named keys (one per machine). The
  # unique index on board_id was the MMF 08 single-key rule; relax it to a plain
  # lookup index. token_prefix stays unique (auth resolves keys by prefix).
  def up do
    drop unique_index(:api_keys, [:board_id])
    create index(:api_keys, [:board_id])
  end

  # Rolling back fails if any board already holds more than one key — revoke the
  # extras first. That is acceptable: the down path restores the old invariant.
  def down do
    drop index(:api_keys, [:board_id])
    create unique_index(:api_keys, [:board_id])
  end
end
