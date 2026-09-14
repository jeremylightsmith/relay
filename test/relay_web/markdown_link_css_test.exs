defmodule RelayWeb.MarkdownLinkCssTest do
  @moduledoc """
  RE324 — a link in rendered card markdown stays on one line and ends in an ellipsis instead of
  breaking at every `/`. The rule lives in both stylesheets (the storybook mirror rule).
  """
  use ExUnit.Case, async: true

  @stylesheets [
    Path.join([File.cwd!(), "assets", "css", "app.css"]),
    Path.join([File.cwd!(), "assets", "css", "storybook.css"])
  ]

  @declarations [
    "color: var(--color-primary)",
    "text-decoration: underline",
    "display: inline-block",
    "max-width: 100%",
    "white-space: nowrap",
    "overflow: hidden",
    "text-overflow: ellipsis",
    "vertical-align: bottom"
  ]

  test ".md a is a one-line, ellipsized link in app.css and storybook.css" do
    for path <- @stylesheets do
      css = File.read!(path)
      assert [_, body] = Regex.run(~r/^\.md a \{([^}]*)\}/m, css), "#{path} has no `.md a { … }` rule"

      for declaration <- @declarations do
        assert body =~ declaration, "#{path}: `.md a` is missing `#{declaration}`"
      end
    end
  end
end
