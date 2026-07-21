defmodule Relay.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :relay

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    # After schema migrations, push the current default flow library onto existing boards so a
    # flow-graph edit (e.g. RLY-192's sync nodes) reaches boards that already exist, not just
    # newly created ones. Idempotent; preserves hand-customized flows (version > 1).
    #
    # RLY-219: this MUST run inside `with_repo` — `migrate/0` runs in a release with no repo
    # started, and the loop above starts each repo only for the duration of its migration and
    # stops it again. Calling `sync_defaults!/0` (which uses `Relay.Repo`) after the loop crashed
    # with "could not lookup Ecto repo Relay.Repo because it was not started", aborting the whole
    # release_command and every deploy since RLY-192. `with_repo` starts the repo for the call.
    [primary_repo | _] = repos()
    {:ok, _, _} = Ecto.Migrator.with_repo(primary_repo, fn _repo -> Relay.Flows.sync_defaults!() end)

    :ok
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
