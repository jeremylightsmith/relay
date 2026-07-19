defmodule Relay.MarkdownTest do
  use ExUnit.Case, async: true

  alias Relay.Markdown

  describe "to_html/1" do
    test "renders bold markdown to a <strong> element" do
      {:safe, html} = Markdown.to_html("**bold**")
      assert html =~ "<strong>bold</strong>"
    end

    test "renders a heading and a list" do
      {:safe, html} = Markdown.to_html("# Title\n\n- one\n- two")
      assert html =~ "<h1>Title</h1>"
      assert html =~ "<li>one</li>"
    end

    test "nil renders to an empty safe string" do
      assert Markdown.to_html(nil) == {:safe, ""}
    end

    test "always returns a Phoenix.HTML safe value" do
      assert {:safe, _} = Markdown.to_html("plain text")
    end

    test "strips a raw <script> tag and its content (XSS guard)" do
      {:safe, html} = Markdown.to_html("hello <script>alert('xss')</script> world")
      refute html =~ "<script"
      refute html =~ "alert('xss')"
      assert html =~ "hello"
    end

    test "renders a GFM pipe table as an HTML <table>" do
      {:safe, html} =
        Markdown.to_html("""
        | HTTP | code |
        | --- | --- |
        | 401 | unauthorized |
        """)

      assert html =~ "<table>"
      assert html =~ "<th>HTTP</th>"
      assert html =~ "<td>401</td>"
      refute html =~ "| HTTP | code |"
    end
  end

  describe "to_docs_html/1" do
    test "adds heading id + anchor href so the TOC can link to it" do
      {:safe, html} = Markdown.to_docs_html("## Getting started")
      assert html =~ ~s(id="getting-started")
      assert html =~ ~s(href="#getting-started")
    end

    test "renders a GitHub-style NOTE callout" do
      {:safe, html} = Markdown.to_docs_html("> [!NOTE]\n> Heads up.")
      assert html =~ "markdown-alert markdown-alert-note"
      assert html =~ "markdown-alert-title"
    end

    test "still renders GFM tables" do
      {:safe, html} = Markdown.to_docs_html("| a | b |\n| --- | --- |\n| 1 | 2 |")
      assert html =~ "<table>"
    end

    test "still strips a raw <script> (sanitizer stays on)" do
      {:safe, html} = Markdown.to_docs_html("hi <script>alert('x')</script>")
      refute html =~ "<script"
      refute html =~ "alert('x')"
    end

    test "nil renders to an empty safe string" do
      assert Markdown.to_docs_html(nil) == {:safe, ""}
    end
  end

  describe "to_html/1 regression (card path is unchanged)" do
    test "does NOT add heading ids (cards get no anchors)" do
      {:safe, html} = Markdown.to_html("## Getting started")
      assert html =~ "Getting started"
      refute html =~ ~s(id="getting-started")
    end
  end

  describe "table_of_contents/1" do
    test "returns level/text/anchor for ## and ### headings, skipping # and code fences" do
      md = """
      # Page title

      ## Alpha

      text

      ```elixir
      ## not a heading
      ```

      ### Beta

      ## Gamma
      """

      assert Markdown.table_of_contents(md) == [
               %{level: 2, text: "Alpha", anchor: "alpha"},
               %{level: 3, text: "Beta", anchor: "beta"},
               %{level: 2, text: "Gamma", anchor: "gamma"}
             ]
    end

    test "de-duplicates repeated headings the way comrak does" do
      anchors =
        "## Setup\n\n## Setup\n\n## Setup"
        |> Markdown.table_of_contents()
        |> Enum.map(& &1.anchor)

      assert anchors == ["setup", "setup-1", "setup-2"]
    end

    test "counts the h1 in de-dup so a ## reusing its text still matches the rendered id" do
      # comrak numbers ids document-wide across levels: h1 Setup -> "setup", h2 Setup -> "setup-1".
      md = "# Setup\n\nintro\n\n## Setup\n\n## Authentication"

      assert Markdown.table_of_contents(md) == [
               %{level: 2, text: "Setup", anchor: "setup-1"},
               %{level: 2, text: "Authentication", anchor: "authentication"}
             ]

      {:safe, html} = Markdown.to_docs_html(md)
      assert html =~ ~s(id="setup-1")
    end

    test "strips backticks from display text but the anchor still matches the rendered id" do
      [%{text: text, anchor: anchor}] = Markdown.table_of_contents("## CLI (`bin/relay`)")
      assert text == "CLI (bin/relay)"
      assert anchor == "cli-binrelay"

      {:safe, html} = Markdown.to_docs_html("## CLI (`bin/relay`)")
      assert html =~ ~s(id="cli-binrelay")
    end

    test "nil returns an empty list" do
      assert Markdown.table_of_contents(nil) == []
    end
  end

  describe "to_docs_html/2 with :rewrite_links" do
    @slugs %{
      "docs/architecture/domain.md" => "architecture-domain",
      "docs/architecture/runtime.md" => "architecture-runtime"
    }

    defp render_arch(markdown) do
      {:safe, html} =
        Markdown.to_docs_html(markdown,
          rewrite_links: {"docs/architecture", @slugs}
        )

      html
    end

    test "an intra-architecture link becomes a /docs path" do
      assert render_arch("See [domain](domain.md).") =~ ~s(href="/docs/architecture-domain")
    end

    test "an anchor survives the rewrite" do
      assert render_arch("See [domain](domain.md#contexts).") =~
               ~s(href="/docs/architecture-domain#contexts")
    end

    test "an unpublished file becomes a GitHub blob URL" do
      html = render_arch("See [ADR 0006](../adr/0006-workflow-orchestration.md).")

      assert html =~
               ~s(href="https://github.com/jeremylightsmith/relay/blob/main/docs/adr/0006-workflow-orchestration.md")
    end

    test "an absolute URL is left alone" do
      assert render_arch("See [boundary](https://hexdocs.pm/boundary).") =~
               ~s(href="https://hexdocs.pm/boundary")
    end

    test "a link inside a fenced code block is not mangled" do
      html = render_arch("```elixir\n# see [domain](domain.md)\n```")

      assert html =~ "[domain](domain.md)"
      refute html =~ "/docs/architecture-domain"
    end

    test "a mermaid fence still reaches the HTML as language-mermaid" do
      html = render_arch("```mermaid\nflowchart LR\n  a --> b\n```")

      assert html =~ ~s(class="language-mermaid")
      assert html =~ "flowchart LR"
    end

    test "without the option, output is identical to to_docs_html/1" do
      markdown = "See [domain](domain.md) and [x](https://example.com).\n\n## Heading\n"

      assert Markdown.to_docs_html(markdown) ==
               Markdown.to_docs_html(markdown, [])
    end
  end
end
