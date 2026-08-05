defmodule Mix.Tasks.Relay.GenVocab do
  @shortdoc "Regenerate the closed-vocabulary table embedded in docs/architecture/state.md"

  @moduledoc """
  Regenerates the "Closed vocabularies" table in `docs/architecture/state.md` from the schemas
  that own each closed set, and writes it between the generated markers.

      mix relay.gen_vocab          # regenerate and write the table into the doc
      mix relay.gen_vocab --check  # exit non-zero if the table is out of date (no writes)

  The `--check` form is a precommit/CI gate: it fails when a value is added to or removed from an
  `Ecto.Enum` without the doc being regenerated. Only the vocabularies block is generated — every
  other table and all prose in `state.md` stays hand-written, and the separate `run-transitions`
  block belongs to `Mix.Tasks.Relay.GenState`.

  Prose pages are allowed to restate these values in their own words (ADR 0008's site carve-out);
  those restatements are held to the schema by `Relay.DocsVocabularyTest` instead.

  A direct sibling of `Mix.Tasks.Relay.GenState` and `Mix.Tasks.Relay.DepsGraph`: same
  marker-splice shape, same `--check` contract.
  """

  use Mix.Task
  use Boundary, check: [in: false, out: false]

  @doc_path "docs/architecture/state.md"

  @begin_marker "<!-- BEGIN generated: vocabularies -->"
  @end_marker "<!-- END generated: vocabularies -->"

  # {label, {module, zero-arity accessor}}. The accessor is the single definition of the set;
  # this list is only the registry of which sets the docs publish.
  @vocabularies [
    {"Card status", {Schemas.Card, :statuses}},
    {"Run status", {Schemas.Run, :statuses}},
    {"Run parked reason", {Schemas.Run, :parked_reasons}},
    {"Node-job state", {Schemas.NodeJob, :states}},
    {"Node-job kind", {Schemas.NodeJob, :kinds}},
    {"Node outcome", {Schemas.NodeExecution, :outcomes}},
    {"Stage category", {Schemas.Stage, :categories}},
    {"Stage type", {Schemas.Stage, :types}}
  ]

  @impl Mix.Task
  def run(args) do
    # The task reads the Schemas modules, so the app must be compiled/loaded first.
    Mix.Task.run("compile", [])
    check? = "--check" in args

    body = render(vocabularies())
    doc = File.read!(@doc_path)

    case splice(doc, body) do
      :error ->
        Mix.raise("#{@doc_path} is missing the vocabularies markers:\n  #{@begin_marker}\n  #{@end_marker}")

      {:ok, ^doc} ->
        Mix.shell().info("#{@doc_path} is up to date.")

      {:ok, _updated} when check? ->
        Mix.raise("#{@doc_path} is out of date. Run `mix relay.gen_vocab` and commit the result.")

      {:ok, updated} ->
        File.write!(@doc_path, updated)
        Mix.shell().info("Updated the closed-vocabulary table in #{@doc_path}.")
    end
  end

  @doc "The registry of published closed vocabularies: `{label, {module, accessor}}`."
  def vocabularies, do: @vocabularies

  @doc """
  Renders the vocabularies as a markdown table. Rows are sorted by label so the same registry
  always renders identically regardless of source order.
  """
  def render(vocabularies) do
    rows =
      vocabularies
      |> Enum.sort_by(fn {label, _owner} -> label end)
      |> Enum.map(fn {label, {module, fun}} ->
        values = module |> apply(fun, []) |> Enum.map_join(" · ", &"`#{&1}`")
        "| #{label} | #{values} | `#{inspect(module)}.#{fun}/0` |"
      end)

    Enum.join(["| Vocabulary | Values | Owner |", "| --- | --- | --- |" | rows], "\n")
  end

  @doc """
  Replaces the content between the vocabularies markers in `doc` with `body`.

  Returns `{:ok, updated}` (the markers are kept), or `:error` if either marker is absent.
  """
  def splice(doc, body) do
    if String.contains?(doc, @begin_marker) and String.contains?(doc, @end_marker) do
      pattern = ~r/#{Regex.escape(@begin_marker)}.*?#{Regex.escape(@end_marker)}/s
      replacement = "#{@begin_marker}\n#{body}\n#{@end_marker}"
      {:ok, Regex.replace(pattern, doc, replacement)}
    else
      :error
    end
  end
end
