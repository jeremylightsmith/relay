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

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    manifest = Relay.Scaffold.build!(File.cwd!(), Relay.Scaffold.root())

    Mix.shell().info(
      "scaffold: #{length(manifest["items"])} items · version #{manifest["version"]} → #{Relay.Scaffold.root()}"
    )
  end
end
