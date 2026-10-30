defmodule Hamaca.Repo.Migrations.AddClaudeSessionIsolationToTalkSessions do
  use Ecto.Migration

  # RE366 — the isolation class a talk session's `claude_session_id` was created under, so a turn
  # that switches class starts a fresh session instead of `--resume`-ing one from the other tree.
  # Every session that exists today was created in its card's own worktree, so a row that already
  # holds a session id is backfilled `exclusive`. The value is FROZEN here (a migration never calls
  # app code that may change later).
  def up do
    alter table(:talk_sessions) do
      add :claude_session_isolation, :string
    end

    execute "UPDATE talk_sessions SET claude_session_isolation = 'exclusive' WHERE claude_session_id IS NOT NULL"
  end

  def down do
    alter table(:talk_sessions) do
      remove :claude_session_isolation
    end
  end
end
