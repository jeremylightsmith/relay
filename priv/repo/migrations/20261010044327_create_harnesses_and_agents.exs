defmodule Relay.Repo.Migrations.CreateHarnessesAndAgents do
  use Ecto.Migration

  # RE433 — a board owns harnesses (an agent CLI's command template + its closed model list) and
  # named agents (harness + model), one of which is the board default. Every existing board is
  # seeded here so no flow node is left without an agent to run on.
  #
  # The seed below is a FROZEN copy of `Relay.Agents.seed_harnesses/0` and the legacy agent table
  # `Schemas.Flow.Node.legacy_models/0` — the one sanctioned exception to the magic-value rule: a
  # migration must replay identically forever, so it never calls app code that may change after
  # it ships.
  @harnesses [
    %{
      key: "claude-code",
      name: "Claude Code",
      command:
        "claude -p {prompt} --model {model} --permission-mode auto --verbose --output-format stream-json [--effort {effort}] [--agent {subagent}]",
      models: ["opus", "sonnet", "haiku"],
      resume_command:
        "claude -p --resume {session} {prompt} --model {model} --permission-mode auto --verbose --output-format stream-json [--effort {effort}] [--agent {subagent}]",
      session_id_path: ".session_id",
      signed_in_check: "claude auth status"
    },
    %{
      key: "codex",
      name: "Codex",
      command:
        "codex exec --json --model {model} --cd {worktree} [-c model_reasoning_effort={effort}] {prompt}",
      models: [
        "gpt-6.1-sol",
        "gpt-6-astra",
        "gpt-6-sol",
        "gpt-6-luna",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna"
      ],
      resume_command: "codex exec resume --json --model {model} {session} {prompt}",
      session_id_path: ".thread_id",
      signed_in_check: "codex login status"
    },
    %{
      key: "gemini-cli",
      name: "Gemini CLI",
      command: "gemini -p {prompt} --model {model}",
      models: ["gemini-2.5-pro", "gemini-2.5-flash"],
      resume_command: nil,
      session_id_path: nil,
      signed_in_check: nil
    }
  ]

  # {name, model} on the claude-code harness, the first one the default.
  @agents [{"Claude Opus", "opus"}, {"Claude Sonnet", "sonnet"}, {"Claude Haiku", "haiku"}]

  def up do
    create table(:harnesses) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :name, :string, null: false
      add :command, :text, null: false
      add :models, {:array, :string}, null: false, default: []
      add :resume_command, :text
      add :session_id_path, :string
      add :signed_in_check, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:harnesses, [:board_id, :key])
    create unique_index(:harnesses, [:board_id, :name])

    create table(:agents) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :harness_id, references(:harnesses, on_delete: :delete_all), null: false
      add :model, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:agents, [:board_id, :name])
    create index(:agents, [:harness_id])

    alter table(:boards) do
      add :default_agent_id, references(:agents, on_delete: :nilify_all)
    end

    flush()

    %{rows: rows} = repo().query!("SELECT id FROM boards ORDER BY id")
    Enum.each(rows, fn [board_id] -> seed_board!(repo(), board_id) end)
  end

  def down do
    alter table(:boards) do
      remove :default_agent_id
    end

    drop table(:agents)
    drop table(:harnesses)
  end

  @doc "Seeds one board with the frozen harnesses, agents and default — exactly what `up` runs per board."
  def seed_board!(repo, board_id) do
    harness_ids =
      Map.new(@harnesses, fn h ->
        %{rows: [[id]]} =
          repo.query!(
            """
            INSERT INTO harnesses (board_id, key, name, command, models, resume_command, session_id_path, signed_in_check, inserted_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now(), now()) RETURNING id
            """,
            [
              board_id,
              h.key,
              h.name,
              h.command,
              h.models,
              h.resume_command,
              h.session_id_path,
              h.signed_in_check
            ]
          )

        {h.key, id}
      end)

    [default_id | _] =
      Enum.map(@agents, fn {name, model} ->
        %{rows: [[id]]} =
          repo.query!(
            "INSERT INTO agents (board_id, name, harness_id, model, inserted_at, updated_at) VALUES ($1, $2, $3, $4, now(), now()) RETURNING id",
            [board_id, name, Map.fetch!(harness_ids, "claude-code"), model]
          )

        id
      end)

    repo.query!("UPDATE boards SET default_agent_id = $1 WHERE id = $2", [default_id, board_id])
    :ok
  end
end
