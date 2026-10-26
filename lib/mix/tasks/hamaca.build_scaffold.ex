defmodule Mix.Tasks.Hamaca.BuildScaffold do
  @shortdoc "Build priv/scaffold/<layout>/ — the files the app serves at /api/scaffold"

  @moduledoc """
  Build every scaffold layout from the Hamaca-owned sources into `priv/scaffold/<layout>/`, each
  with its `manifest.json` (RE304, RE478). The old flat `priv/scaffold/` contents are removed.

      mix hamaca.build_scaffold

  Idempotent and content-addressed: the manifest `version` is derived from the files' bytes, so
  re-running without changing anything produces an identical manifest. `priv/scaffold/` is a
  gitignored build artifact — `mix setup` and the `test` alias run this so a local
  `mix phx.server` serves the same thing a release does, and the `Dockerfile` runs it before
  `mix release` bundles `priv/` into the image.

  The rules (which layouts, which files, how the version is derived) live in `Hamaca.Scaffold`,
  not here; this task is only the entry point.
  """

  use Mix.Task
  use Boundary, check: [in: false, out: false]

  # `compile`, deliberately NOT `app.config`. This task copies files and hashes bytes: it needs
  # the project compiled and `:hamaca` on the code path (`Hamaca.Scaffold`, `Jason`,
  # `Application.app_dir/2`) and nothing else. `app.config` loads `config/runtime.exs` whenever
  # that file exists, and under `MIX_ENV=prod` ours raises without `DATABASE_URL` /
  # `SECRET_KEY_BASE` — so the prod image built only because `COPY config/runtime.exs` happens to
  # sit BELOW this task in the Dockerfile. Hoisting that COPY (a routine tidy its own comment
  # invites) would have broken `fly deploy` with a missing-database error from a task that needs
  # no database, and CI could never catch it: the workflow pins `MIX_ENV=test`, so only a real
  # deploy exercises the Dockerfile. Decoupling also fixes `MIX_ENV=prod mix hamaca.build_scaffold`
  # locally, which is the obvious thing to run when debugging a prod build.
  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    manifests = Hamaca.Scaffold.build!(File.cwd!(), Hamaca.Scaffold.root())

    layouts =
      Enum.map_join(Hamaca.Scaffold.layouts(), ", ", fn layout ->
        manifest = Map.fetch!(manifests, layout)
        "#{layout} #{length(manifest["items"])} items · version #{manifest["version"]}"
      end)

    Mix.shell().info("scaffold: #{layouts} → #{Hamaca.Scaffold.root()}")
  end
end
