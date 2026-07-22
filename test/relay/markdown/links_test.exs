defmodule Relay.Markdown.LinksTest do
  use ExUnit.Case, async: true

  alias Relay.Markdown.Links

  @slugs %{
    "docs/architecture/README.md" => "architecture",
    "docs/architecture/domain.md" => "architecture-domain",
    "docs/architecture/runtime.md" => "architecture-runtime"
  }

  @dir "docs/architecture"

  describe "rewrite/3 leaves URLs it must not touch alone" do
    test "absolute http(s) and mailto URLs are unchanged" do
      for url <- [
            "https://hexdocs.pm/boundary",
            "http://example.com/a.md",
            "mailto:jeremy.lightsmith@gmail.com"
          ] do
        assert Links.rewrite(url, @dir, @slugs) == url
      end
    end

    test "a bare anchor is unchanged" do
      assert Links.rewrite("#contexts", @dir, @slugs) == "#contexts"
    end

    test "an empty URL is unchanged" do
      assert Links.rewrite("", @dir, @slugs) == ""
    end
  end

  describe "rewrite/3 maps published pages to /docs/<slug>" do
    test "a sibling architecture page becomes its docs path" do
      assert Links.rewrite("domain.md", @dir, @slugs) == "/docs/architecture-domain"
    end

    test "an explicit ./ prefix resolves the same way" do
      assert Links.rewrite("./runtime.md", @dir, @slugs) == "/docs/architecture-runtime"
    end

    test "the anchor is preserved" do
      assert Links.rewrite("domain.md#core-schemas", @dir, @slugs) ==
               "/docs/architecture-domain#core-schemas"
    end
  end

  describe "rewrite/3 falls back to the GitHub blob URL" do
    test "a file outside the published set becomes an absolute GitHub URL" do
      assert Links.rewrite("../adr/0006-workflow-orchestration.md", @dir, @slugs) ==
               "https://github.com/jeremylightsmith/relay/blob/main/docs/adr/0006-workflow-orchestration.md"
    end

    test "the anchor is preserved on the fallback too" do
      assert Links.rewrite("../vision.md#north-star", @dir, @slugs) ==
               "https://github.com/jeremylightsmith/relay/blob/main/docs/vision.md#north-star"
    end

    test "a directory link outside the set resolves to its GitHub path" do
      assert Links.rewrite("../designs/flows/README.md", @dir, @slugs) ==
               "https://github.com/jeremylightsmith/relay/blob/main/docs/designs/flows/README.md"
    end
  end
end
