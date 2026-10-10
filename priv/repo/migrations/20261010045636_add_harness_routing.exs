defmodule Relay.Repo.Migrations.AddHarnessRouting do
  use Ecto.Migration

  # RE433 — a node job names the harness it runs on (`node_jobs.harness_key`, nil for shell/gate
  # nodes and talk turns) and a runner reports which harnesses it has installed
  # (`runners.harnesses`, nil = never reported). Claims match the two.
  #
  # Agent jobs already queued or claimed when this ships carry no harness: they are pointed at
  # Claude Code — the only CLI a pre-RE433 runner ever ran. A claimed one must be rewritten too,
  # since `requeue_orphaned_jobs/3` may later hand it to a new runner. The harness below is a
  # FROZEN copy of `Relay.Agents.seed_harnesses/0`'s Claude Code entry and its legacy model — the
  # one sanctioned exception to the magic-value rule: a migration must replay identically forever.
  @harness_key "claude-code"
  @model "opus"
  @command "claude -p {prompt} --model {model} --permission-mode auto --verbose --output-format stream-json [--effort {effort}] [--agent {subagent}]"
  @resume_command "claude -p --resume {session} {prompt} --model {model} --permission-mode auto --verbose --output-format stream-json [--effort {effort}] [--agent {subagent}]"
  @session_id_path ".session_id"

  def up do
    alter table(:node_jobs) do
      add :harness_key, :string
    end

    alter table(:runners) do
      add :harnesses, {:array, :map}
    end

    flush()
    backfill!(repo())
  end

  def down do
    alter table(:runners) do
      remove :harnesses
    end

    alter table(:node_jobs) do
      remove :harness_key
    end
  end

  @doc "Points every active agent job lacking a harness at the frozen Claude Code harness — exactly what its test runs."
  def backfill!(repo) do
    harness = %{
      "key" => @harness_key,
      "command" => @command,
      "resume_command" => @resume_command,
      "session_id_path" => @session_id_path
    }

    repo.query!(
      """
      UPDATE node_jobs
         SET harness_key = $1,
             payload = payload || jsonb_build_object('harness', $2::jsonb, 'model', $3::text)
       WHERE state IN ('queued', 'claimed')
         AND kind = 'node'
         AND payload->>'node_type' = 'agent'
         AND NOT (payload ? 'harness')
      """,
      [@harness_key, harness, @model]
    )

    :ok
  end
end
