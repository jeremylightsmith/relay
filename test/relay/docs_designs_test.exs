defmodule Relay.DocsDesignsTest do
  use ExUnit.Case, async: true

  @designs Path.join([File.cwd!(), "docs", "designs"])

  for file <- ["Relay Docs.dc.html", "Relay API Reference.dc.html"] do
    test "the #{file} mockup is synced into docs/designs/" do
      path = Path.join(@designs, unquote(file))

      assert File.exists?(path), "#{unquote(file)} must be synced into docs/designs/ (RLY-64 Task 1)"
      assert File.stat!(path).size > 2_000, "#{unquote(file)} looks empty or truncated"
    end
  end
end
