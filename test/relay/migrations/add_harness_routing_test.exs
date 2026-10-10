# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Relay.Repo.Migrations.AddHarnessRouting) do
  "priv/repo/migrations/*_add_harness_routing.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Relay.Migrations.AddHarnessRoutingTest do
  @moduledoc """
  RE433 — agent jobs already queued or claimed when the harness routing ships carry no harness;
  the backfill points them at the frozen Claude Code harness so the new runner can still run
  them (a claimed one may later be requeued by `requeue_orphaned_jobs/3`).
  """
  use Relay.DataCase, async: true

  alias Relay.Repo
  alias Relay.Repo.Migrations.AddHarnessRouting, as: Migration
  alias Schemas.NodeJob

  @frozen_harness %{
    "key" => "claude-code",
    "command" =>
      "claude -p {prompt} --model {model} --permission-mode auto --verbose --output-format stream-json [--effort {effort}] [--agent {subagent}]",
    "resume_command" =>
      "claude -p --resume {session} {prompt} --model {model} --permission-mode auto --verbose --output-format stream-json [--effort {effort}] [--agent {subagent}]",
    "session_id_path" => ".session_id"
  }

  defp job!(state, node_type) do
    insert(:node_job,
      state: state,
      payload: %{"isolation" => "shared_clean", "node_type" => node_type, "run" => "/x {ref}"},
      harness_key: nil
    )
  end

  # Task 2 · Scenario 14
  test "the backfill points active agent jobs at the frozen Claude Code harness, nothing else" do
    queued = job!(:queued, "agent")
    claimed = job!(:claimed, "agent")
    shell = job!(:queued, "shell")
    done = job!(:done, "agent")

    Migration.backfill!(Repo)

    for job <- [queued, claimed] do
      job = Repo.get!(NodeJob, job.id)
      assert job.harness_key == "claude-code"
      assert job.payload["harness"] == @frozen_harness
      assert job.payload["model"] == "opus"
      assert job.payload["run"] == "/x {ref}"
    end

    for job <- [shell, done] do
      reloaded = Repo.get!(NodeJob, job.id)
      assert reloaded.harness_key == nil
      assert reloaded.payload == job.payload
    end
  end
end
