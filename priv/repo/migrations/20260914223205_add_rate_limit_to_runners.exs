defmodule Relay.Repo.Migrations.AddRateLimitToRunners do
  use Ecto.Migration

  def change do
    alter table(:runners) do
      # RE320: the runner's self-reported Claude usage pause (`Schemas.RunnerRateLimit`, an
      # embed), or NULL while it is claiming normally — and for every runner predating RE320,
      # which never sends the key. Written by the HEARTBEAT only.
      add :rate_limit, :map
    end
  end
end
