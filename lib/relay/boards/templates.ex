defmodule Relay.Boards.Templates do
  @moduledoc """
  The starter board templates "New board" offers (RE442), **loaded** at compile time from
  `docs/designs/templates/*.json`. Those files are the source of truth: edit the JSON and the
  library follows. This module is the ONE place the slug list lives (`slugs/0`).

  `@external_resource` is load-bearing, not decoration: without it, editing a JSON file does
  not trigger a recompile and the change silently doesn't take effect until a clean build.

  A template carries its picker copy, its main stages (in board order, each with its
  sub-lanes and WIP limit), the agents it adds beyond the seeded ones, and its flow documents —
  the same shape as `docs/designs/flows/*.json`, decoded by `Relay.Flows.Document.decode!/1`, with
  triggers authored as stage *names*. A stage's `category`, `type` and `sublanes` are checked
  against `Schemas.Stage.categories/0`, `types/0` and `sublane_types/0`; any other value fails
  the build. `Relay.Boards.create_board/2` applies one; the web layer reads them through
  `Relay.Boards.templates/0`, never this module.
  """

  alias Relay.Flows.Document
  alias Schemas.Stage

  @type stage :: %{
          name: String.t(),
          category: atom(),
          type: atom(),
          wip_limit: pos_integer() | nil,
          sublanes: [:review | :done]
        }

  @type template :: %{
          slug: String.t(),
          name: String.t(),
          tagline: String.t(),
          blurb: String.t(),
          warning: String.t() | nil,
          stages: [stage()],
          agents: [%{name: String.t(), harness: String.t()}],
          flows: [map()]
        }

  @templates_dir Path.expand("../../../docs/designs/templates", __DIR__)
  @slugs ~w(bare-minimum design-led three-brain)

  for slug <- @slugs do
    @external_resource Path.join(@templates_dir, "#{slug}.json")
  end

  # Compile-time only: turns a JSON string into one of `allowed`'s atoms, never `String.to_atom/1`.
  to_enum! = fn value, allowed, what ->
    Enum.find(allowed, &(Atom.to_string(&1) == value)) ||
      raise ArgumentError, "invalid board template: #{what} #{inspect(value)} is not one of #{inspect(allowed)}"
  end

  sublane_order = Stage.sublane_types()

  @all Enum.map(@slugs, fn slug ->
         doc = @templates_dir |> Path.join("#{slug}.json") |> File.read!() |> Jason.decode!()

         stages =
           Enum.map(doc["stages"], fn stage ->
             sublanes = Enum.map(stage["sublanes"], &to_enum!.(&1, sublane_order, "sub-lane"))

             %{
               name: stage["name"],
               category: to_enum!.(stage["category"], Stage.categories(), "category"),
               type: to_enum!.(stage["type"], Stage.types(), "type"),
               wip_limit: stage["wip_limit"],
               sublanes: Enum.sort_by(sublanes, &Stage.sublane_rank/1)
             }
           end)

         %{
           slug: doc["slug"],
           name: doc["name"],
           tagline: doc["tagline"],
           blurb: doc["blurb"],
           warning: doc["warning"],
           stages: stages,
           agents: Enum.map(doc["agents"], &%{name: &1["name"], harness: &1["harness"]}),
           flows: Enum.map(doc["flows"], &Document.decode!/1)
         }
       end)

  if Enum.map(@all, & &1.slug) != @slugs do
    raise ArgumentError, "invalid board template: each file's \"slug\" must match its file name"
  end

  @doc "The template slugs, in picker order — the ONE slug list."
  @spec slugs() :: [String.t()]
  def slugs, do: @slugs

  @doc "Every template, in `slugs/0` order."
  @spec all() :: [template()]
  def all, do: @all

  @doc "The template with `slug`, or nil."
  @spec get(String.t()) :: template() | nil
  def get(slug), do: Enum.find(@all, &(&1.slug == slug))
end
