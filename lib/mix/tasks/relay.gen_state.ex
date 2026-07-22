defmodule Mix.Tasks.Relay.GenState do
  @shortdoc "Regenerate the Run-status transition table embedded in docs/architecture/state.md"

  @moduledoc """
  Regenerates the Run-status from->to transition table from `Relay.Runs.Transitions`' edge data
  and writes it, as a markdown table, into `docs/architecture/state.md` between the generated
  markers.

      mix relay.gen_state          # regenerate and write the table into the doc
      mix relay.gen_state --check  # exit non-zero if the table is out of date (no writes)

  The `--check` form is a precommit/CI gate: it fails when an edge is added to or removed from
  `Relay.Runs.Transitions` without the doc being regenerated. Only the from->to edge table is
  generated — every other table and all prose in `state.md` stays hand-written.

  A direct sibling of `Mix.Tasks.Relay.DepsGraph`: same marker-splice shape, same `--check`
  contract.
  """

  use Mix.Task
  use Boundary, check: [in: false, out: false]

  alias Relay.Runs.Transitions

  @doc_path "docs/architecture/state.md"

  @begin_marker "<!-- BEGIN generated: run-transitions -->"
  @end_marker "<!-- END generated: run-transitions -->"

  @impl Mix.Task
  def run(args) do
    # The task reads Relay.Runs.Transitions, so the app must be compiled/loaded first.
    Mix.Task.run("compile", [])
    check? = "--check" in args

    body = render(Transitions.transitions())
    doc = File.read!(@doc_path)

    case splice(doc, body) do
      :error ->
        Mix.raise("#{@doc_path} is missing the run-transitions markers:\n  #{@begin_marker}\n  #{@end_marker}")

      {:ok, ^doc} ->
        Mix.shell().info("#{@doc_path} is up to date.")

      {:ok, _updated} when check? ->
        Mix.raise("#{@doc_path} is out of date. Run `mix relay.gen_state` and commit the result.")

      {:ok, updated} ->
        File.write!(@doc_path, updated)
        Mix.shell().info("Updated the run-transition table in #{@doc_path}.")
    end
  end

  @doc """
  Renders the `{from, to, meaning}` transition list as a markdown table. Rows are atom-sorted by
  `{from, to}` so the same graph always renders identically regardless of source order.
  """
  def render(transitions) do
    rows =
      transitions
      |> Enum.sort_by(fn {from, to, _meaning} -> {to_string(from), to_string(to)} end)
      |> Enum.map(fn {from, to, meaning} -> "| `#{from}` | `#{to}` | #{meaning} |" end)

    Enum.join(["| From | To | Meaning |", "| --- | --- | --- |" | rows], "\n")
  end

  @doc """
  Replaces the content between the run-transitions markers in `doc` with `body`.

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
