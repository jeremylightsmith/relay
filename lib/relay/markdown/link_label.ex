defmodule Relay.Markdown.LinkLabel do
  @moduledoc """
  The one place Relay reads a GitHub pull request / issue URL (RE324).

    * `label/1` — the short `repo#number` text a bare GitHub PR or issue link shows in card
      markdown (`https://github.com/jeremylightsmith/relay/pull/230` → `relay#230`); `nil` for
      any other URL, which then shows as-is.
    * `branch_url/2` — the GitHub tree URL for a card's branch, derivable only when the card's
      `pr_url` is a GitHub pull request (it names the owner and repo).

  Matches `https://github.com/<owner>/<repo>/(pull|issues)/<number>`, optionally followed by a
  sub-path, query or fragment (`/files`, `?w=1`, `#issuecomment-123`). Pure and side-effect
  free, so it is unit-tested without rendering; `Relay.Markdown.to_html/1` applies `label/1`
  over the MDEx AST.
  """

  @doc """
  The `repo#number` label for a GitHub PR or issue URL, or `nil` for any other URL.
  """
  @spec label(String.t()) :: String.t() | nil
  def label(url) when is_binary(url) do
    case parse(url) do
      {_owner, repo, _kind, number} -> "#{repo}##{number}"
      nil -> nil
    end
  end

  @doc """
  `https://github.com/<owner>/<repo>/tree/<branch>` when `pr_url` is a GitHub pull request URL
  and `branch` is non-empty; otherwise `nil`. Slashes in the branch are kept (GitHub tree URLs
  take them raw); anything else outside the unreserved set is percent-encoded.
  """
  @spec branch_url(String.t() | nil, String.t() | nil) :: String.t() | nil
  def branch_url(pr_url, branch) when is_binary(pr_url) and is_binary(branch) and branch != "" do
    case parse(pr_url) do
      {owner, repo, "pull", _number} -> "https://github.com/#{owner}/#{repo}/tree/#{encode_branch(branch)}"
      _other -> nil
    end
  end

  def branch_url(_pr_url, _branch), do: nil

  defp parse(url) do
    case Regex.run(
           ~r{\Ahttps://github\.com/([^/?#\s]+)/([^/?#\s]+)/(pull|issues)/(\d+)(?:[/?#]\S*)?\z},
           url,
           capture: :all_but_first
         ) do
      [owner, repo, kind, number] -> {owner, repo, kind, number}
      nil -> nil
    end
  end

  defp encode_branch(branch), do: URI.encode(branch, &(URI.char_unreserved?(&1) or &1 == ?/))
end
