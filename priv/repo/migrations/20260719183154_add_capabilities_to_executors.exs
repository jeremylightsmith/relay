defmodule Relay.Repo.Migrations.AddCapabilitiesToExecutors do
  use Ecto.Migration

  def change do
    alter table(:executors) do
      # Nullable with NO default: null means "this executor has never reported its
      # inventory", which preflight must render as a caveat rather than as missing
      # names. `%{}` — reported, and empty — is a different and real answer.
      add :capabilities, :map, null: true
    end
  end
end
