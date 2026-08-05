defmodule Relay.Repo.Migrations.CreateTalkTables do
  use Ecto.Migration

  # RE268 / ADR 0009: the transcript. Deliberately NOT the `LogForwarder` -> `Relay.AgentLog`
  # path, which drops on a full queue by construction — right for a live feed, wrong for a
  # record this feature promises to keep.
  def change do
    create table(:talk_sessions) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      # nil until the first turn FINISHES — this id is what makes turn n+1 a continuation.
      add :claude_session_id, :string
      add :pinned_executor_name, :string
      add :seed_summary, :string
      add :seed_fields, {:array, :map}, null: false, default: []
      add :last_event_seq, :integer, null: false, default: 0
      add :cleared_through_seq, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:talk_sessions, [:card_id])

    create table(:talk_turns) do
      add :talk_session_id, references(:talk_sessions, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :nilify_all)
      add :prompt, :text, null: false
      add :status, :string, null: false
      add :detail, :text
      add :node_job_id, references(:node_jobs, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:talk_turns, [:talk_session_id, :id])

    create table(:talk_events) do
      add :talk_session_id, references(:talk_sessions, on_delete: :delete_all), null: false
      add :talk_turn_id, references(:talk_turns, on_delete: :delete_all), null: false
      # Server-assigned, monotonic per session. RENDER ORDER IS THIS, never a timestamp.
      add :seq, :integer, null: false
      # The executor's per-turn counter. Its uniqueness is what makes an at-least-once
      # retry of a batch store exactly once.
      add :client_seq, :integer, null: false
      add :kind, :string, null: false
      add :text, :text, null: false
      add :dim, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:talk_events, [:talk_session_id, :seq])
    create unique_index(:talk_events, [:talk_turn_id, :client_seq])
  end
end
