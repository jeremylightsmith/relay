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

  @doc """
  Creates the public example boards (`Relay.Examples.seed!/2`, RE444) owned by the user with
  `email`, returning the `%{created: slugs, skipped: slugs}` summary; `opts` takes
  `reset: true`. Raises `ArgumentError` for an unknown email.

  Unlike `migrate/0`, this runs against the **live** node, never `load_app`/`with_repo`: the
  seeder's `Relay.Events` broadcasts need the running app's PubSub. On Fly:

      fly ssh console -C "/app/bin/relay rpc 'Relay.Release.seed_examples(\"<email>\")'"
  """
  @spec seed_examples(String.t(), keyword()) :: %{created: [String.t()], skipped: [String.t()]}
  def seed_examples(email, opts \\ []) when is_binary(email) do
    case Relay.Accounts.get_user_by_email(email) do
      nil -> raise ArgumentError, "no user with email #{email}"
      owner -> Relay.Examples.seed!(owner, opts)
    end
  end

  @doc """
  The stages and flows of the example board for each template in `slugs`
  (`Relay.Boards.template_parts/1`), as `%{slug => parts}` — what `prod pull-demo-flows` writes
  back into `docs/designs/templates/<slug>.json`. Raises `ArgumentError` for a template with no
  example board. A read, so `rpc` on the live node like `seed_examples/2`.
  """
  @spec example_template_parts([String.t()]) :: %{String.t() => %{String.t() => [map()]}}
  def example_template_parts(slugs) when is_list(slugs) do
    Map.new(slugs, fn slug ->
      case Relay.Boards.get_example_board(slug) do
        {:ok, board} -> {slug, Relay.Boards.template_parts(board)}
        :error -> raise ArgumentError, "no example board for template #{inspect(slug)}"
      end
    end)
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
