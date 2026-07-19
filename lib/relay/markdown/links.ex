defmodule Relay.Markdown.Links do
  @moduledoc """
  Rewrites one markdown link URL into its published form on the public docs site.

  Repo markdown links to sibling files (`domain.md`, `../adr/0006-…md`). Published as
  HTML those would be dead. `rewrite/3` maps each URL, given the source page's
  repo-relative directory and a `%{repo_relative_path => slug}` map of published pages:

    1. absolute (`http://`, `https://`, `mailto:`) or a bare `#anchor` → unchanged;
    2. resolves to a published page → `/docs/<slug>`;
    3. otherwise → the file's GitHub blob URL, so it still resolves for a reader on a phone.

  Anchors are preserved in cases 2 and 3. Pure and side-effect free, so it is unit-tested
  without rendering; `Relay.Markdown.to_docs_html/2` applies it over the MDEx AST (never
  over raw markdown, which would mangle URLs inside code fences).
  """

  @github_blob "https://github.com/jeremylightsmith/relay/blob/main/"
  @absolute_schemes ["http://", "https://", "mailto:"]

  @doc """
  Rewrite `url`, written on a page whose repo-relative directory is `source_dir`, against
  the `%{repo_relative_path => slug}` map of published pages.
  """
  @spec rewrite(String.t(), String.t(), %{optional(String.t()) => String.t()}) :: String.t()
  def rewrite(url, source_dir, slug_by_path) when is_binary(url) and is_binary(source_dir) and is_map(slug_by_path) do
    if passthrough?(url) do
      url
    else
      {path, anchor} = split_anchor(url)
      resolved = resolve(source_dir, path)

      case Map.fetch(slug_by_path, resolved) do
        {:ok, slug} -> "/docs/" <> slug <> anchor
        :error -> @github_blob <> resolved <> anchor
      end
    end
  end

  defp passthrough?(""), do: true
  defp passthrough?("#" <> _), do: true
  defp passthrough?(url), do: Enum.any?(@absolute_schemes, &String.starts_with?(url, &1))

  defp split_anchor(url) do
    case String.split(url, "#", parts: 2) do
      [path] -> {path, ""}
      [path, anchor] -> {path, "#" <> anchor}
    end
  end

  # Path.expand/2 against "/" normalises "." and ".." without touching the filesystem;
  # trimming the leading "/" turns the result back into a repo-relative path.
  defp resolve(source_dir, path) do
    source_dir
    |> Path.join(path)
    |> Path.expand("/")
    |> String.trim_leading("/")
  end
end
