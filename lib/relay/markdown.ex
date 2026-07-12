defmodule Relay.Markdown do
  @moduledoc """
  Renders markdown to sanitized HTML for two audiences:

    * card long-form markdown (`description`, `spec`, `plan`) for display in the card drawer —
      `to_html/1`.
    * the public docs site (`priv/docs/*.md`) — `to_docs_html/1`, which additionally adds
      heading ids and GitHub-style alert callouts so pages can carry an "on this page" table of
      contents; `table_of_contents/1` extracts that TOC from the raw markdown.

  MDEx renders the markdown with raw-HTML pass-through (`unsafe: true`) and then
  runs its HTML sanitizer (`MDEx.Document.default_sanitize_options/0`), so any
  agent- or human-authored markdown has dangerous tags (e.g. `<script>`) and
  their content stripped before it reaches the page. The result is wrapped as a
  `Phoenix.HTML.safe` value for direct `{...}` interpolation in HEEx — templates
  never call `raw/1` on it.
  """

  use Boundary, deps: []

  @doc """
  Render markdown to a sanitized `Phoenix.HTML.safe` value. `nil` renders to an
  empty (safe) string.
  """
  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: {:safe, ""}

  def to_html(markdown) when is_binary(markdown) do
    html =
      MDEx.to_html!(markdown,
        render: [unsafe: true],
        extension: [table: true],
        sanitize: MDEx.Document.default_sanitize_options()
      )

    {:safe, html}
  end

  @doc """
  Render docs-site markdown to a sanitized `Phoenix.HTML.safe` value.

  Unlike `to_html/1` (the card path, which must stay unchanged), this enables heading ids
  (so the TOC can anchor to them) and GitHub-style alert callouts, and widens the sanitizer
  just enough to keep the heading `id` and the alert-title class. `nil` renders to an empty
  (safe) string.
  """
  @spec to_docs_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_docs_html(nil), do: {:safe, ""}

  def to_docs_html(markdown) when is_binary(markdown) do
    html =
      MDEx.to_html!(markdown,
        render: [unsafe: true],
        extension: [table: true, header_id_prefix: "", alerts: true],
        sanitize: docs_sanitize_options()
      )

    {:safe, html}
  end

  @doc """
  Extract an "on this page" table of contents from docs markdown: one entry per `##`/`###`
  heading (level-1 titles and fenced-code lines are skipped). Each entry's `anchor` matches
  the `id` MDEx generates for that heading — same slug algorithm (lowercase; drop punctuation
  except `-`/`_`; whitespace → `-`) and the same `-1`/`-2` de-duplication.
  """
  @spec table_of_contents(String.t() | nil) :: [%{level: 2..3, text: String.t(), anchor: String.t()}]
  def table_of_contents(nil), do: []

  def table_of_contents(markdown) when is_binary(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.reduce({[], false}, &scan_line/2)
    |> elem(0)
    |> Enum.reverse()
    |> assign_anchors()
  end

  defp scan_line(line, {acc, in_fence?}) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "```") or String.starts_with?(trimmed, "~~~") ->
        {acc, not in_fence?}

      in_fence? ->
        {acc, in_fence?}

      true ->
        collect_heading(line, acc, in_fence?)
    end
  end

  defp collect_heading(line, acc, in_fence?) do
    case heading_line(line) do
      {level, rest} -> {[{level, String.trim(rest)} | acc], in_fence?}
      nil -> {acc, in_fence?}
    end
  end

  defp docs_sanitize_options do
    MDEx.Document.default_sanitize_options()
    |> Keyword.put(:add_tag_attributes, %{
      "a" => ["id"],
      "h1" => ["id"],
      "h2" => ["id"],
      "h3" => ["id"],
      "h4" => ["id"],
      "h5" => ["id"],
      "h6" => ["id"]
    })
    |> Keyword.put(:add_allowed_classes, %{"p" => ["markdown-alert-title"]})
  end

  # Match every heading level 1–6 (longest prefix first). We collect all levels so the
  # de-dup counter tracks comrak's document-wide numbering, but only emit ##/### (below).
  defp heading_line("###### " <> rest), do: {6, rest}
  defp heading_line("##### " <> rest), do: {5, rest}
  defp heading_line("#### " <> rest), do: {4, rest}
  defp heading_line("### " <> rest), do: {3, rest}
  defp heading_line("## " <> rest), do: {2, rest}
  defp heading_line("# " <> rest), do: {1, rest}
  defp heading_line(_), do: nil

  defp assign_anchors(headings) do
    {rev, _seen} =
      Enum.reduce(headings, {[], %{}}, fn {level, text}, {acc, seen} ->
        base = slugify(text)

        {anchor, seen} =
          case Map.get(seen, base) do
            nil -> {base, Map.put(seen, base, 1)}
            n -> {"#{base}-#{n}", Map.put(seen, base, n + 1)}
          end

        {[%{level: level, text: display(text), anchor: anchor} | acc], seen}
      end)

    # Advance the counter over *every* heading (so anchors match comrak's ids), but the
    # TOC only shows ## and ### entries.
    rev
    |> Enum.reverse()
    |> Enum.filter(&(&1.level in [2, 3]))
  end

  defp display(text), do: text |> String.replace("`", "") |> String.trim()

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}_\s-]/u, "")
    |> String.replace(~r/\s/u, "-")
  end
end
