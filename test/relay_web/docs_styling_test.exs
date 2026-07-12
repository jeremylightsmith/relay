defmodule RelayWeb.DocsStylingTest do
  use ExUnit.Case, async: true

  @app_css Path.join([File.cwd!(), "assets", "css", "app.css"])
  @storybook_css Path.join([File.cwd!(), "assets", "css", "storybook.css"])

  # Every docs style selector must exist in BOTH stylesheets (the mirror rule).
  @mirrored_selectors [
    ".docs-nav",
    ".docs-nav-brand",
    ".docs-nav-eyebrow",
    ".docs-nav-cta",
    ".docs-sidebar-heading",
    ".docs-sidebar-link.is-active",
    ".docs-toc",
    ".docs-breadcrumb",
    ".docs-eyebrow",
    ".docs h1",
    ".docs h2",
    ".docs pre",
    ".docs table",
    ".docs .markdown-alert-note",
    ".docs .markdown-alert-tip",
    ".docs .markdown-alert-warning"
  ]

  test "every docs style is mirrored from app.css into storybook.css" do
    app = File.read!(@app_css)
    storybook = File.read!(@storybook_css)

    for sel <- @mirrored_selectors do
      assert String.contains?(app, sel), "app.css is missing #{sel}"
      assert String.contains?(storybook, sel), "storybook.css is missing #{sel} (mirror rule)"
    end
  end

  test "the docs chrome keeps its design-language anchors (Human=blue, mono labels, blue CTA)" do
    app = File.read!(@app_css)

    # "Open the board" CTA is a solid Human-blue button.
    assert app =~ ~r/\.docs-nav-cta\s*\{[^}]*background:\s*var\(--color-primary\)/s

    # The active sidebar item reads as Human/blue.
    assert app =~ ~r/\.docs-sidebar-link\.is-active\s*\{[^}]*var\(--color-primary\)/s

    # Eyebrow, section headings and the TOC heading are set in the mono (JetBrains) token.
    for sel <- [".docs-nav-eyebrow", ".docs-sidebar-heading", ".docs-toc-heading", ".docs-eyebrow"] do
      assert app =~ ~r/#{Regex.escape(sel)}\s*\{[^}]*var\(--font-mono\)/s,
             "#{sel} should use var(--font-mono)"
    end

    # The page-header eyebrow above the h1 reads as AI/violet, per the mockup.
    assert app =~ ~r/\.docs-eyebrow\s*\{[^}]*var\(--color-secondary\)/s

    # Callouts carry the actor palette: note→primary(blue), tip→secondary(violet), warning→amber.
    assert app =~ ~r/\.docs\s+\.markdown-alert-note[^}]*\{[^}]*var\(--color-primary\)/s
    assert app =~ ~r/\.docs\s+\.markdown-alert-tip[^}]*\{[^}]*var\(--color-secondary\)/s
    assert app =~ ~r/\.docs\s+\.markdown-alert-warning[^}]*\{[^}]*var\(--color-warning\)/s
  end

  test "the pager label reads all-caps like every other mono label in the mockup" do
    for css <- [File.read!(@app_css), File.read!(@storybook_css)] do
      assert css =~ ~r/\.docs-pager-label\s*\{[^}]*text-transform:\s*uppercase/s
    end
  end
end
