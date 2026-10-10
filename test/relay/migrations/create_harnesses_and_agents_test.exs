# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Relay.Repo.Migrations.CreateHarnessesAndAgents) do
  "priv/repo/migrations/*_create_harnesses_and_agents.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Relay.Migrations.CreateHarnessesAndAgentsTest do
  @moduledoc """
  RE433 — every existing board gets the three frozen seed harnesses, the three Claude agents
  and "Claude Opus" as its default, so no board is left without an agent to run its nodes on.
  """
  use Relay.DataCase, async: true

  alias Relay.Repo
  alias Relay.Repo.Migrations.CreateHarnessesAndAgents, as: Migration

  # Scenario 17
  test "the seed helper gives an unseeded board the frozen harnesses, the agents and the default" do
    board = insert(:board)

    Migration.seed_board!(Repo, board.id)

    %{rows: harnesses} =
      Repo.query!(
        "SELECT key, name, command, models, resume_command, session_id_path, signed_in_check FROM harnesses WHERE board_id = $1 ORDER BY id",
        [board.id]
      )

    assert harnesses == [
             [
               "claude-code",
               "Claude Code",
               "claude -p {prompt} --model {model} --permission-mode auto --verbose --output-format stream-json [--effort {effort}] [--agent {subagent}]",
               ["opus", "sonnet", "haiku"],
               "claude -p --resume {session} {prompt} --model {model} --permission-mode auto --verbose --output-format stream-json [--effort {effort}] [--agent {subagent}]",
               ".session_id",
               "claude auth status"
             ],
             [
               "codex",
               "Codex",
               "codex exec --json --model {model} --cd {worktree} [-c model_reasoning_effort={effort}] {prompt}",
               ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"],
               "codex exec resume --json --model {model} {session} {prompt}",
               ".thread_id",
               "codex login status"
             ],
             [
               "gemini-cli",
               "Gemini CLI",
               "gemini -p {prompt} --model {model}",
               ["gemini-2.5-pro", "gemini-2.5-flash"],
               nil,
               nil,
               nil
             ]
           ]

    %{rows: agents} =
      Repo.query!(
        "SELECT a.name, a.model, h.key FROM agents a JOIN harnesses h ON h.id = a.harness_id WHERE a.board_id = $1 ORDER BY a.id",
        [board.id]
      )

    assert agents == [
             ["Claude Opus", "opus", "claude-code"],
             ["Claude Sonnet", "sonnet", "claude-code"],
             ["Claude Haiku", "haiku", "claude-code"]
           ]

    %{rows: [[default_name]]} =
      Repo.query!("SELECT a.name FROM boards b JOIN agents a ON a.id = b.default_agent_id WHERE b.id = $1", [board.id])

    assert default_name == "Claude Opus"
  end
end
