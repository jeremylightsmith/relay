defmodule Relay.DocsDesignsTest do
  use ExUnit.Case, async: true

  @designs Path.join([File.cwd!(), "docs", "designs"])

  for file <- ["Relay Docs.dc.html", "Relay API Reference.dc.html"] do
    test "the #{file} mockup is synced into docs/designs/" do
      path = Path.join(@designs, unquote(file))

      assert File.exists?(path), "#{unquote(file)} must be synced into docs/designs/ (RLY-64 Task 1)"
      assert File.stat!(path).size > 2_000, "#{unquote(file)} looks empty or truncated"
    end

    test "the #{file} mockup is a pristine pull, not a hand-authored placeholder" do
      path = Path.join(@designs, unquote(file))
      content = File.read!(path)

      refute content =~ "NOTE (local copy)",
             "#{unquote(file)} still carries the hand-authored placeholder note — re-pull " <>
               "the genuine artboard via DesignSync (RLY-64 Task 1)"

      assert content =~ ~s(<script type="text/x-dc" data-dc-script),
             "#{unquote(file)} is missing the design-canvas dynamic-content script — it " <>
               "looks like a hand-authored copy rather than a genuine DesignSync pull"
    end
  end
end
