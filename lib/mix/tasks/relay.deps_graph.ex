defmodule Mix.Tasks.Relay.DepsGraph do
  @shortdoc "Regenerate the boundary dependency graph embedded in docs/architecture/deps.md"

  @moduledoc """
  Regenerates the `Relay` context dependency graph (from the `boundary` compiler)
  and writes it, as a Mermaid diagram, into `docs/architecture/deps.md` between the
  generated markers.

      mix relay.deps_graph          # regenerate and write the graph into the doc
      mix relay.deps_graph --check  # exit non-zero if the doc is out of date (no writes)

  The `--check` form makes a good CI/precommit gate: it fails when a context's
  `deps`/`exports` changed without the doc being regenerated.

  The graph is derived from `mix boundary.visualize`, which emits `boundary/Relay.dot`.
  That intermediate folder is git-ignored — only the Mermaid in the doc is committed.
  """

  use Mix.Task
  use Boundary, check: [in: false, out: false]

  @doc_path "docs/architecture/deps.md"
  @dot_path "boundary/Relay.dot"

  @begin_marker "<!-- BEGIN generated: boundary-graph -->"
  @end_marker "<!-- END generated: boundary-graph -->"

  @impl Mix.Task
  def run(args) do
    check? = "--check" in args

    body = @dot_path |> generate_dot() |> File.read!() |> dot_to_mermaid()
    doc = File.read!(@doc_path)

    case splice(doc, body) do
      :error ->
        Mix.raise("#{@doc_path} is missing the boundary-graph markers:\n  #{@begin_marker}\n  #{@end_marker}")

      {:ok, ^doc} ->
        Mix.shell().info("#{@doc_path} is up to date.")

      {:ok, _updated} when check? ->
        Mix.raise("#{@doc_path} is out of date. Run `mix relay.deps_graph` and commit the result.")

      {:ok, updated} ->
        File.write!(@doc_path, updated)
        Mix.shell().info("Updated the boundary graph in #{@doc_path}.")
    end
  end

  defp generate_dot(path) do
    Mix.Task.run("boundary.visualize", [])
    path
  end

  @doc """
  Converts a boundary-generated Graphviz DOT string into a fenced Mermaid `flowchart LR`.

  Isolated nodes (declared but in no edge) are preserved, and node names that aren't
  valid Mermaid identifiers are emitted in `id["label"]` form. Output is sorted so the
  same graph always renders identically.
  """
  def dot_to_mermaid(dot) do
    edges = parse_edges(dot)
    nodes = parse_nodes(dot, edges)
    edged = MapSet.new(Enum.flat_map(edges, fn {a, b} -> [a, b] end))

    label_lines =
      nodes
      |> Enum.filter(fn n -> ident(n) != n end)
      |> Enum.sort()
      |> Enum.map(fn n -> "    #{ident(n)}[#{inspect(n)}]" end)

    isolated_lines =
      nodes
      |> Enum.reject(&MapSet.member?(edged, &1))
      |> Enum.filter(fn n -> ident(n) == n end)
      |> Enum.sort()
      |> Enum.map(fn n -> "    #{ident(n)}" end)

    edge_lines =
      edges
      |> Enum.sort()
      |> Enum.map(fn {a, b} -> "    #{ident(a)} --> #{ident(b)}" end)

    body = Enum.join(label_lines ++ isolated_lines ++ edge_lines, "\n")

    "```mermaid\nflowchart LR\n#{body}\n```"
  end

  @doc """
  Replaces the content between the generated markers in `doc` with `body`.

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

  defp parse_edges(dot) do
    ~r/"([^"]+)"\s*->\s*"([^"]+)"/
    |> Regex.scan(dot)
    |> Enum.map(fn [_, a, b] -> {a, b} end)
    |> Enum.uniq()
  end

  defp parse_nodes(dot, edges) do
    declared =
      ~r/"([^"]+)"\s*\[/
      |> Regex.scan(dot)
      |> Enum.map(fn [_, n] -> n end)

    Enum.uniq(declared ++ Enum.flat_map(edges, fn {a, b} -> [a, b] end))
  end

  defp ident(name), do: String.replace(name, ~r/[^A-Za-z0-9_]/, "_")
end
