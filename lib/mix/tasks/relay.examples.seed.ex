defmodule Mix.Tasks.Relay.Examples.Seed do
  @shortdoc "Create the public example boards, one per board template (RE444)"

  @moduledoc """
  Creates the three public, read-only example boards (`Relay.Examples.seed!/2`) owned by the
  user with `--owner`'s email, printing `created <slug>` or `skipped <slug>` per template.
  Idempotent: an existing example board is skipped. `--reset` deletes and recreates them.

      mix relay.examples.seed --owner you@example.com [--reset]

  On Fly, use `Relay.Release.seed_examples/2` over `bin/relay rpc` instead.
  """

  use Mix.Task
  use Boundary, check: [in: false, out: false]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [owner: :string, reset: :boolean])
    email = opts[:owner] || Mix.raise("--owner <email> is required")

    Mix.Task.run("app.start")
    owner = Relay.Accounts.get_user_by_email(email) || Mix.raise("no user with email #{email}")
    summary = Relay.Examples.seed!(owner, reset: Keyword.get(opts, :reset, false))

    for %{template: slug} <- Relay.Examples.all() do
      Mix.shell().info(if slug in summary.created, do: "created #{slug}", else: "skipped #{slug}")
    end
  end
end
