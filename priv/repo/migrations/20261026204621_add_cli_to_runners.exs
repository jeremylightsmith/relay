defmodule Hamaca.Repo.Migrations.AddCliToRunners do
  use Ecto.Migration

  # RE486: the CLI name a runner runs as (`"hamaca"` | `"relay"`), reported as `runner.cli` on
  # every claim and heartbeat since RE478 and normalized by `Schemas.Runner.normalize_cli/1`.
  # Nullable with no default: nil means the runner never reported one (a pre-v94 runner) or
  # reported a name outside the closed set. `Hamaca.Runs.pre_rename_runner?/1` reads it.
  def change do
    alter table(:runners) do
      add :cli, :string
    end
  end
end
