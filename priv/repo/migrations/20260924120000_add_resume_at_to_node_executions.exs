defmodule Relay.Repo.Migrations.AddResumeAtToNodeExecutions do
  use Ecto.Migration

  # RE267: when a `:blocked` attempt's usage limit resets, as the runner reported it. Nullable —
  # only a usage-limit block with a known reset carries one, and the engine reads its presence to
  # choose requeue over park without re-parsing `detail`.
  def change do
    alter table(:node_executions) do
      add :resume_at, :utc_datetime
    end
  end
end
