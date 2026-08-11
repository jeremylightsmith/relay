defmodule Mix.Tasks.Relay.BuildScaffold do
  @shortdoc "Build priv/scaffold/ — the files the app serves at /api/scaffold"

  @moduledoc """
  Copy the five Relay-owned files into `priv/scaffold/` and write `priv/scaffold/manifest.json`
  (RE304).

      mix relay.build_scaffold

  Idempotent and content-addressed: the manifest `version` is derived from the files' bytes, so
  re-running without changing anything produces an identical manifest. `priv/scaffold/` is a
  gitignored build artifact — `mix setup` and the `test` alias run this so a local
  `mix phx.server` serves the same thing a release does, and the `Dockerfile` runs it before
  `mix release` bundles `priv/` into the image.

  The rules (which files, how the version is derived) live in `Relay.Scaffold`, not here; this
  task is only the entry point.
  """

  use Mix.Task
  use Boundary, check: [in: false, out: false]

  # `compile`, deliberately NOT `app.config`. This task copies files and hashes bytes: it needs
  # the project compiled and `:relay` on the code path (`Relay.Scaffold`, `Jason`,
  # `Application.app_dir/2`) and nothing else. `app.config` loads `config/runtime.exs` whenever
  # that file exists, and under `MIX_ENV=prod` ours raises without `DATABASE_URL` /
  # `SECRET_KEY_BASE` — so the prod image built only because `COPY config/runtime.exs` happens to
  # sit BELOW this task in the Dockerfile. Hoisting that COPY (a routine tidy its own comment
  # invites) would have broken `fly deploy` with a missing-database error from a task that needs
  # no database, and CI could never catch it: the workflow pins `MIX_ENV=test`, so only a real
  # deploy exercises the Dockerfile. Decoupling also fixes `MIX_ENV=prod mix relay.build_scaffold`
  # locally, which is the obvious thing to run when debugging a prod build.
  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    manifest = Relay.Scaffold.build!(File.cwd!(), Relay.Scaffold.root())

    Mix.shell().info(
      "scaffold: #{length(manifest["items"])} items · version #{manifest["version"]} → #{Relay.Scaffold.root()}"
    )
  end
end
