defmodule Relay.Markdown.LinkLabelTest do
  use ExUnit.Case, async: true

  alias Relay.Markdown.LinkLabel

  describe "label/1 shortens GitHub PR and issue URLs to repo#number" do
    test "a pull request URL" do
      assert LinkLabel.label("https://github.com/jeremylightsmith/relay/pull/230") == "relay#230"
    end

    test "an issue URL" do
      assert LinkLabel.label("https://github.com/jeremylightsmith/relay/issues/12") == "relay#12"
    end

    test "a PR URL with a /files sub-path" do
      assert LinkLabel.label("https://github.com/jeremylightsmith/relay/pull/230/files") == "relay#230"
    end

    test "a PR URL with a fragment" do
      assert LinkLabel.label("https://github.com/jeremylightsmith/relay/pull/230#issuecomment-123") ==
               "relay#230"
    end

    test "a PR URL with a query string" do
      assert LinkLabel.label("https://github.com/jeremylightsmith/relay/pull/230?w=1") == "relay#230"
    end
  end

  describe "label/1 returns nil for every other URL" do
    test "non-GitHub hosts, repo roots, trees, blobs and malformed ids" do
      for url <- [
            "https://gitlab.com/acme/relay/-/merge_requests/4",
            "https://example.com/acme/relay/pull/1",
            "https://github.com.evil.com/acme/relay/pull/1",
            "http://github.com/acme/relay/pull/1",
            "https://github.com/jeremylightsmith/relay",
            "https://github.com/jeremylightsmith/relay/tree/main",
            "https://github.com/jeremylightsmith/relay/blob/main/README.md",
            "https://github.com/jeremylightsmith/relay/pull/abc",
            "https://github.com/jeremylightsmith/relay/pull/230abc",
            "https://github.com/jeremylightsmith/relay/pull/",
            "mailto:someone@example.com",
            "/attachments/1",
            ""
          ] do
        assert LinkLabel.label(url) == nil, "expected nil for #{inspect(url)}"
      end
    end
  end

  describe "branch_url/2" do
    test "a GitHub PR URL yields the branch's tree URL on the same repo" do
      assert LinkLabel.branch_url(
               "https://github.com/jeremylightsmith/relay/pull/230",
               "re-324-fix-long-links"
             ) == "https://github.com/jeremylightsmith/relay/tree/re-324-fix-long-links"
    end

    test "keeps slashes in the branch and percent-encodes characters that would end the path" do
      assert LinkLabel.branch_url("https://github.com/acme/relay/pull/42", "feat/a#b?c d") ==
               "https://github.com/acme/relay/tree/feat/a%23b%3Fc%20d"
    end

    test "a PR URL with a sub-path still derives the tree URL" do
      assert LinkLabel.branch_url("https://github.com/acme/relay/pull/42/files", "rly-1") ==
               "https://github.com/acme/relay/tree/rly-1"
    end

    test "nil when the PR URL is not a GitHub pull request" do
      assert LinkLabel.branch_url("https://github.com/acme/relay/issues/42", "rly-1") == nil
      assert LinkLabel.branch_url("https://gitlab.com/acme/relay/-/merge_requests/4", "rly-1") == nil
      assert LinkLabel.branch_url(nil, "rly-1") == nil
    end

    test "nil without a branch" do
      assert LinkLabel.branch_url("https://github.com/acme/relay/pull/42", nil) == nil
      assert LinkLabel.branch_url("https://github.com/acme/relay/pull/42", "") == nil
    end
  end
end
