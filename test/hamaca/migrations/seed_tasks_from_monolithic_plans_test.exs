# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Hamaca.Repo.Migrations.SeedTasksFromMonolithicPlans) do
  "priv/repo/migrations/*_seed_tasks_from_monolithic_plans.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Hamaca.Migrations.SeedTasksFromMonolithicPlansTest do
  @moduledoc """
  RE487 — the plan-parse task fallback is gone, so a card whose plan still carries its tasks as
  `## Task N:` headings (and has no task rows) gets those tasks seeded as `sub_tasks` rows before
  the fallback's reader is deleted. Rows are read with raw SQL, as the migration writes them.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Repo
  alias Hamaca.Repo.Migrations.SeedTasksFromMonolithicPlans, as: Migration

  @plan "# Goal\n\n## Task 1: Alpha\nbody\n\n### Task 2 — Beta\n"

  # Scenario 1
  test "seeds a task row per heading, in order, not done" do
    card = insert(:card, plan: @plan)

    assert Migration.seed!(Repo) == :ok

    assert tasks(card) == [{"Alpha", false}, {"Beta", false}]
  end

  # Scenario 2
  test "leaves a card that already has tasks alone" do
    card = insert(:card, plan: "## Task 1: Parsed\n")
    insert(:sub_task, card: card, title: "Authored", position: 0)

    Migration.seed!(Repo)

    assert tasks(card) == [{"Authored", false}]
  end

  # Scenario 3
  test "skips an archived card" do
    card = insert(:card, plan: "## Task 1: Alpha\n", archived_at: ~U[2026-10-01 00:00:00Z])

    Migration.seed!(Repo)

    assert tasks(card) == []
  end

  # Scenario 4
  test "seeds nothing for a single-hash heading or a nil plan" do
    single_hash = insert(:card, plan: "# Task 1: title only\n\nprose")
    no_plan = insert(:card, plan: nil)

    Migration.seed!(Repo)

    assert tasks(single_hash) == []
    assert tasks(no_plan) == []
  end

  # Scenario 5
  test "a second run is a no-op" do
    card = insert(:card, plan: @plan)

    Migration.seed!(Repo)
    Migration.seed!(Repo)

    assert length(tasks(card)) == 2
  end

  # Scenario 6
  test "parse/1 returns the heading titles in order, and [] for nil" do
    assert Migration.parse("## Task 1: A\n#### Task 2 - B\n") == ["A", "B"]
    assert Migration.parse(nil) == []
  end

  defp tasks(card) do
    %{rows: rows} =
      Repo.query!("SELECT title, done FROM sub_tasks WHERE card_id = $1 ORDER BY position", [card.id])

    Enum.map(rows, fn [title, done] -> {title, done} end)
  end
end
