defmodule Relay.Flows.DefaultLibrary do
  @moduledoc """
  The default flow library, **loaded** at compile time from `docs/designs/flows/*.json`
  (RLY-241). Those files are the source of truth — not a reference mirrored by hand into
  Elixir, which is what this module used to be. Edit the JSON; the library follows.

  `@external_resource` is load-bearing, not decoration: without it, editing a JSON file does
  not trigger a recompile and the change silently doesn't take effect until a clean build.

  Seeded per board, disabled until cutover, by `Relay.Flows.seed_default_flows!/1`; triggers
  are authored as stage *names* the seeder resolves to ids. `all/0`'s return shape is the dense
  attr shape `Relay.Flows.Document.decode/1` produces, which is what `seed_default_flows!/1`,
  `customized?/1`, `default_key?/1`, `diff_from_default/1`, `reset_to_default/1` and
  `mix relay.flows.sync_defaults` already consume.
  """

  alias Relay.Flows.Document

  @flows_dir Path.expand("../../../docs/designs/flows", __DIR__)
  @keys ~w(spec plan code)

  for key <- @keys do
    @external_resource Path.join(@flows_dir, "#{key}.json")
  end

  @all Enum.map(@keys, fn key ->
         @flows_dir
         |> Path.join("#{key}.json")
         |> File.read!()
         |> Jason.decode!()
         |> Document.decode!()
       end)

  @doc ~S|The three default flow definitions ("spec", "plan", "code") as changeset-ready attrs.|
  def all, do: @all
end
