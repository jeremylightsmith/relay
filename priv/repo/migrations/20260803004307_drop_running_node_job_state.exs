defmodule Relay.Repo.Migrations.DropRunningNodeJobState do
  use Ecto.Migration

  @moduledoc """
  RE255: `:running` leaves the `node_jobs` state enum — nothing ever wrote it in production
  (`Runs.start_job/1` had no caller), and `:claimed` on a live executor already means running.
  `node_jobs.state` is a plain string column with no constraint, so this is a data rewrite only:
  any legacy row would otherwise raise `Ecto.ChangeError` on load once the enum narrows.
  """

  def up do
    execute("UPDATE node_jobs SET state = 'claimed' WHERE state = 'running'")
  end

  # Not reversible: a rewritten row is indistinguishable from a natively-claimed one, and the
  # distinction carried no information anyway.
  def down, do: :ok
end
